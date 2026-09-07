import Foundation

public struct PaymentSheetConfiguration: Sendable, Equatable {
    public struct Telemetry: Sendable, Equatable {
        public var enabled: Bool
        public var traceParent: String?
        public var traceState: String?

        public init(
            enabled: Bool = true,
            traceParent: String? = nil,
            traceState: String? = nil
        ) {
            self.enabled = enabled
            self.traceParent = traceParent
            self.traceState = traceState
        }

        var validTraceParent: String? {
            guard let traceParent,
                  traceParent.range(
                      of: "^(?!ff)[0-9a-f]{2}-(?!0{32})[0-9a-f]{32}-(?!0{16})[0-9a-f]{16}-[0-9a-f]{2}$",
                      options: .regularExpression
                  ) != nil else {
                return nil
            }
            return traceParent
        }

        var validTraceState: String? {
            guard let traceState,
                  traceState.utf8.count <= 512,
                  !traceState.contains("\r"),
                  !traceState.contains("\n") else {
                return nil
            }
            return traceState
        }
    }

    public struct Appearance: Sendable, Equatable {
        public var primaryColor: String?
        public var backgroundColor: String?
        public var textColor: String?
        public var cornerRadius: Double?

        public init(
            primaryColor: String? = nil,
            backgroundColor: String? = nil,
            textColor: String? = nil,
            cornerRadius: Double? = nil
        ) {
            self.primaryColor = primaryColor
            self.backgroundColor = backgroundColor
            self.textColor = textColor
            self.cornerRadius = cornerRadius
        }
    }

    public let orderID: String
    public let returnURL: URL?
    public let appearance: Appearance
    public let telemetry: Telemetry

    public init(
        orderID: String,
        returnURL: URL? = nil,
        appearance: Appearance = .init(),
        telemetry: Telemetry = .init()
    ) throws {
        let normalizedOrderID = orderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOrderID.isEmpty else {
            throw PaymentSheetError.invalidConfiguration(
                "orderID must not be empty"
            )
        }
        if let cornerRadius = appearance.cornerRadius,
           !(0 ... 40).contains(cornerRadius) {
            throw PaymentSheetError.invalidConfiguration(
                "appearance.cornerRadius must be between 0 and 40"
            )
        }
        for (name, color) in [
            ("primaryColor", appearance.primaryColor),
            ("backgroundColor", appearance.backgroundColor),
            ("textColor", appearance.textColor),
        ] where color != nil {
            guard color?.range(
                of: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$",
                options: .regularExpression
            ) != nil else {
                throw PaymentSheetError.invalidConfiguration(
                    "appearance.\(name) must be a six or eight digit hex color"
                )
            }
        }
        if let returnURL, returnURL.scheme?.isEmpty != false {
            throw PaymentSheetError.invalidConfiguration(
                "returnURL must be an absolute URL"
            )
        }
        if telemetry.traceParent != nil, telemetry.validTraceParent == nil {
            throw PaymentSheetError.invalidConfiguration(
                "telemetry.traceparent must be a valid W3C trace parent"
            )
        }
        if telemetry.traceState != nil, telemetry.validTraceState == nil {
            throw PaymentSheetError.invalidConfiguration(
                "telemetry.tracestate must be at most 512 bytes without newlines"
            )
        }

        self.orderID = normalizedOrderID
        self.returnURL = returnURL
        self.appearance = appearance
        self.telemetry = telemetry
    }
}

public struct PaymentSheetSession: Sendable, Equatable {
    public struct Merchant: Sendable, Equatable {
        public let displayName: String
        public let supportText: String?

        public init(displayName: String, supportText: String? = nil) {
            self.displayName = displayName
            self.supportText = supportText
        }
    }

    public struct Money: Sendable, Equatable {
        public let value: Int
        public let currency: String

        public init(value: Int, currency: String) {
            self.value = value
            self.currency = currency.uppercased()
        }

        public var formatted: String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            let decimal = Decimal(value) / 100
            return formatter.string(from: decimal as NSDecimalNumber)
                ?? "\(currency) \(decimal)"
        }
    }

    public struct PaymentMethod: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable {
            case zeboWallet = "zebo_wallet"
            case mobileMoney = "mobile_money"
        }

        public enum Source: String, Sendable {
            case saved
            case new
        }

        public let id: String
        public let kind: Kind
        public let source: Source
        public let label: String
        public let detail: String?

        public init(
            id: String,
            kind: Kind,
            source: Source = .saved,
            label: String,
            detail: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.source = source
            self.label = label
            self.detail = detail
        }
    }

    public let id: String
    public let merchant: Merchant
    public let amount: Money
    public let paymentMethods: [PaymentMethod]
    public let expiresAt: Date

    public init(
        id: String,
        merchant: Merchant,
        amount: Money,
        paymentMethods: [PaymentMethod],
        expiresAt: Date
    ) {
        self.id = id
        self.merchant = merchant
        self.amount = amount
        self.paymentMethods = paymentMethods
        self.expiresAt = expiresAt
    }
}

