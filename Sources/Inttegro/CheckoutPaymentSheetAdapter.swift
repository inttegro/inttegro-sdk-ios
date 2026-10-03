import CryptoKit
import Foundation

/// The public Checkout transport used by ``PaymentSheet``.
///
/// This adapter never accepts an API key. The finalized Order ID is the
/// capability used to look up and pay Checkout, and to change a
/// customer-selected amount only while payment remains pristine.
public struct CheckoutPaymentSheetAdapter: PaymentSheetAdapter {
    typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias RetrySleeper = @Sendable (UInt64) async throws -> Void

    private let baseURL: URL
    private let executeRequest: RequestExecutor
    private let attemptKeys: PaymentAttemptKeys
    private let telemetry: PaymentSheetTelemetry?
    private let retrySleeper: RetrySleeper

    /// Creates an adapter for Inttegro's public Checkout API.
    ///
    /// Applications normally keep the default base URL. A custom URL is useful
    /// for an Inttegro-provided sandbox or an explicitly controlled test
    /// environment; it must never point at an untrusted proxy that can observe
    /// payer details.
    ///
    /// - Parameters:
    ///   - baseURL: Base URL for public Checkout operations.
    ///   - telemetry: Optional host-owned diagnostic source.
    public init(
        baseURL: URL = URL(string: "https://api.inttegro.com")!,
        telemetry: PaymentSheetTelemetry? = nil
    ) {
        self.init(
            baseURL: baseURL,
            executeRequest: { request in
                try await URLSession.shared.data(for: request)
            },
            telemetry: telemetry,
            retrySleeper: { seconds in
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        )
    }

    init(
        baseURL: URL,
        executeRequest: @escaping RequestExecutor,
        telemetry: PaymentSheetTelemetry? = nil,
        retrySleeper: @escaping RetrySleeper = { seconds in
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    ) {
        self.baseURL = baseURL
        self.executeRequest = executeRequest
        self.telemetry = telemetry
        self.retrySleeper = retrySleeper
        attemptKeys = PaymentAttemptKeys()
    }

    /// Retrieves the client-safe Checkout projection for `orderID`.
    ///
    /// The response deliberately omits merchant-only administration fields.
    public func retrieveCheckout(orderID: String) async throws -> PaymentSheetSession {
        let envelope = try await post(
            path: "checkout/lookup",
            body: ["order_id": orderID]
        )
        if let error = envelope.error {
            throw error.checkoutError(metadata: envelope.metadata)
        }
        guard let order = envelope.order else {
            throw PaymentSheetRequestError(
                code: "invalid_checkout_response",
                message: "Inttegro returned an invalid checkout response.",
                requestID: envelope.metadata.requestID,
                retryAfterSeconds: envelope.metadata.retryAfterSeconds
            )
        }
        return try order.paymentSheetSession
    }

    /// Retrieves the client-safe range for a customer-selected amount.
    public func retrieveAmountSelection(
        purchaseIntentID: String
    ) async throws -> PaymentSheetAmountSelection {
        let envelope = try await post(
            path: "checkout/lookup",
            body: ["purchase_intent_id": purchaseIntentID]
        )
        if let error = envelope.error {
            throw error.checkoutError(metadata: envelope.metadata)
        }
        guard let purchaseIntent = envelope.purchaseIntent else {
            throw PaymentSheetRequestError(
                code: "invalid_checkout_response",
                message: "Inttegro returned an invalid Purchase Intent response.",
                requestID: envelope.metadata.requestID,
                retryAfterSeconds: envelope.metadata.retryAfterSeconds
            )
        }
        return try purchaseIntent.paymentSheetAmountSelection
    }

    /// Creates the finalized Order for a payer-selected amount.
    public func selectAmount(
        purchaseIntentID: String,
        amount: PaymentSheetSession.Money
    ) async throws -> PaymentSheetSession {
        let fingerprint = "\(purchaseIntentID)#\(amount.currency)#\(amount.value)"
        let idempotencyKey = await attemptKeys.key(
            operation: "select_amount",
            fingerprint: fingerprint
        )
        let envelope = try await post(
            path: "checkout/select_amount",
            body: [
                "purchase_intent_id": purchaseIntentID,
                "selected_amount": [
                    "currency": amount.currency.lowercased(),
                    "value": amount.value,
                ],
            ],
            idempotencyKey: idempotencyKey
        )
        if let error = envelope.error {
            throw error.checkoutError(metadata: envelope.metadata)
        }
        guard let order = envelope.order else {
            throw PaymentSheetRequestError(
                code: "invalid_checkout_response",
                message: "Inttegro did not return the prepared checkout Order.",
                requestID: envelope.metadata.requestID,
                retryAfterSeconds: envelope.metadata.retryAfterSeconds
            )
        }
        return try order.paymentSheetSession
    }

    /// Updates a payer-selected amount while the Checkout Order is still pristine.
    public func updateAmount(
        orderID: String,
        lineItemID: String,
        amount: PaymentSheetSession.Money
    ) async throws -> PaymentSheetSession {
        let fingerprint = "\(orderID)#\(lineItemID)#\(amount.currency)#\(amount.value)"
        let idempotencyKey = await attemptKeys.key(
            operation: "select_amount",
            fingerprint: fingerprint
        )
        let envelope = try await post(
            path: "checkout/select_amount",
            body: [
                "order_id": orderID,
                "line_item_id": lineItemID,
                "selected_amount": [
                    "currency": amount.currency.lowercased(),
                    "value": amount.value,
                ],
            ],
            idempotencyKey: idempotencyKey
        )
        if let error = envelope.error {
            throw error.checkoutError(metadata: envelope.metadata)
        }
        guard let order = envelope.order else {
            throw PaymentSheetRequestError(
                code: "invalid_checkout_response",
                message: "Inttegro did not return the updated checkout Order.",
                requestID: envelope.metadata.requestID,
                retryAfterSeconds: envelope.metadata.retryAfterSeconds
            )
        }
        return try order.paymentSheetSession
    }

    /// Starts or retries payment with a stable key for the exact selection.
    ///
    /// Changing the selection produces a new idempotency fingerprint; retrying
    /// an unchanged request reuses its key.
    public func pay(
        session: PaymentSheetSession,
        selection: PaymentSheetPaymentSelection
    ) async throws -> PaymentSheetPaymentOutcome {
        let request = paymentRequest(orderID: session.id, selection: selection)
        let idempotencyKey = await attemptKeys.key(
            operation: "pay",
            fingerprint: request.fingerprint
        )
        let envelope = try await post(
            path: "checkout/pay",
            body: request.body,
            idempotencyKey: idempotencyKey
        )
        return try paymentOutcome(from: envelope)
    }

    /// Requests a replacement confirmation code with replay protection.
    public func requestConfirmation(
        session: PaymentSheetSession,
        challenge: PaymentSheetConfirmationChallenge
    ) async throws -> PaymentSheetPaymentOutcome {
        let fingerprint = "\(session.id)#\(challenge.confirmationID ?? "new")"
        let idempotencyKey = await attemptKeys.key(
            operation: "request_confirmation",
            fingerprint: fingerprint
        )
        let envelope = try await post(
            path: "checkout/request_confirmation",
            body: ["order_id": session.id],
            idempotencyKey: idempotencyKey
        )
        return try paymentOutcome(from: envelope)
    }

    /// Submits the confirmation token for the active payment attempt.
    public func confirmPayment(
        session: PaymentSheetSession,
        challenge: PaymentSheetConfirmationChallenge,
        token: String
    ) async throws -> PaymentSheetPaymentOutcome {
        var body: [String: Any] = [
            "order_id": session.id,
            "token": token,
        ]
        if let paymentID = challenge.paymentID {
            body["payment_id"] = paymentID
        }
        if let confirmationID = challenge.confirmationID {
            body["confirmation_id"] = confirmationID
        }
        let fingerprint = [
            session.id,
            challenge.paymentID ?? "",
            challenge.confirmationID ?? "",
            token,
        ].joined(separator: "#")
        let idempotencyKey = await attemptKeys.key(
            operation: "confirm_payment",
            fingerprint: fingerprint
        )
        let envelope = try await post(
            path: "checkout/confirm_payment",
            body: body,
            idempotencyKey: idempotencyKey
        )
        return try paymentOutcome(from: envelope)
    }

    /// Retrieves the latest authoritative payment state from Checkout.
    public func refreshPayment(
        session: PaymentSheetSession
    ) async throws -> PaymentSheetPaymentOutcome {
        let envelope = try await post(
            path: "checkout/lookup",
            body: ["order_id": session.id]
        )
        return try paymentOutcome(from: envelope)
    }

    private func paymentOutcome(from envelope: CheckoutEnvelope) throws -> PaymentSheetPaymentOutcome {
        if let error = envelope.error {
            throw error.confirmationError(metadata: envelope.metadata)
        }
        guard let order = envelope.order else {
            throw PaymentSheetRequestError(
                code: "invalid_checkout_response",
                message: "Inttegro returned an invalid checkout response.",
                requestID: envelope.metadata.requestID,
                retryAfterSeconds: envelope.metadata.retryAfterSeconds
            )
        }

        if order.status == "paid" || order.status == "completed" || order.payment?.status == "paid" {
            return .completed(
                paymentID: order.payment?.id,
                documents: order.paymentSheetDocuments
            )
        }
        if let latestError = order.payment?.latestError {
            throw latestError.confirmationError(metadata: envelope.metadata)
        }
        if let challenge = order.confirmationChallenge {
            return .requiresConfirmation(challenge)
        }
        if let action = try order.externalAction {
            return .pending(action)
        }
        if order.payment?.nextAction?.type == "execute" || order.payment?.nextAction == nil {
            return .pending(nil)
        }
        throw PaymentSheetRequestError(
            code: "payment_requires_action",
            message: "This payment needs an authorization step that this SDK version does not support yet.",
            requestID: envelope.metadata.requestID,
            retryAfterSeconds: envelope.metadata.retryAfterSeconds
        )
    }

    private func paymentRequest(
        orderID: String,
        selection: PaymentSheetPaymentSelection
    ) -> (body: [String: Any], fingerprint: String) {
        switch selection {
        case let .saved(method):
            return (
                [
                    "order_id": orderID,
                    "payment_method_id": method.id,
                ],
                "\(orderID)#saved#\(method.id)"
            )
        case let .mobileMoney(input):
            var methodData: [String: Any] = [
                "type": "mobile_money",
                "mobile_money": [
                    "network": input.network.rawValue,
                    "account_number": input.accountNumber,
                ],
            ]
            var fingerprintParts = [
                orderID,
                "mobile_money",
                input.network.rawValue,
                input.accountNumber,
                "save:\(input.savePaymentMethod)",
            ]
            if let billing = input.billingDetails {
                var address: [String: Any] = ["country": billing.address.country]
                address.addIfPresent("line1", billing.address.line1)
                address.addIfPresent("line2", billing.address.line2)
                address.addIfPresent("city", billing.address.city)
                address.addIfPresent("region", billing.address.region)
                address.addIfPresent("post_code", billing.address.postCode)

                var billingData: [String: Any] = [
                    "name": billing.name,
                    "address": address,
                ]
                billingData.addIfPresent("phone_number", billing.phoneNumber)
                methodData["billing_details"] = billingData
                fingerprintParts.append(contentsOf: [
                    billing.name,
                    billing.phoneNumber ?? "",
                    billing.address.line1 ?? "",
                    billing.address.line2 ?? "",
                    billing.address.city ?? "",
                    billing.address.region ?? "",
                    billing.address.postCode ?? "",
                    billing.address.country,
                ])
            }
            return (
                [
                    "order_id": orderID,
                    "payment_method_data": methodData,
                    "save_payment_method": input.savePaymentMethod,
                ],
                fingerprintParts.joined(separator: "#")
            )
        }
    }

    private func post(
        path: String,
        body: [String: Any],
        idempotencyKey: String? = nil
    ) async throws -> CheckoutEnvelope {
        let operation = path.replacingOccurrences(of: "/", with: ".")
        telemetry?.emit(.requestPrepared, operation: operation)
        let endpoint = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("inttegro-sdk-ios/0.3.0", forHTTPHeaderField: "User-Agent")
        telemetry?.applyTraceContext(to: &request)
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            let data: Data
            let response: URLResponse
            do {
                telemetry?.emit(.httpAttemptStarted, operation: operation)
                (data, response) = try await executeRequest(request)
            } catch let error as PaymentSheetError {
                telemetry?.emit(
                    .requestFailed,
                    operation: operation,
                    errorType: PaymentSheetTelemetry.safeErrorType(error)
                )
                throw error
            } catch {
                telemetry?.emit(
                    .requestFailed,
                    operation: operation,
                    errorType: PaymentSheetTelemetry.safeErrorType(error)
                )
                throw PaymentSheetError.checkoutUnavailable
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                telemetry?.emit(
                    .requestFailed,
                    operation: operation,
                    errorType: "transport_error"
                )
                throw PaymentSheetError.checkoutUnavailable
            }
            let metadata = CheckoutResponseMetadata(httpResponse: httpResponse)
            telemetry?.emit(
                .responseReceived,
                operation: operation,
                httpStatusCode: httpResponse.statusCode,
                requestID: metadata.requestID,
                retryAfterSeconds: metadata.retryAfterSeconds
            )

            if httpResponse.statusCode == 503,
               idempotencyKey != nil,
               attempt == 0,
               let retryAfterSeconds = metadata.retryAfterSeconds {
                attempt += 1
                try await retrySleeper(UInt64(retryAfterSeconds))
                continue
            }

            let envelope: CheckoutEnvelope
            do {
                envelope = try JSONDecoder().decode(CheckoutEnvelope.self, from: data)
            } catch {
                telemetry?.emit(
                    .requestFailed,
                    operation: operation,
                    httpStatusCode: httpResponse.statusCode,
                    requestID: metadata.requestID,
                    retryAfterSeconds: metadata.retryAfterSeconds,
                    errorType: "decode_error"
                )
                throw PaymentSheetRequestError(
                    code: (200 ..< 300).contains(httpResponse.statusCode)
                        ? "invalid_checkout_response" : "checkout_http_\(httpResponse.statusCode)",
                    message: (200 ..< 300).contains(httpResponse.statusCode)
                        ? "Inttegro returned an invalid checkout response."
                        : "Inttegro could not complete the checkout request.",
                    requestID: metadata.requestID,
                    retryAfterSeconds: metadata.retryAfterSeconds
                )
            }
            if !(200 ..< 300).contains(httpResponse.statusCode), envelope.error == nil {
                telemetry?.emit(
                    .requestFailed,
                    operation: operation,
                    httpStatusCode: httpResponse.statusCode,
                    requestID: metadata.requestID,
                    retryAfterSeconds: metadata.retryAfterSeconds,
                    errorType: "checkout_http_\(httpResponse.statusCode)"
                )
                throw PaymentSheetRequestError(
                    code: "checkout_http_\(httpResponse.statusCode)",
                    message: "Inttegro could not complete the checkout request.",
                    requestID: metadata.requestID,
                    retryAfterSeconds: metadata.retryAfterSeconds
                )
            }
            telemetry?.emit(
                .responseDecoded,
                operation: operation,
                httpStatusCode: httpResponse.statusCode,
                requestID: metadata.requestID,
                retryAfterSeconds: metadata.retryAfterSeconds
            )
            var responseEnvelope = envelope
            responseEnvelope.metadata = metadata
            return responseEnvelope
        }
    }

}

private actor PaymentAttemptKeys {
    private var keys: [String: String] = [:]

    func key(operation: String, fingerprint: String) -> String {
        let value = Data("\(operation)#\(fingerprint)".utf8)
        let attempt = SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
        if let key = keys[attempt] {
            return key
        }
        let key = UUID().uuidString.lowercased()
        keys[attempt] = key
        return key
    }
}

private struct CheckoutEnvelope: Decodable {
    let order: CheckoutOrder?
    let purchaseIntent: CheckoutPurchaseIntent?
    let error: CheckoutAPIError?
    var metadata = CheckoutResponseMetadata()

