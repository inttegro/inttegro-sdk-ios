import Foundation
import Testing
@testable import Inttegro

@Suite("Payment sheet bridge")
struct PaymentSheetBridgeTests {
    @Test("Decodes the shared configuration payload")
    func decodesConfiguration() throws {
        let configuration = try PaymentSheetConfiguration(
            bridgePayload: [
                "orderId": "  or_test  ",
                "returnURL": "merchant-app://inttegro-return",
                "appearance": [
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
        #expect(configuration.returnURL?.absoluteString == "merchant-app://inttegro-return")
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
        #expect(
            NSDictionary(
                dictionary: PaymentSheetResult.completed(
                    paymentID: "py_test"
                ).bridgePayload
            ) == [
                "status": "completed",
                "paymentId": "py_test",
            ] as NSDictionary
        )
        #expect(
            NSDictionary(
                dictionary: PaymentSheetResult.failed(
                    .init(
                        code: "declined",
                        message: "Payment declined.",
                        declineCode: "insufficient_funds"
                    )
                ).bridgePayload
            ) == [
                "status": "failed",
                "error": [
                    "code": "declined",
                    "message": "Payment declined.",
                    "declineCode": "insufficient_funds",
                ],
            ] as NSDictionary
        )
    }
}
