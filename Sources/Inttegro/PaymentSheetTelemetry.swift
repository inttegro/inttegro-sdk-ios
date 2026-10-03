import Foundation

/// One ordered, privacy-safe diagnostic event from a payment-sheet flow.
///
/// Events intentionally exclude Order and Payment IDs, payer data,
/// payment-method details, bodies, redirect URLs, and raw error messages. Use
/// `flowID` and `requestID` for correlation, not as metric dimensions.
public struct PaymentSheetTelemetryEvent: Sendable, Equatable {
    /// Stable event names shared by the native and cross-platform SDKs.
    public enum Name: String, Sendable, CaseIterable {
        /// The native sheet became visible.
        case sheetPresented = "inttegro.payment_sheet.presented"
        /// Checkout retrieval began.
        case checkoutLoadStarted = "inttegro.checkout.load.started"
        /// Checkout retrieval produced a valid client-safe session.
        case checkoutLoadSucceeded = "inttegro.checkout.load.succeeded"
        /// Checkout retrieval failed.
        case checkoutLoadFailed = "inttegro.checkout.load.failed"
        /// A payment mutation began.
        case paymentAttemptStarted = "inttegro.payment.attempt.started"
        /// A recoverable payment attempt failed.
        case paymentAttemptFailed = "inttegro.payment.attempt.failed"
        /// Checkout requires a confirmation code.
        case confirmationRequired = "inttegro.payment.confirmation.required"
        /// Checkout is waiting for provider or device authorization.
        case authorizationRequired = "inttegro.payment.authorization.required"
        /// The SDK is polling Checkout for authoritative state.
        case statusPolling = "inttegro.payment.status.polling"
        /// The sheet reached its Checkout-confirmed success state.
        case sheetCompleted = "inttegro.payment_sheet.completed"
        /// The payer dismissed the sheet.
        case sheetCanceled = "inttegro.payment_sheet.canceled"
        /// A terminal SDK failure closed the flow.
        case sheetFailed = "inttegro.payment_sheet.failed"
        /// The Checkout transport prepared a request.
        case requestPrepared = "inttegro.request.prepared"
        /// An HTTP attempt began, including a safe retry.
        case httpAttemptStarted = "inttegro.http.attempt.started"
        /// A Checkout response arrived.
        case responseReceived = "inttegro.response.received"
        /// A Checkout response passed structural decoding.
        case responseDecoded = "inttegro.response.decoded"
        /// A Checkout transport or decoding operation failed.
        case requestFailed = "inttegro.request.failed"
    }

    /// Random identifier shared by events from one presentation.
    public let flowID: String
    /// Monotonically increasing event number within the flow.
    public let sequence: Int
    /// Stable lifecycle or transport event name.
    public let name: Name
    /// Time at which the native SDK emitted the event.
    public let timestamp: Date
    /// Fixed Checkout operation name for network events.
    public let operation: String?
    /// HTTP response status when a response was received.
    public let httpStatusCode: Int?
    /// Bounded Inttegro request identifier for support correlation.
    public let requestID: String?
    /// Bounded server-directed delay before retrying the operation.
    public let retryAfterSeconds: Int?
    /// Privacy-safe error category rather than a raw message.
    public let errorType: String?

    init(
        flowID: String,
        sequence: Int,
        name: Name,
        timestamp: Date,
        operation: String? = nil,
        httpStatusCode: Int? = nil,
        requestID: String? = nil,
        retryAfterSeconds: Int? = nil,
        errorType: String? = nil
    ) {
        self.flowID = flowID
        self.sequence = sequence
        self.name = name
        self.timestamp = timestamp
        self.operation = operation
        self.httpStatusCode = httpStatusCode
        self.requestID = requestID
        self.retryAfterSeconds = retryAfterSeconds
        self.errorType = errorType
    }
}