public struct PaymentSheetMobileMoneyInput: Sendable, Equatable {
    public enum Network: String, CaseIterable, Sendable {
        case mtn
        case vodafone
        case airtel
        case telecel

        static let paymentSheetOptions: [Self] = [.mtn, .telecel, .airtel]

        public var displayName: String {
            switch self {
            case .mtn: "MTN"
            case .vodafone: "Vodafone"
            case .airtel: "AirtelTigo"
            case .telecel: "Telecel"
            }
        }

        var productName: String {
            switch self {
            case .mtn: "MoMo"
            case .vodafone, .telecel: "Cash"
            case .airtel: "Money"
            }
        }

        var paymentSheetAssetName: String {
            switch self {
            case .mtn: "InttegroMobileMoneyMTN"
            case .vodafone, .telecel: "InttegroMobileMoneyTelecel"
            case .airtel: "InttegroMobileMoneyAirtelTigo"
            }
        }
    }

    public struct BillingDetails: Sendable, Equatable {
        public struct Address: Sendable, Equatable {
            public let line1: String?
            public let line2: String?
            public let city: String?
            public let region: String?
            public let postCode: String?
            public let country: String

            public init(
                line1: String? = nil,
                line2: String? = nil,
                city: String? = nil,
                region: String? = nil,
                postCode: String? = nil,
                country: String
            ) {
                self.line1 = line1
                self.line2 = line2
                self.city = city
                self.region = region
                self.postCode = postCode
                self.country = country
            }
        }

        public let name: String
        public let phoneNumber: String?
        public let address: Address

        public init(name: String, phoneNumber: String? = nil, address: Address) {
            self.name = name
            self.phoneNumber = phoneNumber
            self.address = address
        }
    }

    public let network: Network
    public let accountNumber: String
    public let billingDetails: BillingDetails?
    public let savePaymentMethod: Bool

    public init(
        network: Network,
        accountNumber: String,
        billingDetails: BillingDetails? = nil,
        savePaymentMethod: Bool = false
    ) {
        self.network = network
        self.accountNumber = accountNumber
        self.billingDetails = billingDetails
        self.savePaymentMethod = savePaymentMethod
    }
}

public enum PaymentSheetPaymentSelection: Sendable, Equatable {
    case saved(PaymentSheetSession.PaymentMethod)
    case mobileMoney(PaymentSheetMobileMoneyInput)
}

public struct PaymentSheetConfirmationChallenge: Sendable, Equatable {
    public let paymentID: String?
    public let confirmationID: String?
    public let recipient: String?
    public let sentVia: String?
    public let tokenSize: Int
    public let expiresAt: Date?
    public let requestAfter: Date?
    public let requiresNewCode: Bool

    public init(
        paymentID: String? = nil,
        confirmationID: String? = nil,
        recipient: String? = nil,
        sentVia: String? = nil,
        tokenSize: Int = 6,
        expiresAt: Date? = nil,
        requestAfter: Date? = nil,
        requiresNewCode: Bool = false
    ) {
        self.paymentID = paymentID
        self.confirmationID = confirmationID
        self.recipient = recipient
        self.sentVia = sentVia
        self.tokenSize = tokenSize
        self.expiresAt = expiresAt
        self.requestAfter = requestAfter
        self.requiresNewCode = requiresNewCode
    }
}

public enum PaymentSheetExternalAction: Sendable, Equatable {
    case redirect(url: URL, expiresAt: Date?)
    case authorize(scheme: String?, expiresAt: Date?)
}

public enum PaymentSheetPaymentOutcome: Sendable, Equatable {
    case completed(paymentID: String?)
    case requiresConfirmation(PaymentSheetConfirmationChallenge)
    case pending(PaymentSheetExternalAction?)
}

public enum PaymentSheetResult: Sendable, Equatable {
    case completed(paymentID: String?)
    case canceled
    case failed(PaymentSheetFailure)
}

public struct PaymentSheetFailure: Sendable, Equatable {
    public let code: String
    public let message: String
    public let declineCode: String?

    public init(code: String, message: String, declineCode: String? = nil) {
        self.code = code
        self.message = message
        self.declineCode = declineCode
    }
}

public enum PaymentSheetError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case checkoutUnavailable
    case checkoutExpired
    case confirmationFailed(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            message
        case .checkoutUnavailable:
            "The checkout could not be loaded."
        case .checkoutExpired:
            "This checkout has expired."
        case let .confirmationFailed(_, message):
            message
        }
    }

    public var code: String {
        switch self {
        case .invalidConfiguration:
            "invalid_configuration"
        case .checkoutUnavailable:
            "checkout_unavailable"
        case .checkoutExpired:
            "checkout_expired"
        case let .confirmationFailed(code, _):
            code
        }
    }
}
