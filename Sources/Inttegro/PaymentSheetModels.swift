import Foundation

/// Everything Inttegro needs to prepare one native Checkout presentation.
///
/// Create this value with either a finalized Order ID or a public Purchase
/// Intent backed by a customer-selected amount price. The SDK intentionally
/// does not accept a merchant API key or merchant-supplied display terms:
/// Checkout remains authoritative for currency, range, merchant identity, and
/// the finalized Order.
///
/// Configuration is validated synchronously. Reuse it for retries of the same
/// presentation, and create a new value when its Checkout reference or
/// presentation options change.
///
/// ```swift
/// let configuration = try PaymentSheetConfiguration(
///     orderID: checkout.orderID,
///     returnURL: URL(string: "merchant-app://inttegro-return"),
///     features: .init(showLineItems: true)
/// )
/// ```
public struct PaymentSheetConfiguration: Sendable, Equatable {
    /// Optional content and actions exposed by the payment sheet.
    ///
    /// These settings change presentation only. They cannot change the Order,
    /// its shipping address, its amount, or the customer that owns an attached
    /// payment method.
    public struct Features: Sendable, Equatable {
        /// Whether the sheet offers an expandable Order summary before payment.
        ///
        /// Defaults to `false`. Items remain collapsed until the payer opens
        /// the summary, which promotes the sheet to its large detent. The amount
        /// displayed by the sheet always comes from Checkout.
        public var showLineItems: Bool
        /// Whether to offer a Checkout-provided invoice after payment succeeds.
        ///
        /// Defaults to `false`. The action appears only when Checkout returns an
        /// invoice URL for the completed payment.
        public var showInvoiceDownload: Bool
        /// Whether to offer a Checkout-provided receipt after payment succeeds.
        ///
        /// Defaults to `false`. The action appears only when Checkout returns a
        /// receipt URL for the completed payment.
        public var showReceiptDownload: Bool
        /// Whether the payer may choose a different method from an attached one.
        ///
        /// Defaults to `true`. Turning this off does not prevent collection when
        /// the Order has no attached payment method.
        public var allowPaymentMethodChange: Bool

        /// Creates payment-sheet presentation options.
        ///
        /// - Parameters:
        ///   - showLineItems: Offer a collapsed, expandable Order summary.
        ///   - showInvoiceDownload: Offer an invoice after successful payment.
        ///   - showReceiptDownload: Offer a receipt after successful payment.
        ///   - allowPaymentMethodChange: Permit replacement of an attached method.
        public init(
            showLineItems: Bool = false,
            showInvoiceDownload: Bool = false,
            showReceiptDownload: Bool = false,
            allowPaymentMethodChange: Bool = true
        ) {
            self.showLineItems = showLineItems
            self.showInvoiceDownload = showInvoiceDownload
            self.showReceiptDownload = showReceiptDownload
            self.allowPaymentMethodChange = allowPaymentMethodChange
        }
    }

    /// Host-owned diagnostic and distributed-tracing options.
    ///
    /// Inttegro emits a privacy-safe event stream but installs no exporter. If a
    /// valid W3C trace context is supplied, the native Checkout transport
    /// forwards it while telemetry is enabled.
    public struct Telemetry: Sendable, Equatable {
        /// Whether diagnostic events and trace propagation are enabled.
        public var enabled: Bool
        /// A valid W3C `traceparent` value supplied by the host application.
        public var traceParent: String?
        /// Optional W3C `tracestate`, limited to 512 UTF-8 bytes and no newlines.
        public var traceState: String?

        /// Creates telemetry options for a payment-sheet presentation.
        ///
        /// - Parameters:
        ///   - enabled: Enables events and trace propagation. Defaults to `true`.
        ///   - traceParent: Host-generated W3C `traceparent` value.
        ///   - traceState: Optional host-generated W3C `tracestate` value.
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

    /// Restrained visual overrides applied to the native sheet.
    ///
    /// Omit values to inherit platform and application defaults. Inttegro keeps
    /// native controls, accessibility behavior, layout, and state semantics even
    /// when colors or corner radius are customized.
    public struct Appearance: Sendable, Equatable {
        /// Primary action color as `#RRGGBB` or `#RRGGBBAA`.
        public var primaryColor: String?
        /// Sheet surface color as `#RRGGBB` or `#RRGGBBAA`.
        public var backgroundColor: String?
        /// Primary foreground color as `#RRGGBB` or `#RRGGBBAA`.
        public var textColor: String?
        /// Preferred sheet corner radius in points, from `0` through `40`.
        public var cornerRadius: Double?