    private enum CodingKeys: String, CodingKey {
        case order, error
        case purchaseIntent = "purchase_intent"
    }
}

private struct CheckoutPurchaseIntent: Decodable {
    let id: String
    let merchant: Merchant?
    let product: Product?
    let price: Price?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, merchant, product, price
        case expiresAt = "expires_at"
    }

    struct Merchant: Decodable {
        let appName: String?
        let organizationName: String?

        enum CodingKeys: String, CodingKey {
            case appName = "app_name"
            case organizationName = "organization_name"
        }
    }

    struct Product: Decodable {
        let id: String
        let name: String
        let about: String?
        let description: String?
    }

    struct Price: Decodable {
        let id: String?
        let type: String
        let customerSelectedAmount: CustomerSelectedAmount?

        enum CodingKeys: String, CodingKey {
            case id, type
            case customerSelectedAmount = "customer_selected_amount"
        }
    }

    struct CustomerSelectedAmount: Decodable {
        let currency: String
        let minimum: Int
        let maximum: Int?
        let suggestedAmounts: [Suggestion]?

        enum CodingKeys: String, CodingKey {
            case currency, minimum, maximum
            case suggestedAmounts = "suggested_amounts"
        }
    }

    struct Suggestion: Decodable {
        let id: String
        let value: Int
        let recommended: Bool?
    }

