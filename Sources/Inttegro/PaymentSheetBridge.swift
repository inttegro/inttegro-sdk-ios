import CoreFoundation
import Foundation
import UIKit

/// Stateful, Objective-C-compatible entry point used by cross-platform SDKs.
///
/// Each React Native module or Flutter plugin instance owns one coordinator so
/// configuration and presentation state never leak between application engines.
@MainActor
@objc(InttegroPaymentSheetCoordinator)
public final class PaymentSheetCoordinator: NSObject {
    public typealias InitializationCompletion = (String?, String?) -> Void
    public typealias PresentationCompletion = (NSDictionary?, String?, String?) -> Void
    public typealias TelemetryEventHandler = (NSDictionary) -> Void

    private var configuration: PaymentSheetConfiguration?
    private var activeSheet: PaymentSheet?
    private var telemetryEventHandler: TelemetryEventHandler?

    @objc(setTelemetryEventHandler:)
    public func setTelemetryEventHandler(_ handler: TelemetryEventHandler?) {
        telemetryEventHandler = handler
    }

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

extension PaymentSheetConfiguration {
    init(bridgePayload payload: NSDictionary) throws {
        guard let rawOrderID = payload["orderId"] as? String else {
            throw PaymentSheetBridgeError("orderId must be a string")
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
        try self.init(
            orderID: rawOrderID,
            returnURL: returnURL,
            appearance: appearance,
            telemetry: telemetry
        )
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