/// Dependency-free telemetry source owned by the host application.
///
/// Inttegro does not install an exporter. Hosts can translate these events into
/// their OpenTelemetry provider, logs, or another application-owned sink.
public final class PaymentSheetTelemetry: @unchecked Sendable {
    /// Host callback for ordered diagnostic events.
    public typealias EventHandler = @Sendable (PaymentSheetTelemetryEvent) -> Void

    /// Random identifier shared by every event from this telemetry source.
    public let flowID: String

    private let enabled: Bool
    private let traceParent: String?
    private let traceState: String?
    private let eventHandler: EventHandler?
    private let lock = NSLock()
    private var sequence = 0

    /// Creates a host-owned telemetry source for one presentation.
    ///
    /// The handler is invoked synchronously after the event sequence is
    /// allocated. Hand off expensive recording work rather than blocking the
    /// native payment state machine.
    ///
    /// - Parameters:
    ///   - configuration: Enablement and optional W3C trace context.
    ///   - eventHandler: Application callback, or `nil` to emit nothing.
    public init(
        configuration: PaymentSheetConfiguration.Telemetry = .init(),
        eventHandler: EventHandler? = nil
    ) {
        enabled = configuration.enabled
        traceParent = configuration.validTraceParent
        traceState = configuration.validTraceState
        self.eventHandler = eventHandler
        flowID = UUID().uuidString.lowercased()
    }

    init(
        configuration: PaymentSheetConfiguration.Telemetry,
        flowID: String,
        eventHandler: EventHandler?
    ) {
        enabled = configuration.enabled
        traceParent = configuration.validTraceParent
        traceState = configuration.validTraceState
        self.eventHandler = eventHandler
        self.flowID = flowID
    }

    func emit(
        _ name: PaymentSheetTelemetryEvent.Name,
        operation: String? = nil,
        httpStatusCode: Int? = nil,
        requestID: String? = nil,
        retryAfterSeconds: Int? = nil,
        errorType: String? = nil
    ) {
        guard enabled, let eventHandler else { return }
        let boundedRequestID = requestID.flatMap {
            (1 ... 255).contains($0.utf8.count) ? $0 : nil
        }
        let boundedRetryAfter = retryAfterSeconds.flatMap {
            (0 ... 300).contains($0) ? $0 : nil
        }
        lock.lock()
        sequence += 1
        let eventSequence = sequence
        lock.unlock()
        eventHandler(
            PaymentSheetTelemetryEvent(
                flowID: flowID,
                sequence: eventSequence,
                name: name,
                timestamp: Date(),
                operation: operation,
                httpStatusCode: httpStatusCode,
                requestID: boundedRequestID,
                retryAfterSeconds: boundedRetryAfter,
                errorType: errorType
            )
        )
    }

    func applyTraceContext(to request: inout URLRequest) {
        guard enabled else { return }
        if let traceParent {
            request.setValue(traceParent, forHTTPHeaderField: "traceparent")
        }
        if let traceState {
            request.setValue(traceState, forHTTPHeaderField: "tracestate")
        }
    }

    static func safeErrorType(_ error: Error) -> String {
        if let error = error as? URLError {
            return error.code == .timedOut ? "timeout" : "transport_error"
        }
        if let error = error as? PaymentSheetError {
            return safeErrorType(error.code)
        }
        if let error = error as? PaymentSheetRequestError {
            return safeErrorType(error.code)
        }
        return "sdk_error"
    }

    static func safeErrorType(_ code: String) -> String {
        if code.range(of: "^checkout_http_[1-5][0-9]{2}$", options: .regularExpression) != nil {
            return code
        }
        let allowed = [
            "checkout_expired",
            "checkout_unavailable",
            "confirmation_failed",
            "confirmation_request_failed",
            "invalid_checkout_response",
            "payment_method_required",
            "payment_requires_action",
            "payment_sheet_already_presented",
            "payment_sheet_failed",
            "unsupported_payment_method",
        ]
        return allowed.contains(code) ? code : "sdk_error"
    }
}