    var paymentSheetAmountSelection: PaymentSheetAmountSelection {
        get throws {
            guard let product,
                  let policy = price?.customerSelectedAmount else {
                throw PaymentSheetRequestError(
                    code: "invalid_checkout_response",
                    message: "The Purchase Intent does not include a customer-selected price."
                )
            }
            return .init(
                purchaseIntentID: id,
                merchantName: merchant?.appName?.nonEmpty
                    ?? merchant?.organizationName?.nonEmpty
                    ?? "Inttegro merchant",
                productName: product.name,
                productAbout: product.about?.nonEmpty ?? product.description?.nonEmpty,
                currency: policy.currency,
                minimum: policy.minimum,
                maximum: policy.maximum,
                suggestions: policy.suggestedAmounts?.map {
                    .init(
                        id: $0.id,
                        value: $0.value,
                        recommended: $0.recommended == true
                    )
                } ?? [],
                expiresAt: CheckoutOrder.date(from: expiresAt)
            )
        }
    }
}

private struct CheckoutResponseMetadata: Sendable {
    let requestID: String?
    let retryAfterSeconds: Int?

    init(requestID: String? = nil, retryAfterSeconds: Int? = nil) {
        self.requestID = requestID.flatMap {
            (1 ... 255).contains($0.utf8.count) ? $0 : nil
        }
        self.retryAfterSeconds = retryAfterSeconds.flatMap {
            (0 ... 300).contains($0) ? $0 : nil
        }
    }