        /// Creates optional appearance overrides.
        ///
        /// - Parameters:
        ///   - primaryColor: Primary action color in hexadecimal notation.
        ///   - backgroundColor: Sheet surface color in hexadecimal notation.
        ///   - textColor: Primary foreground color in hexadecimal notation.
        ///   - cornerRadius: Sheet corner radius from `0` through `40` points.
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

    /// Public identifier of the finalized Order to retrieve through Checkout.
    public let orderID: String?
    /// Public Purchase Intent whose amount the payer must choose before payment.
    public let purchaseIntentID: String?
    /// Application URL used when a provider returns control to the merchant app.
    public let returnURL: URL?
    /// Optional native appearance overrides.
    public let appearance: Appearance
    /// Host-owned telemetry and trace-context options.
    public let telemetry: Telemetry
    /// Optional content and post-payment actions exposed by the sheet.
    public let features: Features

    /// Creates and validates a payment-sheet configuration.
    ///
    /// - Parameters:
    ///   - orderID: Public ID of an Order created and finalized by the backend.
    ///   - returnURL: Absolute application URL for provider return flows.
    ///   - appearance: Restrained native appearance overrides.
    ///   - telemetry: Host-owned diagnostics and trace-context options.
    ///   - features: Optional content and post-payment actions.
    /// - Throws: ``PaymentSheetError/invalidConfiguration(_:)`` when the Order
    ///   ID is empty, a URL or trace value is malformed, a color is invalid, or
    ///   the requested corner radius is outside its supported range.
    public init(
        orderID: String,
        returnURL: URL? = nil,
        appearance: Appearance = .init(),
        telemetry: Telemetry = .init(),
        features: Features = .init()
    ) throws {
        let normalizedOrderID = orderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOrderID.isEmpty else {
            throw PaymentSheetError.invalidConfiguration(
                "orderID must not be empty"
            )
        }
        try Self.validatePresentationOptions(
            returnURL: returnURL,
            appearance: appearance,
            telemetry: telemetry
        )

        self.orderID = normalizedOrderID
        purchaseIntentID = nil
        self.returnURL = returnURL
        self.appearance = appearance
        self.telemetry = telemetry
        self.features = features
    }

    /// Creates a payment sheet that begins with customer-selected amount entry.
    ///
    /// Checkout loads the allowed currency and range from the Purchase Intent.
    /// After the payer chooses an amount, Inttegro creates the finalized Order
    /// idempotently and continues through the ordinary native payment flow.
    public init(
        purchaseIntentID: String,
        returnURL: URL? = nil,
        appearance: Appearance = .init(),
        telemetry: Telemetry = .init(),
        features: Features = .init()
    ) throws {
        let normalizedPurchaseIntentID = purchaseIntentID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPurchaseIntentID.isEmpty else {
            throw PaymentSheetError.invalidConfiguration(
                "purchaseIntentID must not be empty"
            )
        }
        try Self.validatePresentationOptions(
            returnURL: returnURL,
            appearance: appearance,
            telemetry: telemetry
        )

        orderID = nil
        self.purchaseIntentID = normalizedPurchaseIntentID
        self.returnURL = returnURL
        self.appearance = appearance
        self.telemetry = telemetry
        self.features = features
    }

    private static func validatePresentationOptions(
        returnURL: URL?,
        appearance: Appearance,
        telemetry: Telemetry
    ) throws {
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
    }
}

/// Client-safe policy for creating or editing a customer-selected checkout.
///
/// ``purchaseIntentID`` is present while creating an Order from a Buy link;
/// ``orderID`` is present while changing a still-pristine existing Order.
public struct PaymentSheetAmountSelection: Sendable, Equatable {
    /// One convenient amount suggested by the merchant.
    public struct Suggestion: Sendable, Equatable, Identifiable {
        public let id: String
        public let value: Int
        public let recommended: Bool

        public init(id: String, value: Int, recommended: Bool = false) {
            self.id = id
            self.value = value
            self.recommended = recommended
        }
    }

    public let purchaseIntentID: String?
    public let orderID: String?
    public let lineItemID: String?
    public let merchantName: String
    public let productName: String
    public let productAbout: String?
    public let currency: String
    public let minimum: Int
    public let maximum: Int?
    public let suggestions: [Suggestion]
    public let expiresAt: Date?

