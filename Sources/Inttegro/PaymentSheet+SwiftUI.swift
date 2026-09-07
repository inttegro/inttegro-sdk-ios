import SwiftUI

/// A SwiftUI-native entry point for Inttegro's payment sheet.
///
/// Pass the public Checkout Order ID created by your backend. Never embed an
/// Inttegro merchant API key in an iOS application.
@MainActor
public struct InttegroPaymentSheet: View {
    @StateObject private var model: PaymentSheetViewModel
    @State private var didReportPresentation = false
    @State private var didReportTerminalResult = false
    @State private var telemetry: PaymentSheetTelemetry
    private let onCompletion: (PaymentSheetResult) -> Void

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

    /// This initializer supports separately supplied transports for testing
    /// and custom API environments.
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}