    init(httpResponse: HTTPURLResponse) {
        self.init(
            requestID: httpResponse.value(forHTTPHeaderField: "x-request-id"),
            retryAfterSeconds: httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Int.init)
        )
    }
}

private struct CheckoutOrder: Decodable {
    let id: String
    let status: String
    let expiresAt: String?
    let paymentDueAt: String?
    let lineItemGroup: LineItemGroup?
    let payment: Payment?
    let invoice: Invoice?

    enum CodingKeys: String, CodingKey {
        case id, status, payment, invoice
        case expiresAt = "expires_at"
        case paymentDueAt = "payment_due_at"
        case lineItemGroup = "line_item_group"
    }

    struct LineItemGroup: Decodable {
        let lineItems: [LineItem]?
        let total: Money?

        enum CodingKeys: String, CodingKey {
            case total
            case lineItems = "line_items"
        }
    }

    struct LineItem: Decodable {
        let type: String
        let product: Product?
        let fee: Fee?
        let shipping: Shipping?

        struct Product: Decodable {
            let id: String
            let name: String
            let about: String?
            let price: Price
            let quantity: Int
        }

        struct Price: Decodable {
            let id: String?
            let type: String
            let fixedAmount: Money?
            let selectedAmount: Money?
            let customerSelectedAmount: CheckoutPurchaseIntent.CustomerSelectedAmount?

