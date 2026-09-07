import Foundation

public struct PaymentSheetTelemetryEvent: Sendable, Equatable {
    public enum Name: String, Sendable, CaseIterable {
        case sheetPresented = "inttegro.payment_sheet.presented"
        case checkoutLoadStarted = "inttegro.checkout.load.started"
        case checkoutLoadSucceeded = "inttegro.checkout.load.succeeded"
        case checkoutLoadFailed = "inttegro.checkout.load.failed"
        case paymentAttemptStarted = "inttegro.payment.attempt.started"
        case paymentAttemptFailed = "inttegro.payment.attempt.failed"
        case confirmationRequired = "inttegro.payment.confirmation.required"
        case authorizationRequired = "inttegro.payment.authorization.required"
        case statusPolling = "inttegro.payment.status.polling"
        case sheetCompleted = "inttegro.payment_sheet.completed"
        case sheetCanceled = "inttegro.payment_sheet.canceled"
        case sheetFailed = "inttegro.payment_sheet.failed"
        case requestPrepared = "inttegro.request.prepared"
        case httpAttemptStarted = "inttegro.http.attempt.started"
        case responseReceived = "inttegro.response.received"
        case responseDecoded = "inttegro.response.decoded"
        case requestFailed = "inttegro.request.failed"
    }

    public let flowID: String
    public let sequence: Int
    public let name: Name
    public let timestamp: Date
    public let operation: String?
    public let httpStatusCode: Int?
    public let requestID: String?
    public let errorType: String?

    init(
        flowID: String,
        sequence: Int,
        name: Name,
        timestamp: Date,
        operation: String? = nil,
        httpStatusCode: Int? = nil,
        requestID: String? = nil,
        errorType: String? = nil
    ) {
        self.flowID = flowID
        self.sequence = sequence
        self.name = name
        self.timestamp = timestamp
        self.operation = operation
        self.httpStatusCode = httpStatusCode
        self.requestID = requestID
        self.errorType = errorType
    }
}

/// Dependency-free telemetry source owned by the host application.
///
/// Inttegro does not install an exporter. Hosts can translate these events into
/// their OpenTelemetry provider, logs, or another application-owned sink.
public final class PaymentSheetTelemetry: @unchecked Sendable {
    public typealias EventHandler = @Sendable (PaymentSheetTelemetryEvent) -> Void

    public let flowID: String

    private let enabled: Bool
    private let traceParent: String?
    private let traceState: String?
    private let eventHandler: EventHandler?
    private let lock = NSLock()
    private var sequence = 0

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
        errorType: String? = nil
    ) {
        guard enabled, let eventHandler else { return }
        let boundedRequestID = requestID.flatMap {
            (1 ... 255).contains($0.utf8.count) ? $0 : nil
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

extension PaymentSheetTelemetryEvent {
    var bridgePayload: [String: Any] {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var value: [String: Any] = [
            "flowId": flowID,
            "sequence": sequence,
            "name": name.rawValue,
            "timestamp": timestampFormatter.string(from: timestamp),
        ]
        if let operation { value["operation"] = operation }
        if let httpStatusCode { value["httpStatusCode"] = httpStatusCode }
        if let requestID { value["requestId"] = requestID }
        if let errorType { value["errorType"] = errorType }
        return value
    }
}
