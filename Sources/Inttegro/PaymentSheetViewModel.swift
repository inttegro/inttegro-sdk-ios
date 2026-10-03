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
            paymentID: String?,
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
    @Published var selectedPaymentMethodID: String?
    @Published private(set) var mobileMoneyNetwork: PaymentSheetMobileMoneyInput.Network?
    @Published private(set) var networkSelectorRevealed = false
    @Published var mobileMoneyAccountNumber = "" {
        didSet { updateNetworkSuggestion() }
    }
    @Published var savePaymentMethod = false
    @Published var billingName = ""
    @Published var billingPhoneNumber = ""
    @Published var billingLine1 = ""
    @Published var billingLine2 = ""
    @Published var billingCity = ""
    @Published var billingRegion = ""
    @Published var billingPostCode = ""
    @Published var billingCountry = "GH"
    @Published var confirmationToken = ""
    @Published var selectedAmountValue = 0

    let configuration: PaymentSheetConfiguration
    private let adapter: any PaymentSheetAdapter
    private let telemetry: PaymentSheetTelemetry
    private var amountOrderID: String?
    private var networkSelectionSource: NetworkSelectionSource?

    init(
        configuration: PaymentSheetConfiguration,
        adapter: any PaymentSheetAdapter,
        telemetry: PaymentSheetTelemetry? = nil
    ) {
        self.configuration = configuration
        self.adapter = adapter
        self.telemetry = telemetry ?? PaymentSheetTelemetry(
            configuration: configuration.telemetry
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
        case let .completed(session, _, _):
            session
        case .loading, .amountSelection, .failed:
            nil
        }
    }

    var completedResult: PaymentSheetResult? {
        guard case let .completed(_, paymentID, _) = state else { return nil }
        return .completed(paymentID: paymentID)
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
        } catch {
            let failure = Self.failure(from: error)
            state = .failed(failure)
            telemetry.emit(
                .checkoutLoadFailed,
                errorType: PaymentSheetTelemetry.safeErrorType(failure.code)
            )
        }
    }

    func chooseAmount(_ value: Int) {
        selectedAmountValue = value
        if case let .amountSelection(selection, _, _) = state {
            state = .amountSelection(selection, isProcessing: false, failure: nil)
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
        case let .completed(paymentID, documents):
            state = .completed(
                session,
                paymentID: paymentID,
                documents: session.documents.merging(documents)
            )
            return nil
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
            return nil
        case let .pending(action):
            telemetry.emit(.authorizationRequired)
            state = .awaitingResult(
                session,
                action,
                isRefreshing: false,
                failure: nil
            )
            return nil
        }
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

private extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