            enum CodingKeys: String, CodingKey {
                case id, type
                case fixedAmount = "fixed_amount"
                case selectedAmount = "selected_amount"
                case customerSelectedAmount = "customer_selected_amount"
            }
        }

        struct Fee: Decodable {
            let id: String
            let label: String
            let amount: Money
        }

        struct Shipping: Decodable {
            let id: String
            let label: String?
            let fee: Money
        }

        func paymentSheetLineItem(
            orderID: String,
            merchantName: String,
            expiresAt: Date
        ) -> PaymentSheetSession.LineItem? {
            switch type {
            case "product":
                guard let product,
                      let amount = product.price.type == "customer_selected_amount"
                        ? product.price.selectedAmount
                        : product.price.fixedAmount else { return nil }
                let amountSelection = product.price.customerSelectedAmount.map { policy in
                    PaymentSheetAmountSelection(
                        orderID: orderID,
                        lineItemID: product.id,
                        merchantName: merchantName,
                        productName: product.name,
                        productAbout: product.about,
                        currency: policy.currency,
                        minimum: policy.minimum,
                        maximum: policy.maximum,
                        suggestions: policy.suggestedAmounts?.map {
                            .init(
                                id: $0.id,
                                value: $0.value,
                                recommended: $0.recommended == true
                            )
                        } ?? [],
                        expiresAt: expiresAt
                    )
                }
                return .init(
                    id: product.id,
                    name: product.name,
                    quantity: product.quantity,
                    total: .init(
                        value: amount.value * product.quantity,
                        currency: amount.currency
                    ),
                    amountSelection: amountSelection
                )
            case "fee":
                guard let fee else { return nil }
                return .init(
                    id: fee.id,
                    name: fee.label,
                    total: .init(value: fee.amount.value, currency: fee.amount.currency)
                )
            case "shipping":
                guard let shipping else { return nil }
                return .init(
                    id: shipping.id,
                    name: shipping.label?.nonEmpty ?? "Shipping",
                    total: .init(value: shipping.fee.value, currency: shipping.fee.currency)
                )
            default:
                return nil
            }
        }
    }

