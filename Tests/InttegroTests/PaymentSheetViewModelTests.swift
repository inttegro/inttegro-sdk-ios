import Foundation
import Testing
@testable import Inttegro

@Suite("Payment sheet view model")
struct PaymentSheetViewModelTests {
    @Test("Creates an Order after the payer chooses an amount")
    @MainActor
    func createsOrderForSelectedAmount() async throws {
        let selection = PaymentSheetAmountSelection(
            purchaseIntentID: "sale_test",
            merchantName: "Field & Form",
            productName: "Community garden",
            currency: "GHS",
            minimum: 500,
            maximum: 5_000,
            suggestions: [
                .init(id: "recommended", value: 1_000, recommended: true),
            ]
        )
        let editableSelection = PaymentSheetAmountSelection(
            orderID: "or_test",
            lineItemID: "li_selected",
            merchantName: selection.merchantName,
            productName: selection.productName,
            currency: selection.currency,
            minimum: selection.minimum,
            maximum: selection.maximum,
            suggestions: selection.suggestions
        )
        let adapter = ViewModelAdapter(
            session: editableSession(selection: editableSelection),
            amountSelection: selection
        )
        let model = PaymentSheetViewModel(
            configuration: try .init(purchaseIntentID: "sale_test"),
            adapter: adapter
        )

        await model.load()
        guard case .amountSelection = model.state else {
            Issue.record("Expected amount selection")
            return
        }
        #expect(model.selectedAmountValue == 1_000)

        model.chooseAmount(1_250)
        await model.continueWithSelectedAmount()

        guard case .ready = model.state else {
            Issue.record("Expected finalized Checkout")
            return
        }
        #expect(await adapter.selectedAmount?.value == 1_250)
        #expect(model.canChangeAmount)

        model.editAmount(lineItemID: "li_selected")
        guard case .amountSelection = model.state else {
            Issue.record("Expected amount selection after editing")
            return
        }
        model.chooseAmount(2_500)
        await model.continueWithSelectedAmount()

        guard case .ready = model.state else {
            Issue.record("Expected updated Checkout")
            return
        }
        #expect(await adapter.updatedAmount?.value == 2_500)
    }

    @Test("Edits a customer-selected amount on a merchant-created Order")
    @MainActor
    func editsMerchantCreatedOrderAmount() async throws {
        let selection = PaymentSheetAmountSelection(
            orderID: "or_test",
            lineItemID: "li_selected",
            merchantName: "Field & Form",
            productName: "Community garden",
            currency: "GHS",
            minimum: 500,
            maximum: 5_000
        )
        let editableSession = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 1_000, currency: "GHS"),
            paymentMethods: [
                .init(
                    id: "new_mobile_money",
                    kind: .mobileMoney,
                    source: .new,
                    label: "Mobile money"
                ),
            ],
            expiresAt: .distantFuture,
            lineItems: [
                .init(
                    id: "li_selected",
                    name: "Community garden",
                    total: .init(value: 1_000, currency: "GHS"),
                    amountSelection: selection
                ),
            ]
        )
        let adapter = ViewModelAdapter(session: editableSession)
        let model = PaymentSheetViewModel(
            configuration: try .init(orderID: "or_test"),
            adapter: adapter
        )

        await model.load()
        guard case .ready = model.state else {
            Issue.record("Expected the existing Checkout")
            return
        }
        #expect(model.canChangeAmount)

        model.editAmount(lineItemID: "li_selected")
        model.chooseAmount(2_500)
        await model.continueWithSelectedAmount()

        guard case .ready = model.state else {
            Issue.record("Expected the updated Checkout")
            return
        }
        #expect(await adapter.updatedAmount?.value == 2_500)
        #expect(await adapter.selectedAmount == nil)
    }

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
        #expect(
            model.validationMessage(for: .billingLine1)
                == "Enter your street address."
        )
        #expect(model.validationMessage(for: .billingCity) == "Enter your city.")
        #expect(model.validationMessage(for: .billingRegion) == "Enter your region.")
        #expect(
            model.validationMessage(for: .billingPostCode)
                == "Enter your postal code."
        )
        #expect(await adapter.payCallCount == 0)
    }

    @Test("Requires a complete billing address when saving a payment method")
    @MainActor
    func requiresCompleteBillingAddress() async throws {
        let model = PaymentSheetViewModel(
            configuration: try .init(orderID: "or_test"),
            adapter: ViewModelAdapter(session: session())
        )
        await model.load()
        model.mobileMoneyAccountNumber = "0244000042"
        model.savePaymentMethod = true
        model.billingName = "Ama Mensah"
        model.billingLine1 = "14 Independence Avenue"
        model.billingCity = "Accra"
        model.billingRegion = "Greater Accra"

        #expect(!model.canPay)

        model.billingPostCode = "GA-184-8164"

        #expect(model.canPay)
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

    private func editableSession(
        selection: PaymentSheetAmountSelection
    ) -> PaymentSheetSession {
        let base = session()
        return PaymentSheetSession(
            id: base.id,
            merchant: base.merchant,
            amount: base.amount,
            paymentMethods: base.paymentMethods,
            expiresAt: base.expiresAt,
            lineItems: [
                .init(
                    id: "li_selected",
                    name: "Community garden",
                    total: .init(value: 1_000, currency: "GHS"),
                    amountSelection: selection
                ),
            ]
        )
    }
}

private actor ViewModelAdapter: PaymentSheetAdapter {
    private let session: PaymentSheetSession
    private let amountSelection: PaymentSheetAmountSelection?
    private let payOutcome: PaymentSheetPaymentOutcome
    private let confirmOutcome: PaymentSheetPaymentOutcome
    private let refreshOutcome: PaymentSheetPaymentOutcome
    private(set) var payCallCount = 0
    private(set) var confirmCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var selectedAmount: PaymentSheetSession.Money?
    private(set) var updatedAmount: PaymentSheetSession.Money?

    init(
        session: PaymentSheetSession,
        amountSelection: PaymentSheetAmountSelection? = nil,
        payOutcome: PaymentSheetPaymentOutcome = .completed(paymentID: "py_test"),
        confirmOutcome: PaymentSheetPaymentOutcome = .completed(paymentID: "py_test"),
        refreshOutcome: PaymentSheetPaymentOutcome = .completed(paymentID: "py_test")
    ) {
        self.session = session
        self.amountSelection = amountSelection
        self.payOutcome = payOutcome
        self.confirmOutcome = confirmOutcome
        self.refreshOutcome = refreshOutcome
    }

    func retrieveCheckout(orderID _: String) async throws -> PaymentSheetSession {
        session
    }

    func retrieveAmountSelection(
        purchaseIntentID _: String
    ) async throws -> PaymentSheetAmountSelection {
        guard let amountSelection else {
            throw PaymentSheetError.checkoutUnavailable
        }
        return amountSelection
    }

    func selectAmount(
        purchaseIntentID _: String,
        amount: PaymentSheetSession.Money
    ) async throws -> PaymentSheetSession {
        selectedAmount = amount
        return session
    }

    func updateAmount(
        orderID _: String,
        lineItemID _: String,
        amount: PaymentSheetSession.Money
    ) async throws -> PaymentSheetSession {
        updatedAmount = amount
        return session
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
