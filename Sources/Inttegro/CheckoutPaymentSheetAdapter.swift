import CryptoKit
import Foundation

/// The public Checkout transport used by ``PaymentSheet``.
///
/// This adapter never accepts an API key. The finalized Order ID is the
/// capability used to look up and pay the immutable checkout.
public struct CheckoutPaymentSheetAdapter: PaymentSheetAdapter {
    typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL
    private let executeRequest: RequestExecutor
    private let attemptKeys: PaymentAttemptKeys
    private let telemetry: PaymentSheetTelemetry?

    public init(
        baseURL: URL = URL(string: "https://api.inttegro.com")!,
        telemetry: PaymentSheetTelemetry? = nil
    ) {
        self.init(
            baseURL: baseURL,
            executeRequest: { request in
                try await URLSession.shared.data(for: request)
            },
            telemetry: telemetry
        )
    }

    init(
        baseURL: URL,
        executeRequest: @escaping RequestExecutor,
        telemetry: PaymentSheetTelemetry? = nil
    ) {
        self.baseURL = baseURL
        self.executeRequest = executeRequest
        self.telemetry = telemetry
        attemptKeys = PaymentAttemptKeys()
    }

    public func retrieveCheckout(orderID: String) async throws -> PaymentSheetSession {
        let envelope = try await post(
            path: "checkout/lookup",
            body: ["order_id": orderID]
        )
        if let error = envelope.error {
            throw error.checkoutError
        }
        guard let order = envelope.order else {
            throw PaymentSheetError.checkoutUnavailable
        }
        return try order.paymentSheetSession
    }

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
            throw error.confirmationError
        }
        guard let order = envelope.order else {
            throw PaymentSheetError.confirmationFailed(
                code: "invalid_checkout_response",
                message: "Inttegro returned an invalid checkout response."
            )
        }

        if order.status == "paid" || order.status == "completed" || order.payment?.status == "paid" {
            return .completed(paymentID: order.payment?.id)
        }
        if let latestError = order.payment?.latestError {
            throw latestError.confirmationError
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
        throw PaymentSheetError.confirmationFailed(
            code: "payment_requires_action",
            message: "This payment needs an authorization step that this SDK version does not support yet."
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
        request.setValue("inttegro-sdk-ios/0.1.0", forHTTPHeaderField: "User-Agent")
        telemetry?.applyTraceContext(to: &request)
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id")
        telemetry?.emit(
            .responseReceived,
            operation: operation,
            httpStatusCode: httpResponse.statusCode,
            requestID: requestID
        )

        let envelope: CheckoutEnvelope
        do {
            envelope = try JSONDecoder().decode(CheckoutEnvelope.self, from: data)
        } catch {
            telemetry?.emit(
                .requestFailed,
                operation: operation,
                httpStatusCode: httpResponse.statusCode,
                requestID: requestID,
                errorType: "decode_error"
            )
            if (200 ..< 300).contains(httpResponse.statusCode) {
                throw PaymentSheetError.checkoutUnavailable
            }
            throw PaymentSheetError.confirmationFailed(
                code: "checkout_http_\(httpResponse.statusCode)",
                message: "Inttegro could not complete the checkout request."
            )
        }
        if !(200 ..< 300).contains(httpResponse.statusCode), envelope.error == nil {
            telemetry?.emit(
                .requestFailed,
                operation: operation,
                httpStatusCode: httpResponse.statusCode,
                requestID: requestID,
                errorType: "checkout_http_\(httpResponse.statusCode)"
            )
            throw PaymentSheetError.confirmationFailed(
                code: "checkout_http_\(httpResponse.statusCode)",
                message: "Inttegro could not complete the checkout request."
            )
        }
        telemetry?.emit(
            .responseDecoded,
            operation: operation,
            httpStatusCode: httpResponse.statusCode,
            requestID: requestID
        )
        return envelope
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
    let error: CheckoutAPIError?
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
        let total: Money?
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

        enum CodingKeys: String, CodingKey {
            case id, amount, status
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
                expiresAt: expiry
            )
        }
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

    private static func date(from value: String?) -> Date? {
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

    var checkoutError: PaymentSheetError {
        .confirmationFailed(
            code: code?.nonEmpty ?? "checkout_unavailable",
            message: message?.nonEmpty ?? detail?.nonEmpty ?? "The checkout could not be loaded."
        )
    }

    var confirmationError: PaymentSheetError {
        .confirmationFailed(
            code: code?.nonEmpty ?? "confirmation_failed",
            message: message?.nonEmpty ?? detail?.nonEmpty ?? "The payment could not be authorized."
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