    struct Money: Decodable {
        let value: Int
        let currency: String
    }

    struct Payment: Decodable {
        let id: String?
        let amount: Money?
        let status: String?
        let dueAt: String?
        let paymentMethodTypes: [String]?
        let paymentMethod: PaymentMethod?
        let nextAction: NextAction?
        let latestError: CheckoutAPIError?
        let receipt: Document?

        enum CodingKeys: String, CodingKey {
            case id, amount, status, receipt
            case dueAt = "due_at"
            case paymentMethodTypes = "payment_method_types"
            case paymentMethod = "payment_method"
            case nextAction = "next_action"
            case latestError = "latest_error"
        }
    }

    struct PaymentMethod: Decodable {
        let id: String
        let type: String
        let mobileMoney: MobileMoney?

        enum CodingKeys: String, CodingKey {
            case id, type
            case mobileMoney = "mobile_money"
        }

        struct MobileMoney: Decodable {
            let network: String
            let accountNumber: String?
            let last4: String?

            enum CodingKeys: String, CodingKey {
                case network, last4
                case accountNumber = "account_number"
            }
        }

    }

    struct NextAction: Decodable {
        let type: String?
        let redirect: Redirect?
        let authorize: Authorize?
        let confirmPayment: ConfirmPayment?
        let requestConfirmation: RequestConfirmation?

        enum CodingKeys: String, CodingKey {
            case type, redirect, authorize
            case confirmPayment = "confirm_payment"
            case requestConfirmation = "request_confirmation"
        }

        struct ConfirmationRequest: Decodable {
            let id: String?
            let recipient: String?
            let sentVia: String?
            let tokenSize: Int?

            enum CodingKeys: String, CodingKey {
                case id, recipient
                case sentVia = "sent_via"
                case tokenSize = "token_size"
            }
        }

        struct Redirect: Decodable {
            let validUntil: String?
            let redirectURL: String?

            enum CodingKeys: String, CodingKey {
                case validUntil = "valid_until"
                case redirectURL = "redirect_url"
            }
        }

        struct Authorize: Decodable {
            let expiresAt: String?
            let scheme: String?

