import SwiftUI

/// A SwiftUI-native entry point for Inttegro's payment sheet.
///
/// Pass the public Checkout Order ID created by your backend. Never embed an
/// Inttegro merchant API key in an iOS application.
///
/// Use this view when your application owns sheet presentation. For a concise
/// binding-based API, apply
/// ``inttegroPaymentSheet(isPresented:configuration:telemetryEventHandler:onCompletion:)``
/// to the presenting view instead.
@MainActor
public struct InttegroPaymentSheet: View {
    @StateObject private var model: PaymentSheetViewModel
    @State private var didReportPresentation = false
    @State private var didReportTerminalResult = false
    @State private var telemetry: PaymentSheetTelemetry
    private let onCompletion: (PaymentSheetResult) -> Void

    /// Creates Checkout-backed payment content for a SwiftUI sheet.
    ///
    /// - Parameters:
    ///   - configuration: Validated Checkout and presentation options.
    ///   - telemetryEventHandler: Optional host-owned diagnostic receiver.
    ///   - onCompletion: Called once with the terminal presentation result.
    public init(
        configuration: PaymentSheetConfiguration,
        telemetryEventHandler: PaymentSheetTelemetry.EventHandler? = nil,
        onCompletion: @escaping (PaymentSheetResult) -> Void
    ) {
        let telemetry = PaymentSheetTelemetry(
            configuration: configuration.telemetry,
            eventHandler: telemetryEventHandler
        )
        _model = StateObject(
            wrappedValue: PaymentSheetViewModel(
                configuration: configuration,
                adapter: CheckoutPaymentSheetAdapter(telemetry: telemetry),
                telemetry: telemetry
            )
        )
        _telemetry = State(initialValue: telemetry)
        self.onCompletion = onCompletion
    }

    /// Creates payment content with an application-supplied adapter.
    ///
    /// This initializer supports deterministic previews, tests, and controlled
    /// API environments. Production adapters must preserve the public Checkout
    /// security boundary and must not trust client-supplied commercial terms.
    ///
    /// - Parameters:
    ///   - configuration: Validated Checkout and presentation options.
    ///   - adapter: Transport and operations used by the payment state machine.
    ///   - telemetry: Optional shared diagnostic source.
    ///   - onCompletion: Called once with the terminal presentation result.
    public init(
        configuration: PaymentSheetConfiguration,
        adapter: any PaymentSheetAdapter,
        telemetry: PaymentSheetTelemetry? = nil,
        onCompletion: @escaping (PaymentSheetResult) -> Void
    ) {
        let resolvedTelemetry = telemetry ?? PaymentSheetTelemetry(
            configuration: configuration.telemetry
        )
        _model = StateObject(
            wrappedValue: PaymentSheetViewModel(
                configuration: configuration,
                adapter: adapter,
                telemetry: resolvedTelemetry
            )
        )
        _telemetry = State(initialValue: resolvedTelemetry)
        self.onCompletion = onCompletion
    }

    public var body: some View {
        PaymentSheetView(model: model, onResult: report)
            .onAppear {
                guard !didReportPresentation else { return }
                didReportPresentation = true
                telemetry.emit(.sheetPresented)
            }
    }

    private func report(_ result: PaymentSheetResult) {
        guard !didReportTerminalResult else { return }
        didReportTerminalResult = true
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
        onCompletion(result)
    }
}

public extension View {
    /// Presents Inttegro using the system sheet appropriate for iPhone or iPad.
    ///
    /// The payment sheet manages its native detents and drag indicator. This
    /// modifier resets `isPresented` before invoking `onCompletion`, so the
    /// host can safely update navigation or present its own success UI from
    /// the callback.
    ///
    /// - Parameters:
    ///   - isPresented: Binding that controls native sheet presentation.
    ///   - configuration: Validated Checkout and presentation options.
    ///   - telemetryEventHandler: Optional host-owned diagnostic receiver.
    ///   - onCompletion: Called once with the terminal presentation result.
    func inttegroPaymentSheet(
        isPresented: Binding<Bool>,
        configuration: PaymentSheetConfiguration,
        telemetryEventHandler: PaymentSheetTelemetry.EventHandler? = nil,
        onCompletion: @escaping (PaymentSheetResult) -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            InttegroPaymentSheet(
                configuration: configuration,
                telemetryEventHandler: telemetryEventHandler
            ) { result in
                isPresented.wrappedValue = false
                onCompletion(result)
            }
        }
    }
}
