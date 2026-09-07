import Foundation

public protocol PaymentSheetAdapter: Sendable {
    func retrieveCheckout(orderID: String) async throws -> PaymentSheetSession
    func pay(
        session: PaymentSheetSession,
        selection: PaymentSheetPaymentSelection
    ) async throws -> PaymentSheetPaymentOutcome
    func requestConfirmation(
        session: PaymentSheetSession,
        challenge: PaymentSheetConfirmationChallenge
    ) async throws -> PaymentSheetPaymentOutcome
    func confirmPayment(
        session: PaymentSheetSession,
        challenge: PaymentSheetConfirmationChallenge,
        token: String
    ) async throws -> PaymentSheetPaymentOutcome
    func refreshPayment(
        session: PaymentSheetSession
    ) async throws -> PaymentSheetPaymentOutcome
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
public struct PreviewPaymentSheetAdapter: PaymentSheetAdapter {
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
