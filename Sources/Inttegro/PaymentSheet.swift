import SwiftUI
import UIKit

/// UIKit presenter for Inttegro's native Checkout experience.
///
/// `PaymentSheet` retrieves the client-safe Checkout projection, renders the
/// familiar Inttegro payment flow, collects a supported payment method, and
/// handles confirmation or provider authorization. Create a new instance for
/// each Order presentation.
///
/// The sheet retains its completion handler only while it is presented. All
/// methods and callbacks are isolated to the main actor.
///
/// ```swift
/// let sheet = PaymentSheet(configuration: configuration)
/// sheet.present(from: viewController) { result in
///     if case .completed = result {
///         verifyOrderFromBackend()
///     }
/// }
/// ```
@MainActor
public final class PaymentSheet {
    /// Callback invoked exactly once with the terminal presentation result.
    public typealias Completion = @MainActor (PaymentSheetResult) -> Void

    private let configuration: PaymentSheetConfiguration
    private let adapter: any PaymentSheetAdapter
    private let telemetry: PaymentSheetTelemetry
    private weak var presentedController: UIViewController?
    private var completion: Completion?

    /// Creates a payment sheet with an application-supplied Checkout adapter.
    ///
    /// Use this initializer for controlled previews, tests, or an adapter that
    /// preserves Inttegro's public Checkout contract. Most applications should
    /// use ``init(configuration:)``.
    ///
    /// - Parameters:
    ///   - configuration: Validated Checkout and presentation options.
    ///   - adapter: Transport and payment operations used by the state machine.
    ///   - telemetry: Optional shared telemetry source for host diagnostics.
    public init(
        configuration: PaymentSheetConfiguration,
        adapter: any PaymentSheetAdapter,
        telemetry: PaymentSheetTelemetry? = nil
    ) {
        self.configuration = configuration
        self.adapter = adapter
        self.telemetry = telemetry ?? PaymentSheetTelemetry(
            configuration: configuration.telemetry
        )
    }

    /// Creates a payment sheet backed by Inttegro's public Checkout endpoints.
    ///
    /// This convenience initializer emits no host-observable events. Use
    /// ``init(configuration:telemetryEventHandler:)`` to receive diagnostics.
    public convenience init(configuration: PaymentSheetConfiguration) {
        self.init(configuration: configuration, telemetryEventHandler: nil)
    }

    /// Creates a Checkout-backed sheet with an optional diagnostic event handler.
    ///
    /// Inttegro installs no exporter. The handler receives privacy-safe events
    /// synchronously in emission order and should hand expensive work to the
    /// application's diagnostics pipeline.
    public convenience init(
        configuration: PaymentSheetConfiguration,
        telemetryEventHandler: PaymentSheetTelemetry.EventHandler?
    ) {
        let telemetry = PaymentSheetTelemetry(
            configuration: configuration.telemetry,
            eventHandler: telemetryEventHandler
        )
        self.init(
            configuration: configuration,
            adapter: CheckoutPaymentSheetAdapter(telemetry: telemetry),
            telemetry: telemetry
        )
    }

    /// Presents the sheet from a visible UIKit view controller.
    ///
    /// Only one presentation may be active for this instance. Recoverable
    /// payment-attempt failures remain inside the sheet, while `completion`
    /// receives only completion, cancellation, or a terminal failure.
    ///
    /// - Parameters:
    ///   - presentingViewController: Visible controller that owns presentation.
    ///   - completion: Main-actor callback invoked once when the sheet finishes.
    public func present(
        from presentingViewController: UIViewController,
        completion: @escaping Completion
    ) {
        guard presentedController == nil else {
            completion(
                .failed(
                    PaymentSheetFailure(
                        code: "payment_sheet_already_presented",
                        message: "The payment sheet is already presented."
                    )
                )
            )
            return
        }

        self.completion = completion
        let model = PaymentSheetViewModel(
            configuration: configuration,
            adapter: adapter,
            telemetry: telemetry
        )
        let rootView = PaymentSheetView(model: model) { [weak self] result in
            self?.finish(with: result)
        }
        let controller = PaymentSheetHostingController(rootView: rootView)
        controller.onDismiss = { [weak self] in
            self?.finish(with: .canceled, dismiss: false)
        }
        controller.modalPresentationStyle = .pageSheet

        if let sheet = controller.sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
            sheet.preferredCornerRadius = configuration.appearance.cornerRadius ?? 30
        }

        presentedController = controller
        presentingViewController.present(controller, animated: true)
        telemetry.emit(.sheetPresented)
    }

    private func finish(with result: PaymentSheetResult, dismiss: Bool = true) {
        guard let completion else { return }
        switch result {
        case .completed:
            telemetry.emit(.sheetCompleted)
        case .canceled:
            telemetry.emit(.sheetCanceled)
        case let .failed(failure):
            telemetry.emit(
                .sheetFailed,
                errorType: PaymentSheetTelemetry.safeErrorType(failure.code)
            )
        }
        self.completion = nil
        let controller = presentedController
        presentedController = nil
        if dismiss {
            controller?.dismiss(animated: true) {
                Task { @MainActor in completion(result) }
            }
        } else {
            completion(result)
        }
    }
}

private final class PaymentSheetHostingController<Content: View>:
    UIHostingController<Content>,
    UIAdaptivePresentationControllerDelegate
{
    var onDismiss: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        onDismiss?()
    }
}