            enum CodingKeys: String, CodingKey {
                case scheme
                case expiresAt = "expires_at"
            }
        }

        struct ConfirmPayment: Decodable {
            let expiresAt: String?
            let request: ConfirmationRequest?

            enum CodingKeys: String, CodingKey {
                case request
                case expiresAt = "expires_at"
            }
        }

        struct RequestConfirmation: Decodable {
            let lastRequest: ConfirmationRequest?
            let after: String?

            enum CodingKeys: String, CodingKey {
                case after
                case lastRequest = "last_request"
            }
        }
    }

    struct Invoice: Decodable {
        let beneficiary: Beneficiary?
        let format: DocumentFormat?

        struct Beneficiary: Decodable {
            let name: String?
            let alias: String?
            let supportLine: String?

            enum CodingKeys: String, CodingKey {
                case name, alias
                case supportLine = "invoice_support_line"
            }
        }
    }

    struct Document: Decodable {
        let format: DocumentFormat?
    }

    struct DocumentFormat: Decodable {
        let pdf: DocumentLink?
        let receipt: DocumentLink?
    }

    struct DocumentLink: Decodable {
        let url: String?
    }

    var paymentSheetDocuments: PaymentSheetSession.Documents {
        .init(
            invoiceURL: Self.httpsURL(from: invoice?.format?.pdf?.url),
            receiptURL: Self.httpsURL(
                from: payment?.receipt?.format?.pdf?.url
                    ?? invoice?.format?.receipt?.url
            )
        )
    }

    var paymentSheetSession: PaymentSheetSession {
        get throws {
        guard let amount = payment?.amount ?? lineItemGroup?.total else {
            throw PaymentSheetError.confirmationFailed(
                code: "invalid_checkout_response",
                message: "The checkout does not include a payable amount."
            )
        }
        var methods: [PaymentSheetSession.PaymentMethod] = []
        if let attachedMethod = payment?.paymentMethod {
            methods.append(try attachedMethod.paymentSheetMethod)
        }
        if payment?.paymentMethodTypes?.contains("mobile_money") == true {
            methods.append(
                .init(
                    id: "new_mobile_money",
                    kind: .mobileMoney,
                    source: .new,
                    label: methods.isEmpty ? "Mobile money" : "Use another mobile money number",
                    detail: "MTN MoMo, Telecel Cash, or AirtelTigo Money"
                )
            )
        }
        guard !methods.isEmpty else {
            throw PaymentSheetError.confirmationFailed(
                code: payment?.paymentMethod == nil
                    ? "payment_method_required" : "unsupported_payment_method",
                message: payment?.paymentMethod == nil
                    ? "This checkout does not have an available payment method."
                    : "This SDK version does not support the attached payment method."
            )
        }

        let beneficiary = invoice?.beneficiary
        let displayName = beneficiary?.name?.nonEmpty
            ?? beneficiary?.alias?.nonEmpty
            ?? "Inttegro checkout"
        let expiry = Self.date(from: expiresAt)
            ?? Self.date(from: paymentDueAt)
            ?? Self.date(from: payment?.dueAt)
            ?? .distantFuture

        return PaymentSheetSession(
            id: id,
            merchant: .init(
                displayName: displayName,
                supportText: beneficiary?.supportLine?.nonEmpty
            ),
            amount: .init(value: amount.value, currency: amount.currency),
            paymentMethods: methods,
            expiresAt: expiry,
            lineItems: lineItemGroup?.lineItems?.compactMap {
                $0.paymentSheetLineItem(
                    orderID: id,
                    merchantName: displayName,
                    expiresAt: expiry
                )
            } ?? [],
            documents: paymentSheetDocuments
        )
        }
    }

