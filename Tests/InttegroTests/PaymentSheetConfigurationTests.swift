import Foundation
import Testing
@testable import Inttegro

@Suite("Payment sheet configuration")
struct PaymentSheetConfigurationTests {
    @Test("Trims the checkout Order ID")
    func trimsOrderID() throws {
        let configuration = try PaymentSheetConfiguration(
            orderID: "  or_test  "
        )

        #expect(configuration.orderID == "or_test")
    }

    @Test("Rejects an empty checkout Order ID")
    func rejectsEmptyOrderID() {
        #expect(throws: PaymentSheetError.self) {
            try PaymentSheetConfiguration(orderID: "   ")
        }
    }

    @Test("Rejects corner radii outside the bridge contract")
    func rejectsInvalidCornerRadius() {
        #expect(throws: PaymentSheetError.self) {
            try PaymentSheetConfiguration(
                orderID: "or_test",
                appearance: .init(cornerRadius: 41)
            )
        }
    }

    @Test("Requires an absolute return URL")
    func rejectsRelativeReturnURL() {
        #expect(throws: PaymentSheetError.self) {
            try PaymentSheetConfiguration(
                orderID: "or_test",
                returnURL: URL(string: "relative/path")
            )
        }
    }

    @Test("Rejects malformed appearance colors")
    func rejectsMalformedColor() {
        #expect(throws: PaymentSheetError.self) {
            try PaymentSheetConfiguration(
                orderID: "or_test",
                appearance: .init(primaryColor: "purple")
            )
        }
    }
}
