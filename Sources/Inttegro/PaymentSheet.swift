import SwiftUI
import UIKit

@MainActor
public final class PaymentSheet {
    public typealias Completion = @MainActor (PaymentSheetResult) -> Void

    private let configuration: PaymentSheetConfiguration
    private let adapter: any PaymentSheetAdapter
    private let telemetry: PaymentSheetTelemetry
    private weak var presentedController: UIViewController?
    private var completion: Completion?

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

    public convenience init(configuration: PaymentSheetConfiguration) {
        self.init(configuration: configuration, telemetryEventHandler: nil)
    }

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
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
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