    public init(
        purchaseIntentID: String? = nil,
        orderID: String? = nil,
        lineItemID: String? = nil,
        merchantName: String,
        productName: String,
        productAbout: String? = nil,
        currency: String,
        minimum: Int,
        maximum: Int? = nil,
        suggestions: [Suggestion] = [],
        expiresAt: Date? = nil
    ) {
        self.purchaseIntentID = purchaseIntentID
        self.orderID = orderID
        self.lineItemID = lineItemID
        self.merchantName = merchantName
        self.productName = productName
        self.productAbout = productAbout
        self.currency = currency.uppercased()
        self.minimum = minimum
        self.maximum = maximum
        self.suggestions = suggestions
        self.expiresAt = expiresAt
    }
}

/// Client-safe Checkout data used during one payment-sheet presentation.
///
/// The default Checkout adapter constructs this value from Inttegro's public
/// projection. Applications normally read it only when implementing a custom
/// ``PaymentSheetAdapter``; they must not treat it as an editable Order.
public struct PaymentSheetSession: Sendable, Equatable {
    /// Merchant identity displayed to the payer.
    public struct Merchant: Sendable, Equatable {
        /// Merchant-controlled display name returned by Checkout.
        public let displayName: String
        /// Optional short support or trust message returned by Checkout.
        public let supportText: String?

        /// Creates display information for a custom payment-sheet adapter.
        public init(displayName: String, supportText: String? = nil) {
            self.displayName = displayName
            self.supportText = supportText
        }
    }

    /// A monetary amount represented in the currency's minor unit.
    public struct Money: Sendable, Equatable {
        /// Amount in the currency's minor unit, such as pesewas for GHS.
        public let value: Int
        /// ISO 4217 currency code.
        public let currency: String

        /// Creates a monetary value and normalizes the currency to uppercase.
        public init(value: Int, currency: String) {
            self.value = value
            self.currency = currency.uppercased()
        }

        /// Locale-aware display text suitable for the native payment sheet.
        public var formatted: String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            let scale = pow(10.0, Double(formatter.maximumFractionDigits))
            let decimal = Decimal(value) / Decimal(scale)
            return formatter.string(from: decimal as NSDecimalNumber)
                ?? "\(currency) \(decimal)"
        }
    }

    /// A saved or newly collected method that the payer can select.
    public struct PaymentMethod: Sendable, Equatable, Identifiable {
        /// Payment-method families supported by this SDK version.
        public enum Kind: String, Sendable {
            /// A method backed by a Zebo Wallet.
            case zeboWallet = "zebo_wallet"
            /// A Ghanaian Mobile Money account.
            case mobileMoney = "mobile_money"
        }

        /// Where the method came from for this presentation.
        public enum Source: String, Sendable {
            /// An existing method attached to the Order's customer.
            case saved
            /// A new method whose details the payer must provide.
            case new
        }

        /// Stable Checkout identifier for the selectable method.
        public let id: String
        /// Payment-method family used to select the native collection UI.
        public let kind: Kind
        /// Whether the method is already saved or needs collection.
        public let source: Source
        /// Primary payer-facing label supplied by Checkout.
        public let label: String
        /// Optional secondary payer-facing description.
        public let detail: String?

        /// Creates a selectable method for a custom adapter or preview.
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

    /// A purchasable item displayed in the optional Order summary.
    public struct LineItem: Sendable, Equatable, Identifiable {
        /// Stable identifier supplied by Checkout.
        public let id: String
        /// Payer-facing product or service name.
        public let name: String
        /// Optional quantity when Checkout exposes one.
        public let quantity: Int?
        /// Checkout-calculated total for this line.
        public let total: Money
        /// Customer-selected policy when this exact line can still be repriced.
        public let amountSelection: PaymentSheetAmountSelection?

        /// Creates a line item for a custom adapter or preview.
        public init(
            id: String,
            name: String,
            quantity: Int? = nil,
            total: Money,
            amountSelection: PaymentSheetAmountSelection? = nil
        ) {
            self.id = id
            self.name = name
            self.quantity = quantity
            self.total = total
            self.amountSelection = amountSelection
        }
    }

    /// Documents that Checkout made available after payment completed.
    public struct Documents: Sendable, Equatable {
        /// HTTPS location of the completed Order's invoice, when available.
        public let invoiceURL: URL?
        /// HTTPS location of the completed payment's receipt, when available.
        public let receiptURL: URL?

