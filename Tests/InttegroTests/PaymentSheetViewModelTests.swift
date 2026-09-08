import Foundation
import Testing
@testable import Inttegro

@Suite("Payment sheet view model")
struct PaymentSheetViewModelTests {
    @Test("Suggests a network and preserves a ported-number override")
    @MainActor
    func suggestsAndOverridesNetwork() async throws {
        let model = PaymentSheetViewModel(
            configuration: try .init(orderID: "or_test"),
            adapter: ViewModelAdapter(session: session())
        )
        await model.load()

        model.mobileMoneyAccountNumber = "024"

        #expect(model.networkSelectorRevealed)
        #expect(model.mobileMoneyNetwork == .mtn)
        #expect(
            model.networkSuggestionHint
                == "Suggested MTN from prefix 024. Change it if this number has been ported."
        )

        model.selectMobileMoneyNetwork(.telecel)
        #expect(
            model.networkSuggestionHint
                == "This number is usually associated with MTN, but you can continue with "
                    + "Telecel if this number was moved."
        )

        model.mobileMoneyAccountNumber = ""
        #expect(model.networkSelectorRevealed)
        #expect(model.mobileMoneyNetwork == .telecel)
    }

    @Test("Requires a network when the account prefix is unknown")
    @MainActor
    func requiresNetworkForUnknownPrefix() async throws {
        let adapter = ViewModelAdapter(session: session())
        let model = PaymentSheetViewModel(
            configuration: try .init(orderID: "or_test"),
            adapter: adapter
        )
        await model.load()

        model.mobileMoneyAccountNumber = "0991234567"

        #expect(model.mobileMoneyNetwork == nil)
        #expect(!model.canPay)
        #expect(
            model.networkSuggestionHint
                == "We could not match that prefix. Choose the current network for this account."
        )
        #expect(await model.pay() == nil)
        #expect(
            model.validationMessage(for: .network)
                == "Choose the current network for this account."
        )
        #expect(await adapter.payCallCount == 0)
    }

    @Test("Validates payer input without clearing it")
    @MainActor
    func validatesPayerInput() async throws {
        let adapter = ViewModelAdapter(session: session())
        let model = PaymentSheetViewModel(
            configuration: try .init(orderID: "or_test"),
            adapter: adapter
        )
        await model.load()
        model.mobileMoneyAccountNumber = "12"
        model.savePaymentMethod = true
        model.billingName = ""
        model.billingCountry = "Ireland"

        let result = await model.pay()

        #expect(result == nil)
        guard case .ready = model.state else {
            Issue.record("Expected the sheet to remain ready")
            return
        }
        #expect(model.mobileMoneyAccountNumber == "12")
        #expect(
            model.validationMessage(for: .accountNumber)
                == "Enter the 10-digit mobile money number."
        )
        #expect(
            model.validationMessage(for: .billingName)
                == "Enter your name to save this account."
        )
        #expect(await adapter.payCallCount == 0)
    }

    @Test("Enters confirmation and validates the exact token size")
    @MainActor
    func validatesConfirmationToken() async throws {
        let challenge = PaymentSheetConfirmationChallenge(
            paymentID: "py_test",
            confirmationID: "sc_test",
            tokenSize: 6
        )
        let adapter = ViewModelAdapter(
            session: session(),
            payOutcome: .requiresConfirmation(challenge)
        )
        let model = PaymentSheetViewModel(
            configuration: try .init(orderID: "or_test"),
            adapter: adapter
        )
        await model.load()
        model.mobileMoneyAccountNumber = "0244000042"

        #expect(await model.pay() == nil)
        guard case .confirmation = model.state else {
            Issue.record("Expected the sheet to require confirmation")
            return
        }

        model.confirmationToken = "123"
        #expect(await model.submitConfirmation() == nil)
        #expect(
            model.validationMessage(for: .confirmationToken)
                == "Enter the 6-digit code."
        )
        #expect(model.confirmationToken == "123")
        #expect(await adapter.confirmCallCount == 0)
    }

    @Test("Awaits provider authorization and completes after refresh")
    @MainActor
    func refreshesProviderAuthorization() async throws {
        let action = PaymentSheetExternalAction.authorize(
            scheme: "mobile_money",
            expiresAt: nil
        )
        let adapter = ViewModelAdapter(
            session: session(),
            payOutcome: .pending(action),
            refreshOutcome: .completed(paymentID: "py_test")
        )
        let model = PaymentSheetViewModel(
            configuration: try .init(orderID: "or_test"),
            adapter: adapter
        )
        await model.load()
        model.mobileMoneyAccountNumber = "0244000042"

        #expect(await model.pay() == nil)
        guard case let .awaitingResult(_, pendingAction, false, nil) = model.state else {
            Issue.record("Expected the sheet to await provider authorization")
            return
        }
        #expect(pendingAction == action)
        #expect(await model.refreshPayment() == nil)
        guard case let .completed(completedSession, paymentID, _) = model.state else {
            Issue.record("Expected the sheet to show payment completion")
            return
        }
        #expect(completedSession.id == "or_test")
        #expect(paymentID == "py_test")
        #expect(model.completedResult == .completed(paymentID: "py_test"))
        #expect(await adapter.refreshCallCount == 1)
    }

    @Test("Emits confirmation and provider authorization lifecycle events")
    @MainActor
    func emitsConfirmationAndAuthorizationEvents() async throws {
        let challenge = PaymentSheetConfirmationChallenge(
            paymentID: "py_test",
            confirmationID: "sc_test",
            tokenSize: 6
        )
        let events = ViewModelTelemetryEventStore()
        let telemetry = PaymentSheetTelemetry(
            configuration: .init(),
            flowID: "550e8400-e29b-41d4-a716-446655440000",
            eventHandler: events.append
        )
        let adapter = ViewModelAdapter(
            session: session(),
            payOutcome: .requiresConfirmation(challenge),
            confirmOutcome: .pending(.authorize(scheme: "mtn", expiresAt: nil))
        )
        let model = PaymentSheetViewModel(
            configuration: try .init(orderID: "or_test"),
            adapter: adapter,
            telemetry: telemetry
        )

        await model.load()
        model.mobileMoneyAccountNumber = "0244000042"
        #expect(await model.pay() == nil)
        model.confirmationToken = "123456"
        #expect(await model.submitConfirmation() == nil)

        #expect(events.snapshot().map(\.name) == [
            .checkoutLoadStarted,
            .checkoutLoadSucceeded,
            .paymentAttemptStarted,
            .confirmationRequired,
            .authorizationRequired,
        ])
    }

    private func session() -> PaymentSheetSession {
        PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [
                .init(
                    id: "new_mobile_money",
                    kind: .mobileMoney,
                    source: .new,
                    label: "Mobile money"
                ),
            ],
            expiresAt: .distantFuture
        )
    }
}

