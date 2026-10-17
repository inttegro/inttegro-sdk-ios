import Foundation
import Testing
@testable import Inttegro
@testable import InttegroBridge

@Suite("Payment sheet bridge")
struct PaymentSheetBridgeTests {
    @Test("Decodes the shared configuration payload")
    func decodesConfiguration() throws {
        let configuration = try PaymentSheetConfiguration(
            bridgePayload: [
                "orderId": "  or_test  ",
                "title": "Complete contribution",
                "returnURL": "merchant-app://inttegro-return",
                "appearance": [
                    "theme": "dark",
                    "primaryColor": "#112233",
                    "cornerRadius": 24,
                ],
                "telemetry": [
                    "enabled": true,
                    "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                    "tracestate": "vendor=value",
                ],
                "features": [
                    "showLineItems": true,
                    "showInvoiceDownload": true,
                    "showReceiptDownload": true,
                    "allowPaymentMethodChange": false,
                ],
            ] as NSDictionary
        )

        #expect(configuration.orderID == "or_test")
        #expect(configuration.title == "Complete contribution")
        #expect(configuration.returnURL?.absoluteString == "merchant-app://inttegro-return")
        #expect(configuration.appearance.theme == .dark)
        #expect(configuration.appearance.primaryColor == "#112233")
        #expect(configuration.appearance.cornerRadius == 24)
        #expect(configuration.telemetry.enabled)
        #expect(
            configuration.telemetry.traceParent
                == "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        )
        #expect(configuration.telemetry.traceState == "vendor=value")
        #expect(configuration.features.showLineItems)
        #expect(configuration.features.showInvoiceDownload)
        #expect(configuration.features.showReceiptDownload)
        #expect(!configuration.features.allowPaymentMethodChange)
    }

    @Test("Decodes a customer-selected Purchase Intent")
    func decodesPurchaseIntentConfiguration() throws {
        let configuration = try PaymentSheetConfiguration(
            bridgePayload: ["purchaseIntentId": "sale_test"] as NSDictionary
        )

        #expect(configuration.purchaseIntentID == "sale_test")
        #expect(configuration.orderID == nil)
    }

    @Test("Rejects malformed nested configuration")
    func rejectsMalformedConfiguration() throws {
        #expect(throws: (any Error).self) {
            _ = try PaymentSheetConfiguration(
                bridgePayload: [
                    "orderId": "or_test",
                    "appearance": ["cornerRadius": "large"],
                ] as NSDictionary
            )
        }
    }

    @Test("Rejects an unknown color scheme")
    func rejectsUnknownTheme() {
        #expect(throws: (any Error).self) {
            _ = try PaymentSheetConfiguration(
                bridgePayload: [
                    "orderId": "or_test",
                    "appearance": ["theme": "sepia"],
                ] as NSDictionary
            )
        }
    }

    @Test("Rejects legacy wallet configuration")
    func rejectsWalletConfiguration() {
        #expect(throws: (any Error).self) {
            _ = try PaymentSheetConfiguration(
                bridgePayload: [
                    "orderId": "or_test",
                    "wallets": ["googlePayEnvironment": "test"],
                ] as NSDictionary
            )
        }
    }

    @Test("Encodes only terminal public results")
    func encodesResults() {
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Acme"),
            amount: .init(value: 1_500, currency: "ghs"),
            paymentMethods: [],
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let lifecycle = CheckoutLifecycle(
            flowID: "550e8400-e29b-41d4-a716-446655440000",
            eventHandler: nil
        )
        let completed = PaymentSheetResult.completed(
            lifecycle.emit(
                .completed,
                order: CheckoutOrder(session: session, status: .paid)
            )
        ).bridgePayload
        #expect(completed["type"] as? String == "completed")
        #expect((completed["order"] as? [String: Any])?["id"] as? String == "or_test")

        let failed = PaymentSheetResult.failed(
            lifecycle.emit(
                .failed,
                order: CheckoutOrder(session: session, status: .failed),
                failure: .init(
                    code: "payment_failed",
                    message: "Payment failed.",
                    recoverable: false
                )
            )
        ).bridgePayload
        #expect(failed["type"] as? String == "failed")
        #expect(
            (failed["failure"] as? [String: Any])?["code"] as? String
                == "payment_failed"
        )
        #expect((failed["failure"] as? [String: Any])?["recoverable"] as? Bool == false)
    }
}
