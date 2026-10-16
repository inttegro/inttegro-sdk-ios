import Foundation

final class CheckoutLifecycle: @unchecked Sendable {
    typealias EventHandler = @Sendable (CheckoutEvent) -> Void

    let flowID: String

    private let eventHandler: EventHandler?
    private let lock = NSLock()
    private var sequence = 0

    init(flowID: String = UUID().uuidString.lowercased(), eventHandler: EventHandler?) {
        self.flowID = flowID
        self.eventHandler = eventHandler
    }

    @discardableResult
    func emit(
        _ type: CheckoutEvent.Kind,
        order: CheckoutOrder? = nil,
        action: CheckoutAction? = nil,
        failure: CheckoutFailure? = nil,
        complete: Bool? = nil,
        paymentMethod: String? = nil
    ) -> CheckoutEvent {
        lock.lock()
        sequence += 1
        let eventSequence = sequence
        lock.unlock()
        let event = CheckoutEvent(
            type: type,
            occurredAt: Date(),
            flowID: flowID,
            sequence: eventSequence,
            order: order,
            action: action,
            failure: failure,
            complete: complete,
            paymentMethod: paymentMethod
        )
        eventHandler?(event)
        return event
    }
}

extension PaymentSheetFailure {
    func checkoutFailure(recoverable: Bool) -> CheckoutFailure {
        let publicMessage = switch code {
        case "checkout_expired":
            "This checkout has expired."
        case "unsupported_payment_method":
            "This payment method is not supported by this SDK version."
        default:
            recoverable
                ? "The payment did not complete. Check the details and try again."
                : "Checkout could not continue. Try again or contact the merchant."
        }
        return .init(code: code, message: publicMessage, recoverable: recoverable)
    }
}
