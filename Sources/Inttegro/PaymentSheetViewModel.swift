import Foundation

@MainActor
final class PaymentSheetViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case amountSelection(
            PaymentSheetAmountSelection,
            isProcessing: Bool,
            failure: PaymentSheetFailure?
        )
        case ready(PaymentSheetSession)
        case processing(PaymentSheetSession)
        case confirmation(
            PaymentSheetSession,
            PaymentSheetConfirmationChallenge,
            isProcessing: Bool,
            failure: PaymentSheetFailure?
        )
        case awaitingResult(
            PaymentSheetSession,
            PaymentSheetExternalAction?,
            isRefreshing: Bool,
            failure: PaymentSheetFailure?
        )
        case completed(
            PaymentSheetSession,
            documents: PaymentSheetSession.Documents
        )
        case failed(PaymentSheetFailure)
    }

    enum Field: Hashable {
        case accountNumber
        case network
        case billingName
        case billingLine1
        case billingCity
        case billingRegion
        case billingPostCode
        case billingCountry
        case confirmationToken
    }

    private enum NetworkSelectionSource {
        case manual
        case suggested
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var inlineFailure: PaymentSheetFailure?
    @Published private(set) var validationMessages: [Field: String] = [:]
    @Published var selectedPaymentMethodID: String? {
        didSet { emitChangeIfNeeded() }
    }
    @Published private(set) var mobileMoneyNetwork: PaymentSheetMobileMoneyInput.Network? {
        didSet { emitChangeIfNeeded() }
    }
    @Published private(set) var networkSelectorRevealed = false
    @Published var mobileMoneyAccountNumber = "" {
        didSet {
            updateNetworkSuggestion()
            emitChangeIfNeeded()
        }
    }
    @Published var savePaymentMethod = false { didSet { emitChangeIfNeeded() } }
    @Published var billingName = "" { didSet { emitChangeIfNeeded() } }
    @Published var billingPhoneNumber = "" { didSet { emitChangeIfNeeded() } }
    @Published var billingLine1 = "" { didSet { emitChangeIfNeeded() } }
    @Published var billingLine2 = "" { didSet { emitChangeIfNeeded() } }
    @Published var billingCity = "" { didSet { emitChangeIfNeeded() } }
    @Published var billingRegion = "" { didSet { emitChangeIfNeeded() } }
    @Published var billingPostCode = "" { didSet { emitChangeIfNeeded() } }
    @Published var billingCountry = "GH" { didSet { emitChangeIfNeeded() } }
    @Published var confirmationToken = ""
    @Published var selectedAmountValue = 0

    let configuration: PaymentSheetConfiguration
    private let adapter: any PaymentSheetAdapter
    private let lifecycle: CheckoutLifecycle
    private let telemetry: PaymentSheetTelemetry
    private var amountOrderID: String?
    private var networkSelectionSource: NetworkSelectionSource?
    private var terminalResult: PaymentSheetResult?
    private var lastChangeComplete: Bool?
    private var lastChangePaymentMethod: String?

    init(
        configuration: PaymentSheetConfiguration,
        adapter: any PaymentSheetAdapter,
        lifecycle: CheckoutLifecycle? = nil,
        telemetry: PaymentSheetTelemetry? = nil
    ) {
        self.configuration = configuration
        self.adapter = adapter
        self.telemetry = telemetry ?? PaymentSheetTelemetry(
            configuration: configuration.telemetry
        )
        self.lifecycle = lifecycle ?? CheckoutLifecycle(
            flowID: self.telemetry.flowID,
            eventHandler: nil
        )
    }

    var isProcessing: Bool {
        switch state {
        case .processing,
             .amountSelection(_, isProcessing: true, failure: _),
             .confirmation(_, _, isProcessing: true, failure: _):
            true
        default:
            false
        }
    }

    var isAwaitingResult: Bool {
        if case .awaitingResult = state { return true }
        return false
    }

    var selectedMethod: PaymentSheetSession.PaymentMethod? {
        guard let selectedPaymentMethodID else { return nil }
        return currentSession?.paymentMethods.first { $0.id == selectedPaymentMethodID }
    }

    var currentSession: PaymentSheetSession? {
        switch state {
        case let .ready(session), let .processing(session):
            session
        case let .confirmation(session, _, _, _):
            session
        case let .awaitingResult(session, _, _, _):
            session
        case let .completed(session, _):
            session
        case .loading, .amountSelection, .failed:
            nil
        }
    }

    var completedResult: PaymentSheetResult? {
        guard let terminalResult else { return nil }
        if case .completed = terminalResult { return terminalResult }
        return nil
    }

    func dismissalResult() -> PaymentSheetResult {
        if let terminalResult { return terminalResult }
        let event = lifecycle.emit(.canceled, order: currentCheckoutOrder())
        let result = PaymentSheetResult.canceled(event)
        terminalResult = result
        return result
    }

    var canSelectAmount: Bool {
        guard case let .amountSelection(selection, false, _) = state else {
            return false
        }
        return selectedAmountValue >= selection.minimum
            && (selection.maximum == nil || selectedAmountValue <= selection.maximum!)
    }

    var canChangeAmount: Bool {
        guard case let .ready(session) = state else { return false }
        return session.lineItems.contains { $0.amountSelection != nil }
    }

    var canPay: Bool {
        guard let method = selectedMethod else { return false }
        guard method.source == .new else { return true }
        guard mobileMoneyAccountNumber.filter(\.isNumber).count == 10 else {
            return false
        }
        guard mobileMoneyNetwork != nil else { return false }
        guard savePaymentMethod else { return true }
        return paymentMethodOwnerReady
    }

    var networkSuggestionHint: String? {
        let digits = mobileMoneyAccountNumber.filter(\.isNumber)
        guard digits.count >= 3 else { return nil }
        let prefix = String(digits.prefix(3))
        guard let inferredNetwork = Self.inferMobileMoneyNetwork(from: digits) else {
            return "We could not match that prefix. Choose the current network for this account."
        }
        if let mobileMoneyNetwork, mobileMoneyNetwork != inferredNetwork {
            return "This number is usually associated with \(inferredNetwork.displayName), "
                + "but you can continue with \(mobileMoneyNetwork.displayName) "
                + "if this number was moved."
        }
        if networkSelectionSource == .suggested {
            return "Suggested \(inferredNetwork.displayName) from prefix \(prefix). "
                + "Change it if this number has been ported."
        }
        return nil
    }

    var paymentMethodOwnerReady: Bool {
        !billingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !billingLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !billingCity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !billingRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !billingPostCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && billingCountry
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: "^[A-Za-z]{2}$", options: .regularExpression) != nil
    }

    func validationMessage(for field: Field) -> String? {
        validationMessages[field]
    }

    func selectPaymentMethod(_ id: String) {
        selectedPaymentMethodID = id
        inlineFailure = nil
        validationMessages = [:]
    }

    func selectMobileMoneyNetwork(_ network: PaymentSheetMobileMoneyInput.Network) {
        mobileMoneyNetwork = network
        networkSelectionSource = .manual
        validationMessages[.network] = nil
    }

    func load() async {
        telemetry.emit(.checkoutLoadStarted)
        state = .loading
        inlineFailure = nil
        validationMessages = [:]
        amountOrderID = nil
        lastChangeComplete = nil
        lastChangePaymentMethod = nil
        do {
            if let purchaseIntentID = configuration.purchaseIntentID {
                let selection = try await adapter.retrieveAmountSelection(
                    purchaseIntentID: purchaseIntentID
                )
                if let expiresAt = selection.expiresAt, expiresAt <= Date() {
                    throw PaymentSheetError.checkoutExpired
                }
                selectedAmountValue = selection.suggestions
                    .first(where: \.recommended)?.value
                    ?? selection.minimum
                state = .amountSelection(
                    selection,
                    isProcessing: false,
                    failure: nil
                )
                telemetry.emit(.checkoutLoadSucceeded)
                lifecycle.emit(.ready)
                emitChangeIfNeeded()
                return
            }
            guard let orderID = configuration.orderID else {
                throw PaymentSheetError.invalidConfiguration(
                    "A Checkout reference is required."
                )
            }
            let session = try await adapter.retrieveCheckout(orderID: orderID)
            guard session.expiresAt > Date() else {
                throw PaymentSheetError.checkoutExpired
            }
            selectedPaymentMethodID = session.paymentMethods.first?.id
            state = .ready(session)
            telemetry.emit(.checkoutLoadSucceeded)
            lifecycle.emit(.ready)
            emitChangeIfNeeded()
        } catch {
            let failure = Self.failure(from: error)
            state = .failed(failure)
            telemetry.emit(
                .checkoutLoadFailed,
                errorType: PaymentSheetTelemetry.safeErrorType(failure.code)
            )
            let event = lifecycle.emit(
                .failed,
                failure: failure.checkoutFailure(recoverable: false)
            )
            terminalResult = .failed(event)
        }
    }

    func chooseAmount(_ value: Int) {
        selectedAmountValue = value
        if case let .amountSelection(selection, _, _) = state {
            state = .amountSelection(selection, isProcessing: false, failure: nil)
            emitChangeIfNeeded()
        }
    }

    func continueWithSelectedAmount() async {
        guard case let .amountSelection(selection, false, _) = state,
              canSelectAmount else {
            return
        }
        state = .amountSelection(selection, isProcessing: true, failure: nil)
        do {
            let amount = PaymentSheetSession.Money(
                value: selectedAmountValue,
                currency: selection.currency
            )
            let session: PaymentSheetSession
            if let amountOrderID {
                guard let lineItemID = selection.lineItemID else {
                    throw PaymentSheetError.invalidConfiguration(
                        "The editable line item is missing."
                    )
                }
                session = try await adapter.updateAmount(
                    orderID: amountOrderID,
                    lineItemID: lineItemID,
                    amount: amount
                )
            } else {
                guard let purchaseIntentID = selection.purchaseIntentID else {
                    throw PaymentSheetError.invalidConfiguration(
                        "A Purchase Intent ID is required to create this checkout."
                    )
                }
                session = try await adapter.selectAmount(
                    purchaseIntentID: purchaseIntentID,
                    amount: amount
                )
            }
            guard session.expiresAt > Date() else {
                throw PaymentSheetError.checkoutExpired
            }
            amountOrderID = session.id
            selectedPaymentMethodID = session.paymentMethods.first?.id
            state = .ready(session)
            lifecycle.emit(
                .orderPrepared,
                order: CheckoutOrder(session: session, status: .requiresPayment)
            )
            emitChangeIfNeeded()
        } catch {
            state = .amountSelection(
                selection,
                isProcessing: false,
                failure: Self.failure(from: error)
            )
        }
    }

    func editAmount(lineItemID: String) {
        guard case let .ready(session) = state,
              let lineItem = session.lineItems.first(where: { $0.id == lineItemID }),
              let amountSelection = lineItem.amountSelection else {
            return
        }
        amountOrderID = session.id
        selectedAmountValue = lineItem.total.value
        inlineFailure = nil
        validationMessages = [:]
        state = .amountSelection(
            amountSelection,
            isProcessing: false,
            failure: nil
        )
    }

    func pay() async -> PaymentSheetResult? {
        guard case let .ready(session) = state,
              let selection = paymentSelection(in: session) else {
            return nil
        }

        inlineFailure = nil
        state = .processing(session)
        telemetry.emit(.paymentAttemptStarted)
        lifecycle.emit(
            .paymentAttemptStarted,
            order: CheckoutOrder(session: session, status: .requiresPayment)
        )
        do {
            let outcome = try await adapter.pay(session: session, selection: selection)
            return handle(outcome, session: session)
        } catch {
            let failure = Self.failure(from: error)
            inlineFailure = failure
            state = .ready(session)
            telemetry.emit(
                .paymentAttemptFailed,
                errorType: PaymentSheetTelemetry.safeErrorType(failure.code)
            )
            lifecycle.emit(
                .paymentAttemptFailed,
                order: CheckoutOrder(session: session, status: .requiresPayment),
                failure: failure.checkoutFailure(recoverable: true)
            )
            return nil
        }
    }

    func requestNewCode() async -> PaymentSheetResult? {
        guard case let .confirmation(session, challenge, false, _) = state else {
            return nil
        }

        confirmationToken = ""
        validationMessages[.confirmationToken] = nil
        state = .confirmation(session, challenge, isProcessing: true, failure: nil)
        do {
            let outcome = try await adapter.requestConfirmation(
                session: session,
                challenge: challenge
            )
            return handle(outcome, session: session)
        } catch {
            state = .confirmation(
                session,
                challenge,
                isProcessing: false,
                failure: Self.failure(from: error)
            )
            return nil
        }
    }

    func submitConfirmation() async -> PaymentSheetResult? {
        guard case let .confirmation(session, challenge, false, _) = state else {
            return nil
        }
        let token = confirmationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == challenge.tokenSize, token.allSatisfy(\.isNumber) else {
            validationMessages[.confirmationToken] =
                "Enter the \(challenge.tokenSize)-digit code."
            return nil
        }

        validationMessages[.confirmationToken] = nil
        state = .confirmation(session, challenge, isProcessing: true, failure: nil)
        do {
            let outcome = try await adapter.confirmPayment(
                session: session,
                challenge: challenge,
                token: token
            )
            return handle(outcome, session: session)
        } catch {
            state = .confirmation(
                session,
                challenge,
                isProcessing: false,
                failure: Self.failure(from: error)
            )
            return nil
        }
    }

    func refreshPayment() async -> PaymentSheetResult? {
        guard case let .awaitingResult(session, action, false, _) = state else {
            return nil
        }

        telemetry.emit(.statusPolling)
        state = .awaitingResult(
            session,
            action,
            isRefreshing: true,
            failure: nil
        )
        do {
            let outcome = try await adapter.refreshPayment(session: session)
            return handle(outcome, session: session)
        } catch {
            state = .awaitingResult(
                session,
                action,
                isRefreshing: false,
                failure: Self.failure(from: error)
            )
            return nil
        }
    }

    private func paymentSelection(
        in session: PaymentSheetSession
    ) -> PaymentSheetPaymentSelection? {
        validationMessages = [:]
        guard let method = session.paymentMethods.first(where: {
            $0.id == selectedPaymentMethodID
        }) else {
            return nil
        }
        guard method.source == .new else {
            return .saved(method)
        }

        let account = mobileMoneyAccountNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitCount = account.filter(\.isNumber).count
        if digitCount != 10 {
            validationMessages[.accountNumber] = "Enter the 10-digit mobile money number."
        }
        if mobileMoneyNetwork == nil {
            validationMessages[.network] = "Choose the current network for this account."
        }

        var billing: PaymentSheetMobileMoneyInput.BillingDetails?
        if savePaymentMethod {
            let name = billingName.trimmingCharacters(in: .whitespacesAndNewlines)
            let country = billingCountry
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if name.isEmpty {
                validationMessages[.billingName] = "Enter your name to save this account."
            }
            if billingLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationMessages[.billingLine1] = "Enter your street address."
            }
            if billingCity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationMessages[.billingCity] = "Enter your city."
            }
            if billingRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationMessages[.billingRegion] = "Enter your region."
            }
            if billingPostCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationMessages[.billingPostCode] = "Enter your postal code."
            }
            if country.range(of: "^[A-Z]{2}$", options: .regularExpression) == nil {
                validationMessages[.billingCountry] = "Use a two-letter country code."
            }
            billing = .init(
                name: name,
                phoneNumber: billingPhoneNumber.trimmedOrNil,
                address: .init(
                    line1: billingLine1.trimmedOrNil,
                    line2: billingLine2.trimmedOrNil,
                    city: billingCity.trimmedOrNil,
                    region: billingRegion.trimmedOrNil,
                    postCode: billingPostCode.trimmedOrNil,
                    country: country
                )
            )
        }

        guard validationMessages.isEmpty, let mobileMoneyNetwork else { return nil }
        return .mobileMoney(
            .init(
                network: mobileMoneyNetwork,
                accountNumber: account,
                billingDetails: billing,
                savePaymentMethod: savePaymentMethod
            )
        )
    }

    private func updateNetworkSuggestion() {
        let digits = mobileMoneyAccountNumber.filter(\.isNumber)
        if digits.count >= 3 {
            networkSelectorRevealed = true
        }
        guard networkSelectionSource != .manual else { return }
        if let inferredNetwork = Self.inferMobileMoneyNetwork(from: digits) {
            mobileMoneyNetwork = inferredNetwork
            networkSelectionSource = .suggested
        } else if networkSelectionSource == .suggested {
            mobileMoneyNetwork = nil
            networkSelectionSource = nil
        }
    }

    private func emitChangeIfNeeded() {
        let complete: Bool
        let paymentMethod: String?
        switch state {
        case .amountSelection:
            complete = canSelectAmount
            paymentMethod = nil
        case .ready:
            complete = canPay
            paymentMethod = selectedMethod?.kind == .mobileMoney
                ? "mobile_money"
                : nil
        default:
            return
        }
        guard complete != lastChangeComplete || paymentMethod != lastChangePaymentMethod else {
            return
        }
        lastChangeComplete = complete
        lastChangePaymentMethod = paymentMethod
        lifecycle.emit(
            .change,
            complete: complete,
            paymentMethod: paymentMethod
        )
    }

    private static func inferMobileMoneyNetwork(
        from digits: String
    ) -> PaymentSheetMobileMoneyInput.Network? {
        guard digits.count >= 3 else { return nil }
        return switch String(digits.prefix(3)) {
        case "020", "050": .telecel
        case "024", "025", "053", "054", "055", "059": .mtn
        case "026", "027", "056", "057": .airtel
        default: nil
        }
    }

    private func handle(
        _ outcome: PaymentSheetPaymentOutcome,
        session: PaymentSheetSession
    ) -> PaymentSheetResult? {
        switch outcome {
        case let .completed(documents):
            let resolvedDocuments = session.documents.merging(documents)
            state = .completed(
                session,
                documents: resolvedDocuments
            )
            let event = lifecycle.emit(
                .completed,
                order: CheckoutOrder(
                    session: session,
                    status: .paid,
                    documents: resolvedDocuments
                )
            )
            let result = PaymentSheetResult.completed(event)
            terminalResult = result
            return result
        case let .requiresConfirmation(challenge):
            telemetry.emit(.confirmationRequired)
            confirmationToken = ""
            validationMessages = [:]
            state = .confirmation(
                session,
                challenge,
                isProcessing: false,
                failure: nil
            )
            lifecycle.emit(
                .paymentActionRequired,
                order: CheckoutOrder(session: session, status: .requiresAction),
                action: .init(type: .confirmation, expiresAt: challenge.expiresAt)
            )
            return nil
        case let .pending(action):
            telemetry.emit(.authorizationRequired)
            state = .awaitingResult(
                session,
                action,
                isRefreshing: false,
                failure: nil
            )
            if let action {
                lifecycle.emit(
                    .paymentActionRequired,
                    order: CheckoutOrder(session: session, status: .requiresAction),
                    action: action.checkoutAction
                )
            } else {
                lifecycle.emit(
                    .paymentProcessing,
                    order: CheckoutOrder(session: session, status: .processing)
                )
            }
            return nil
        }
    }

    private func currentCheckoutOrder() -> CheckoutOrder? {
        guard let session = currentSession else { return nil }
        let status: CheckoutOrder.Status = switch state {
        case .processing:
            .processing
        case .confirmation, .awaitingResult:
            .requiresAction
        case .completed:
            .paid
        case .ready:
            .requiresPayment
        case .loading, .amountSelection, .failed:
            .requiresPayment
        }
        return CheckoutOrder(session: session, status: status)
    }

    private static func failure(from error: Error) -> PaymentSheetFailure {
        if let error = error as? PaymentSheetRequestError {
            return PaymentSheetFailure(
                code: error.code,
                message: error.message,
                declineCode: error.declineCode,
                requestID: error.requestID,
                retryAfterSeconds: error.retryAfterSeconds
            )
        }
        if let error = error as? PaymentSheetError {
            return PaymentSheetFailure(
                code: error.code,
                message: error.localizedDescription
            )
        }
        return PaymentSheetFailure(
            code: "payment_sheet_failed",
            message: error.localizedDescription
        )
    }
}

private extension PaymentSheetExternalAction {
    var checkoutAction: CheckoutAction {
        switch self {
        case let .redirect(_, expiresAt):
            .init(type: .redirect, expiresAt: expiresAt)
        case let .authorize(_, expiresAt):
            .init(type: .authorization, expiresAt: expiresAt)
        }
    }
}

private extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
