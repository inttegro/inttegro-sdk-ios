import CoreFoundation
import Foundation
import UIKit

#if SWIFT_PACKAGE
import Inttegro
#endif

/// Stateful, Objective-C-compatible entry point used by cross-platform SDKs.
///
/// Each React Native module or Flutter plugin instance owns one coordinator so
/// configuration and presentation state never leak between application engines.
@MainActor
@objc(InttegroPaymentSheetCoordinator)
public final class PaymentSheetCoordinator: NSObject {
    /// Objective-C completion used when validating cross-platform configuration.
    public typealias InitializationCompletion = (String?, String?) -> Void
    /// Objective-C completion containing a result payload or stable error.
    public typealias PresentationCompletion = (NSDictionary?, String?, String?) -> Void
    /// Objective-C callback for privacy-safe diagnostic payloads.
    public typealias TelemetryEventHandler = (NSDictionary) -> Void

    private var configuration: PaymentSheetConfiguration?
    private var activeSheet: PaymentSheet?
    private var telemetryEventHandler: TelemetryEventHandler?

    /// Replaces the host callback that receives bridge-safe diagnostic events.
    ///
    /// Cross-platform adapters should install this before presentation and clear
    /// it when their engine or module is invalidated.
    ///
    /// - Parameter handler: Callback for ordered, bridge-safe event dictionaries,
    ///   or `nil` to stop forwarding diagnostics.
    @objc(setTelemetryEventHandler:)
    public func setTelemetryEventHandler(_ handler: TelemetryEventHandler?) {
        telemetryEventHandler = handler
    }

    /// Validates and stores a versioned dictionary from a framework adapter.
    ///
    /// Native Swift applications should construct `PaymentSheetConfiguration`
    /// from the `Inttegro` product directly instead of calling this bridge.
    ///
    /// - Parameters:
    ///   - payload: Versioned configuration containing a public Order ID and
    ///     optional presentation settings.
    ///   - completion: Called with `nil` values on success or a stable error code
    ///     and message when validation fails.
    @objc(initializePaymentSheet:completion:)
    public func initializePaymentSheet(
        _ payload: NSDictionary,
        completion: InitializationCompletion
    ) {
        guard activeSheet == nil else {
            completion(
                "payment_sheet_already_presented",
                "The payment sheet is already presented."
            )
            return
        }

        do {
            configuration = try PaymentSheetConfiguration(bridgePayload: payload)
            completion(nil, nil)
        } catch {
            completion("invalid_configuration", error.localizedDescription)
        }
    }

    /// Presents the configured native sheet for a framework adapter.
    ///
    /// The completion is invoked exactly once with a bridge-safe terminal result
    /// or a stable initialization/presentation error.
    ///
    /// - Parameters:
    ///   - presentingViewController: Visible controller that owns presentation.
    ///   - completion: Called with a terminal result dictionary or a stable error
    ///     code and message when presentation cannot start.
    @objc(presentPaymentSheetFrom:completion:)
    public func presentPaymentSheet(
        from presentingViewController: UIViewController,
        completion: @escaping PresentationCompletion
    ) {
        guard activeSheet == nil else {
            completion(
                nil,
                "payment_sheet_already_presented",
                "The payment sheet is already presented."
            )
            return
        }
        guard let configuration else {
            completion(
                nil,
                "payment_sheet_not_initialized",
                "Initialize the payment sheet before presenting it."
            )
            return
        }

        let sheet = PaymentSheet(
            configuration: configuration,
            telemetryEventHandler: { [weak self] event in
                guard let self else { return }
                let payload = event.bridgePayload as NSDictionary
                Task { @MainActor in
                    self.telemetryEventHandler?(payload)
                }
            }
        )
        activeSheet = sheet
        sheet.present(from: presentingViewController) { [weak self] result in
            self?.activeSheet = nil
            completion(result.bridgePayload as NSDictionary, nil, nil)
        }
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
        if let retryAfterSeconds { value["retryAfterSeconds"] = retryAfterSeconds }
        if let errorType { value["errorType"] = errorType }
        return value
    }
}

