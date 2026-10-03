import Foundation

/// Operations required by Inttegro's native payment state machine.
///
/// The SDK ships ``CheckoutPaymentSheetAdapter`` for production use. Implement
/// this protocol only for deterministic previews, tests, or a controlled
/// transport that preserves Checkout's read-and-pay boundary. Implementations
/// must keep retries idempotent and return `.pending` until the authoritative
/// payment has actually completed.
public protocol PaymentSheetAdapter: Sendable {
    /// Retrieves the client-safe Checkout projection for a finalized Order.
    ///
    /// - Parameter orderID: Public Order identifier created by the backend.
    /// - Returns: Current display and collection data for this presentation.
    func retrieveCheckout(orderID: String) async throws -> PaymentSheetSession

    /// Loads the client-safe amount policy for a Purchase Intent.
    func retrieveAmountSelection(
        purchaseIntentID: String
    ) async throws -> PaymentSheetAmountSelection

    /// Creates the finalized Order for a valid selected amount.
    func selectAmount(
        purchaseIntentID: String,
        amount: PaymentSheetSession.Money
    ) async throws -> PaymentSheetSession

    /// Updates the amount on the same finalized Order before payment starts.
    func updateAmount(
        orderID: String,
        lineItemID: String,
        amount: PaymentSheetSession.Money
    ) async throws -> PaymentSheetSession

    /// Starts or safely retries payment using the payer's current selection.
    ///
    /// - Parameters:
    ///   - session: Session previously returned by `retrieveCheckout`.
    ///   - selection: Saved method or newly collected Mobile Money details.
    /// - Returns: Completion, a confirmation challenge, or pending authorization.
    func pay(
        session: PaymentSheetSession,
        selection: PaymentSheetPaymentSelection
    ) async throws -> PaymentSheetPaymentOutcome

    /// Requests a replacement code for a recoverable confirmation challenge.
    func requestConfirmation(
        session: PaymentSheetSession,
        challenge: PaymentSheetConfirmationChallenge
    ) async throws -> PaymentSheetPaymentOutcome

    /// Submits the payer's confirmation code to Checkout.
    func confirmPayment(
        session: PaymentSheetSession,
        challenge: PaymentSheetConfirmationChallenge,
        token: String
    ) async throws -> PaymentSheetPaymentOutcome

    /// Refreshes asynchronous payment state after provider authorization.
    func refreshPayment(
        session: PaymentSheetSession
    ) async throws -> PaymentSheetPaymentOutcome
}

public extension PaymentSheetAdapter {
    func retrieveAmountSelection(
        purchaseIntentID _: String
    ) async throws -> PaymentSheetAmountSelection {
        throw PaymentSheetError.checkoutUnavailable
    }

    func selectAmount(
        purchaseIntentID _: String,
        amount _: PaymentSheetSession.Money
    ) async throws -> PaymentSheetSession {
        throw PaymentSheetError.checkoutUnavailable
    }

    func updateAmount(
        orderID _: String,
        lineItemID _: String,
        amount _: PaymentSheetSession.Money
    ) async throws -> PaymentSheetSession {
        throw PaymentSheetError.checkoutUnavailable
    }
}

struct UnavailablePaymentSheetAdapter: PaymentSheetAdapter {
    func retrieveCheckout(orderID _: String) async throws -> PaymentSheetSession {
        throw PaymentSheetError.checkoutUnavailable
    }

    func pay(
        session _: PaymentSheetSession,
        selection _: PaymentSheetPaymentSelection
    ) async throws -> PaymentSheetPaymentOutcome {
        throw PaymentSheetError.checkoutUnavailable
    }

    func requestConfirmation(
        session _: PaymentSheetSession,
        challenge _: PaymentSheetConfirmationChallenge
    ) async throws -> PaymentSheetPaymentOutcome {
        throw PaymentSheetError.checkoutUnavailable
    }

    func confirmPayment(
        session _: PaymentSheetSession,
        challenge _: PaymentSheetConfirmationChallenge,
        token _: String
    ) async throws -> PaymentSheetPaymentOutcome {
        throw PaymentSheetError.checkoutUnavailable
    }

    func refreshPayment(
        session _: PaymentSheetSession
    ) async throws -> PaymentSheetPaymentOutcome {
        throw PaymentSheetError.checkoutUnavailable
    }
}

#if DEBUG
/// Deterministic adapter for previews and debug-only interface review.
///
/// It never contacts Inttegro or initiates a real payment and is not compiled
/// into release builds.
public struct PreviewPaymentSheetAdapter: PaymentSheetAdapter {
    /// Creates the deterministic debug adapter.
    public init() {}

    public func retrieveCheckout(orderID _: String) async throws -> PaymentSheetSession {
        try await Task.sleep(for: .milliseconds(350))
        return .preview
    }

    public func pay(
        session _: PaymentSheetSession,
        selection _: PaymentSheetPaymentSelection
    ) async throws -> PaymentSheetPaymentOutcome {
        try await Task.sleep(for: .milliseconds(650))
        return .completed(paymentID: "py_preview")
    }

    public func requestConfirmation(
        session _: PaymentSheetSession,
        challenge _: PaymentSheetConfirmationChallenge
    ) async throws -> PaymentSheetPaymentOutcome {
        try await Task.sleep(for: .milliseconds(350))
        return .requiresConfirmation(.init(recipient: "••• ••• 0042", sentVia: "sms"))
    }

    public func confirmPayment(
        session _: PaymentSheetSession,
        challenge _: PaymentSheetConfirmationChallenge,
        token _: String
    ) async throws -> PaymentSheetPaymentOutcome {
        try await Task.sleep(for: .milliseconds(650))
        return .completed(paymentID: "py_preview")
    }

    public func refreshPayment(
        session _: PaymentSheetSession
    ) async throws -> PaymentSheetPaymentOutcome {
        return .completed(paymentID: "py_preview")
    }
}

extension PaymentSheetSession {
    static let preview = PaymentSheetSession(
        id: "or_preview",
        merchant: .init(
            displayName: "Field & Form",
            supportText: "Payment secured by Inttegro"
        ),
        amount: .init(value: 12_500, currency: "GHS"),
        paymentMethods: [
            .init(
                id: "zebo_wallet",
                kind: .zeboWallet,
                label: "Zebo Wallet",
                detail: "Use a saved payment method"
            ),
            .init(
                id: "mobile_money",
                kind: .mobileMoney,
                source: .new,
                label: "Mobile money",
                detail: "MTN MoMo, Telecel Cash, or AirtelTigo Money"
            ),
        ],
        expiresAt: Date().addingTimeInterval(15 * 60)
    )
}
#endif