        /// Creates post-payment document actions for a custom adapter.
        public init(invoiceURL: URL? = nil, receiptURL: URL? = nil) {
            self.invoiceURL = invoiceURL
            self.receiptURL = receiptURL
        }

        func merging(_ newer: Documents) -> Documents {
            .init(
                invoiceURL: newer.invoiceURL ?? invoiceURL,
                receiptURL: newer.receiptURL ?? receiptURL
            )
        }
    }

    /// Public Order identifier backing the Checkout session.
    public let id: String
    /// Merchant identity displayed to the payer.
    public let merchant: Merchant
    /// Checkout-calculated amount the payer is authorizing.
    public let amount: Money
    /// Saved and collectable payment-method choices.
    public let paymentMethods: [PaymentMethod]
    /// Time after which the client must stop using this Checkout projection.
    public let expiresAt: Date
    /// Optional Checkout-provided line items.
    public let lineItems: [LineItem]
    /// Invoice and receipt links currently available from Checkout.
    public let documents: Documents

    /// Creates a client-safe Checkout session for a custom adapter.
    ///
    /// Production applications normally receive this value from
    /// ``CheckoutPaymentSheetAdapter`` rather than constructing it themselves.
    public init(
        id: String,
        merchant: Merchant,
        amount: Money,
        paymentMethods: [PaymentMethod],
        expiresAt: Date,
        lineItems: [LineItem] = [],
        documents: Documents = .init()
    ) {
        self.id = id
        self.merchant = merchant
        self.amount = amount
        self.paymentMethods = paymentMethods
        self.expiresAt = expiresAt
        self.lineItems = lineItems
        self.documents = documents
    }
}

/// Payer-supplied Mobile Money details for a new payment method.
///
/// Account numbers are collected with the native segmented input and sent only
/// to Checkout. Billing details are collected only when the payer explicitly
/// saves the method. The native sheet requires a complete billing address and
/// never passes shipping details through this value.
public struct PaymentSheetMobileMoneyInput: Sendable, Equatable {
    /// Ghanaian Mobile Money networks recognized by Checkout.
    public enum Network: String, CaseIterable, Sendable {
        /// MTN Mobile Money.
        case mtn
        /// Legacy Vodafone Cash wire value retained for existing integrations.
        case vodafone
        /// AirtelTigo Money.
        case airtel
        /// Telecel Cash.
        case telecel

        static let paymentSheetOptions: [Self] = [.mtn, .telecel, .airtel]

        /// Current network name shown to the payer.
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

    /// Personal and billing information supplied when saving a new method.
    public struct BillingDetails: Sendable, Equatable {
        /// Billing address for the person saving the payment method.
        public struct Address: Sendable, Equatable {
            /// First street-address line.
            public let line1: String?
            /// Optional second street-address line.
            public let line2: String?
            /// City or locality.
            public let city: String?
            /// Region, state, or province.
            public let region: String?
            /// Postal code, when used by the country.
            public let postCode: String?
            /// Two-letter ISO 3166-1 country code.
            public let country: String

            /// Creates the payer's billing address.
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

        /// Name of the person who owns the payment method.
        public let name: String
        /// Optional contact number for the payment-method owner.
        public let phoneNumber: String?
        /// Billing address associated with the saved method.
        public let address: Address

        /// Creates personal and billing details for a saved method.
        public init(name: String, phoneNumber: String? = nil, address: Address) {
            self.name = name
            self.phoneNumber = phoneNumber
            self.address = address
        }
    }

    /// Network selected by the payer, including overrides for ported numbers.
    public let network: Network
    /// Mobile Money account number entered by the payer.
    public let accountNumber: String
    /// Optional personal and billing details used when saving the method.
    public let billingDetails: BillingDetails?
    /// Whether Checkout should save the method to the Order's customer.
    public let savePaymentMethod: Bool