extension PaymentSheetConfiguration {
    init(bridgePayload payload: NSDictionary) throws {
        let rawOrderID = payload["orderId"] as? String
        let rawPurchaseIntentID = payload["purchaseIntentId"] as? String
        guard (rawOrderID != nil) != (rawPurchaseIntentID != nil) else {
            throw PaymentSheetBridgeError(
                "Provide exactly one of orderId or purchaseIntentId"
            )
        }
        if payload["wallets"] != nil {
            throw PaymentSheetBridgeError(
                "wallets is not supported; Apple Pay and Google Pay are not available"
            )
        }

        let returnURL: URL?
        if let value = payload["returnURL"] {
            guard let rawURL = value as? String, let parsedURL = URL(string: rawURL) else {
                throw PaymentSheetBridgeError("returnURL must be an absolute URL")
            }
            returnURL = parsedURL
        } else {
            returnURL = nil
        }

        let appearance = try Self.bridgeAppearance(payload["appearance"])
        let telemetry = try Self.bridgeTelemetry(payload["telemetry"])
        let features = try Self.bridgeFeatures(payload["features"])
        if let rawOrderID {
            try self.init(
                orderID: rawOrderID,
                returnURL: returnURL,
                appearance: appearance,
                telemetry: telemetry,
                features: features
            )
        } else {
            try self.init(
                purchaseIntentID: rawPurchaseIntentID!,
                returnURL: returnURL,
                appearance: appearance,
                telemetry: telemetry,
                features: features
            )
        }
    }

    private static func bridgeAppearance(_ value: Any?) throws -> Appearance {
        guard let value else { return .init() }
        guard let payload = value as? NSDictionary else {
            throw PaymentSheetBridgeError("appearance must be an object")
        }
        let cornerRadius: Double?
        if let value = payload["cornerRadius"] {
            guard let number = value as? NSNumber else {
                throw PaymentSheetBridgeError("appearance.cornerRadius must be a number")
            }
            cornerRadius = number.doubleValue
        } else {
            cornerRadius = nil
        }
        return try .init(
            primaryColor: bridgeString(payload, key: "primaryColor"),
            backgroundColor: bridgeString(payload, key: "backgroundColor"),
            textColor: bridgeString(payload, key: "textColor"),
            cornerRadius: cornerRadius
        )
    }

    private static func bridgeTelemetry(_ value: Any?) throws -> Telemetry {
        guard let value else { return .init() }
        guard let payload = value as? NSDictionary else {
            throw PaymentSheetBridgeError("telemetry must be an object")
        }
        let enabled: Bool
        if let value = payload["enabled"] {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw PaymentSheetBridgeError("telemetry.enabled must be a boolean")
            }
            enabled = number.boolValue
        } else {
            enabled = true
        }
        return .init(
            enabled: enabled,
            traceParent: try bridgeString(payload, key: "traceparent"),
            traceState: try bridgeString(payload, key: "tracestate")
        )
    }

    private static func bridgeFeatures(_ value: Any?) throws -> Features {
        guard let value else { return .init() }
        guard let payload = value as? NSDictionary else {
            throw PaymentSheetBridgeError("features must be an object")
        }
        return .init(
            showLineItems: try bridgeBoolean(payload, key: "showLineItems") ?? false,
            showInvoiceDownload: try bridgeBoolean(payload, key: "showInvoiceDownload") ?? false,
            showReceiptDownload: try bridgeBoolean(payload, key: "showReceiptDownload") ?? false,
            allowPaymentMethodChange: try bridgeBoolean(
                payload,
                key: "allowPaymentMethodChange"
            ) ?? true
        )
    }

    private static func bridgeBoolean(
        _ payload: NSDictionary,
        key: String
    ) throws -> Bool? {
        guard let value = payload[key] else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw PaymentSheetBridgeError("features.\(key) must be a boolean")
        }
        return number.boolValue
    }

    private static func bridgeString(
        _ payload: NSDictionary,
        key: String
    ) throws -> String? {
        guard let value = payload[key] else { return nil }
        guard let value = value as? String else {
            throw PaymentSheetBridgeError("\(key) must be a string")
        }
        return value
    }
}

extension PaymentSheetResult {
    var bridgePayload: [String: Any] {
        switch self {
        case let .completed(paymentID):
            var payload: [String: Any] = ["status": "completed"]
            if let paymentID { payload["paymentId"] = paymentID }
            return payload
        case .canceled:
            return ["status": "canceled"]
        case let .failed(failure):
            var error: [String: Any] = [
                "code": failure.code,
                "message": failure.message,
            ]
            if let declineCode = failure.declineCode {
                error["declineCode"] = declineCode
            }
            if let requestID = failure.requestID {
                error["requestId"] = requestID
            }
            if let retryAfterSeconds = failure.retryAfterSeconds {
                error["retryAfterSeconds"] = retryAfterSeconds
            }
            return [
                "status": "failed",
                "error": error,
            ]
        }
    }
}

private struct PaymentSheetBridgeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