    private static func httpsURL(from value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https" else {
            return nil
        }
        return url
    }

    var confirmationChallenge: PaymentSheetConfirmationChallenge? {
        guard let action = payment?.nextAction else { return nil }
        switch action.type {
        case "confirm_payment":
            let confirmation = action.confirmPayment
            let request = confirmation?.request
            return PaymentSheetConfirmationChallenge(
                paymentID: payment?.id,
                confirmationID: request?.id,
                recipient: request?.recipient?.maskedRecipient,
                sentVia: request?.sentVia,
                tokenSize: request?.tokenSize.positive ?? 6,
                expiresAt: Self.date(from: confirmation?.expiresAt)
            )
        case "request_confirmation":
            let confirmation = action.requestConfirmation
            let request = confirmation?.lastRequest
            return PaymentSheetConfirmationChallenge(
                paymentID: payment?.id,
                confirmationID: request?.id,
                recipient: request?.recipient?.maskedRecipient,
                sentVia: request?.sentVia,
                tokenSize: request?.tokenSize.positive ?? 6,
                requestAfter: Self.date(from: confirmation?.after),
                requiresNewCode: true
            )
        default:
            return nil
        }
    }

    var externalAction: PaymentSheetExternalAction? {
        get throws {
            guard let action = payment?.nextAction else { return nil }
            switch action.type {
            case "redirect":
                guard let rawURL = action.redirect?.redirectURL,
                      let url = URL(string: rawURL),
                      url.scheme?.lowercased() == "https",
                      url.host?.isEmpty == false else {
                    throw PaymentSheetError.confirmationFailed(
                        code: "invalid_redirect_url",
                        message: "Inttegro returned an invalid payment-provider URL."
                    )
                }
                return .redirect(
                    url: url,
                    expiresAt: Self.date(from: action.redirect?.validUntil)
                )
            case "authorize_payment", "authorize":
                return .authorize(
                    scheme: action.authorize?.scheme?.nonEmpty,
                    expiresAt: Self.date(from: action.authorize?.expiresAt)
                )
            default:
                return nil
            }
        }
    }

    fileprivate static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private extension CheckoutOrder.PaymentMethod {
    var paymentSheetMethod: PaymentSheetSession.PaymentMethod {
        get throws {
            switch type {
            case "mobile_money":
                let network = mobileMoney?.network.networkDisplayName
                let label = network.map { "\($0) Mobile Money" } ?? "Mobile money"
                let last4 = mobileMoney?.last4?.nonEmpty
                    ?? mobileMoney?.accountNumber?.suffix(4).description.nonEmpty
                return .init(
                    id: id,
                    kind: .mobileMoney,
                    label: label,
                    detail: last4.map { "Account ending in \($0)" }
                )
            default:
                throw PaymentSheetError.confirmationFailed(
                    code: "unsupported_payment_method",
                    message: "This SDK version does not support the attached payment method."
                )
            }
        }
    }
}

private struct CheckoutAPIError: Decodable {
    let code: String?
    let message: String?
    let detail: String?

    func checkoutError(metadata: CheckoutResponseMetadata) -> PaymentSheetRequestError {
        PaymentSheetRequestError(
            code: code?.nonEmpty ?? "checkout_unavailable",
            message: message?.nonEmpty ?? detail?.nonEmpty ?? "The checkout could not be loaded.",
            requestID: metadata.requestID,
            retryAfterSeconds: metadata.retryAfterSeconds
        )
    }

    func confirmationError(metadata: CheckoutResponseMetadata) -> PaymentSheetRequestError {
        PaymentSheetRequestError(
            code: code?.nonEmpty ?? "confirmation_failed",
            message: message?.nonEmpty ?? detail?.nonEmpty ?? "The payment could not be authorized.",
            requestID: metadata.requestID,
            retryAfterSeconds: metadata.retryAfterSeconds
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var networkDisplayName: String {
        switch lowercased() {
        case "mtn": "MTN"
        case "airteltigo": "AirtelTigo"
        default: replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var maskedRecipient: String {
        if let at = firstIndex(of: "@") {
            let domain = self[at...]
            return "••••\(domain)"
        }
        let digits = filter(\.isNumber)
        guard !digits.isEmpty else { return "your payment method" }
        return "••• ••• \(digits.suffix(4))"
    }
}

private extension Optional where Wrapped == Int {
    var positive: Int? {
        flatMap { $0 > 0 ? $0 : nil }
    }
}

private extension Dictionary where Key == String, Value == Any {
    mutating func addIfPresent(_ key: String, _ value: String?) {
        if let value, !value.isEmpty {
            self[key] = value
        }
    }
}