    /// Creates a new Mobile Money payment selection.
    ///
    /// - Parameters:
    ///   - network: Current network selected or confirmed by the payer.
    ///   - accountNumber: Mobile Money number entered by the payer.
    ///   - billingDetails: Personal and billing details used when saving.
    ///   - savePaymentMethod: Whether to attach the new method to the customer.
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

/// The payer's selected source for the next payment attempt.
public enum PaymentSheetPaymentSelection: Sendable, Equatable {
    /// Continue with a method already attached to the immutable customer.
    case saved(PaymentSheetSession.PaymentMethod)
    /// Pay with newly entered Mobile Money details.
    case mobileMoney(PaymentSheetMobileMoneyInput)
}

/// A recoverable confirmation-code challenge returned by Checkout.
public struct PaymentSheetConfirmationChallenge: Sendable, Equatable {
    /// Payment being confirmed, when Checkout makes it available.
    public let paymentID: String?
    /// Server-issued confirmation challenge identifier.
    public let confirmationID: String?
    /// Masked destination to which the code was sent.
    public let recipient: String?
    /// Delivery channel, such as `sms`, when provided.
    public let sentVia: String?
    /// Exact number of numeric digits the payer must enter.
    public let tokenSize: Int
    /// Time after which the current code is no longer valid.
    public let expiresAt: Date?
    /// Earliest time at which the payer may request another code.
    public let requestAfter: Date?
    /// Whether Checkout requires a new code before confirmation can continue.
    public let requiresNewCode: Bool

    /// Creates a confirmation challenge for a custom adapter.
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

/// Provider-owned work that must finish outside the payment sheet.
public enum PaymentSheetExternalAction: Sendable, Equatable {
    /// Open a secure web redirect and return through the configured URL.
    case redirect(url: URL, expiresAt: Date?)
    /// Ask the payer to approve the request in a provider or device experience.
    case authorize(scheme: String?, expiresAt: Date?)
}

/// Intermediate outcome returned by a ``PaymentSheetAdapter`` operation.
///
/// The native state machine consumes these values. Applications should use
/// ``PaymentSheetResult`` for terminal presentation behavior.
public enum PaymentSheetPaymentOutcome: Sendable, Equatable {
    /// Checkout reports payment completion and may provide document actions.
    case completed(paymentID: String?, documents: PaymentSheetSession.Documents = .init())
    /// The payer must enter a confirmation code inside the sheet.
    case requiresConfirmation(PaymentSheetConfirmationChallenge)
    /// Provider authorization or asynchronous processing is still outstanding.
    case pending(PaymentSheetExternalAction?)
}

/// Terminal result of one native payment-sheet presentation.
///
/// A completed client result is not authorization to fulfill an Order. The
/// merchant backend must retrieve the owner-scoped Order and verify its
/// authoritative payment state.
public enum PaymentSheetResult: Sendable, Equatable {
    /// The native experience reached its Checkout-confirmed success state.
    case completed(paymentID: String?)
    /// The payer dismissed the sheet before completion.
    case canceled
    /// A terminal SDK or Checkout failure prevented the flow from continuing.
    case failed(PaymentSheetFailure)
}

/// Stable, application-facing details for a terminal payment-sheet failure.
public struct PaymentSheetFailure: Sendable, Equatable {
    /// Machine-readable failure category suitable for branching.
    public let code: String
    /// Payer-safe or developer-facing description supplied by the SDK.
    public let message: String
    /// Optional processor decline classification.
    public let declineCode: String?
    /// Inttegro request identifier suitable for support correlation.
    public let requestID: String?
    /// Server-directed delay before the same operation should be retried.
    public let retryAfterSeconds: Int?

    /// Creates a failure value for a custom adapter.
    public init(
        code: String,
        message: String,
        declineCode: String? = nil,
        requestID: String? = nil,
        retryAfterSeconds: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.declineCode = declineCode
        self.requestID = requestID
        self.retryAfterSeconds = retryAfterSeconds
    }
}

struct PaymentSheetRequestError: LocalizedError, Sendable {
    let code: String
    let message: String
    let declineCode: String?
    let requestID: String?
    let retryAfterSeconds: Int?

    init(
        code: String,
        message: String,
        declineCode: String? = nil,
        requestID: String? = nil,
        retryAfterSeconds: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.declineCode = declineCode
        self.requestID = requestID
        self.retryAfterSeconds = retryAfterSeconds
    }

    var errorDescription: String? { message }
}

/// Errors raised while configuring or retrieving Checkout.
public enum PaymentSheetError: LocalizedError, Sendable, Equatable {
    /// A client-owned configuration value failed validation.
    case invalidConfiguration(String)
    /// Checkout could not be retrieved or decoded safely.
    case checkoutUnavailable
    /// Checkout expired before payment could continue.
    case checkoutExpired
    /// Confirmation failed with a stable code and payer-safe message.
    case confirmationFailed(code: String, message: String)

    /// Human-readable description used by native error presentation.
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

    /// Stable machine-readable error code.
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