private actor ViewModelAdapter: PaymentSheetAdapter {
    private let session: PaymentSheetSession
    private let payOutcome: PaymentSheetPaymentOutcome
    private let confirmOutcome: PaymentSheetPaymentOutcome
    private let refreshOutcome: PaymentSheetPaymentOutcome
    private(set) var payCallCount = 0
    private(set) var confirmCallCount = 0
    private(set) var refreshCallCount = 0

    init(
        session: PaymentSheetSession,
        payOutcome: PaymentSheetPaymentOutcome = .completed(paymentID: "py_test"),
        confirmOutcome: PaymentSheetPaymentOutcome = .completed(paymentID: "py_test"),
        refreshOutcome: PaymentSheetPaymentOutcome = .completed(paymentID: "py_test")
    ) {
        self.session = session
        self.payOutcome = payOutcome
        self.confirmOutcome = confirmOutcome
        self.refreshOutcome = refreshOutcome
    }

    func retrieveCheckout(orderID _: String) async throws -> PaymentSheetSession {
        session
    }

    func pay(
        session _: PaymentSheetSession,
        selection _: PaymentSheetPaymentSelection
    ) async throws -> PaymentSheetPaymentOutcome {
        payCallCount += 1
        return payOutcome
    }

    func requestConfirmation(
        session _: PaymentSheetSession,
        challenge: PaymentSheetConfirmationChallenge
    ) async throws -> PaymentSheetPaymentOutcome {
        .requiresConfirmation(challenge)
    }

    func confirmPayment(
        session _: PaymentSheetSession,
        challenge _: PaymentSheetConfirmationChallenge,
        token _: String
    ) async throws -> PaymentSheetPaymentOutcome {
        confirmCallCount += 1
        return confirmOutcome
    }

    func refreshPayment(
        session _: PaymentSheetSession
    ) async throws -> PaymentSheetPaymentOutcome {
        refreshCallCount += 1
        return refreshOutcome
    }
}

private final class ViewModelTelemetryEventStore: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PaymentSheetTelemetryEvent] = []

    func append(_ event: PaymentSheetTelemetryEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [PaymentSheetTelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
