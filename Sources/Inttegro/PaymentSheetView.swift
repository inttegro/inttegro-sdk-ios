import SafariServices
import SwiftUI

struct PaymentSheetView: View {
    private enum InputField: Hashable {
        case accountNumber
        case billingName
        case billingPhone
        case billingLine1
        case billingCity
        case billingRegion
        case billingPostCode
        case confirmationToken
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: InputField?
    @State private var redirectDestination: RedirectDestination?
    @State private var selectedDetent: PresentationDetent = .medium
    @ObservedObject var model: PaymentSheetViewModel
    let onResult: (PaymentSheetResult) -> Void

    private var primaryColor: Color {
        Color(hex: model.configuration.appearance.primaryColor) ?? .accentColor
    }

    private var textColor: Color {
        Color(hex: model.configuration.appearance.textColor)
            ?? Color(uiColor: .label)
    }

    private var primaryButtonForegroundColor: Color {
        Color.contrastingForeground(
            forHex: model.configuration.appearance.primaryColor
        ) ?? .white
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    loadingView
                case let .ready(session):
                    checkoutView(session: session, isProcessing: false)
                case let .processing(session):
                    checkoutView(session: session, isProcessing: true)
                case let .confirmation(session, challenge, isProcessing, failure):
                    confirmationView(
                        session: session,
                        challenge: challenge,
                        isProcessing: isProcessing,
                        failure: failure
                    )
                case let .awaitingResult(session, action, isRefreshing, failure):
                    awaitingResultView(
                        session: session,
                        action: action,
                        isRefreshing: isRefreshing,
                        failure: failure
                    )
                case let .completed(session, _):
                    completedView(session)
                case let .failed(failure):
                    failureView(failure)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(sheetBackground)
            .foregroundStyle(textColor)
            .fontWeight(.regular)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Payment")
                        .font(.headline.weight(.regular))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") {
                        onResult(model.completedResult ?? .canceled)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.isProcessing)
                    .accessibilityLabel("Close payment sheet")
                }
            }
        }
        .tint(primaryColor)
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .interactiveDismissDisabled(model.isProcessing || model.completedResult != nil)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: model.state)
        .task {
            if case .loading = model.state {
                await model.load()
            }
        }
        .task(id: model.isAwaitingResult) {
            guard model.isAwaitingResult else { return }
            try? await Task.sleep(for: .milliseconds(2_500))
            while !Task.isCancelled, model.isAwaitingResult {
                if let result = await model.refreshPayment() {
                    onResult(result)
                    return
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: prefersLargeDetent) { shouldExpand in
            selectedDetent = shouldExpand ? .large : .medium
        }
        .onChange(of: model.networkSuggestionHint) { hint in
            guard UIAccessibility.isVoiceOverRunning, let hint else { return }
            UIAccessibility.post(notification: .announcement, argument: hint)
        }
        .fullScreenCover(item: $redirectDestination) { destination in
            SafariView(url: destination.url)
                .ignoresSafeArea()
        }
    }

    private var prefersLargeDetent: Bool {
        switch model.state {
        case .confirmation, .awaitingResult:
            return true
        case .completed:
            return false
        default:
            return model.selectedMethod?.source == .new || model.savePaymentMethod
        }
    }

    private var sheetBackground: some View {
        Group {
            if let color = Color(hex: model.configuration.appearance.backgroundColor) {
                color
            } else {
                Color(uiColor: .systemGroupedBackground)
            }
        }
        .ignoresSafeArea()
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading secure payment")
                .font(.headline.weight(.regular))
            Text("Confirming the merchant and amount with Inttegro.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .accessibilityElement(children: .combine)
    }

    private func failureView(_ failure: PaymentSheetFailure) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Payment unavailable")
                .font(.title3.weight(.regular))
            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await model.load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private func checkoutView(
        session: PaymentSheetSession,
        isProcessing: Bool
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    merchantSummary(session)
                    paymentMethodSection(session)
                    if let failure = model.inlineFailure {
                        inlineFailure(failure)
                    }
                    paymentConsent(session)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .id(model.selectedPaymentMethodID)
            .scrollDismissesKeyboard(.interactively)

            payButton(session, isProcessing: isProcessing)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
    }

    private func merchantSummary(_ session: PaymentSheetSession) -> some View {
        VStack(spacing: 8) {
            Text(session.merchant.displayName)
                .font(.subheadline.weight(.regular))
                .foregroundStyle(.secondary)
            Text(session.amount.formatted)
                .font(.system(.largeTitle, design: .rounded, weight: .regular))
                .contentTransition(.numericText())
            if let supportText = session.merchant.supportText {
                Text(supportText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Pay \(session.amount.formatted) to \(session.merchant.displayName)"
        )
    }

    private func paymentMethodSection(_ session: PaymentSheetSession) -> some View {
        let attachedMethod = session.paymentMethods.first { $0.source == .saved }
        let newMethod = session.paymentMethods.first { $0.source == .new }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Pay with Mobile Money")
                .font(.headline.weight(.regular))

            if let selectedMethod = model.selectedMethod,
               selectedMethod.source == .saved {
                VStack(alignment: .leading, spacing: 12) {
                    paymentMethodSummary(selectedMethod)
                    Text(
                        "Use the Mobile Money account attached to this payment, "
                            + "or change it before payment is sent."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    if let newMethod {
                        Button("Change payment method") {
                            model.selectPaymentMethod(newMethod.id)
                        }
                        .font(.subheadline.weight(.regular))
                    }
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            } else {
                if let attachedMethod {
                    Button {
                        model.selectPaymentMethod(attachedMethod.id)
                    } label: {
                        HStack(spacing: 12) {
                            Text("Use")
                                .foregroundStyle(.secondary)
                            paymentMethodSummary(attachedMethod)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
                    }
                    .accessibilityLabel("Use \(attachedMethod.label)")

                    Text("Use another Mobile Money account")
                        .font(.headline.weight(.regular))
                        .padding(.top, 2)
                }

                mobileMoneyForm
            }
        }
    }

    private func paymentMethodSummary(
        _ method: PaymentSheetSession.PaymentMethod
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: method.kind))
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(primaryColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(method.label)
                    .font(.body.weight(.regular))
                if let detail = method.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var mobileMoneyForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Account number")
                        .font(.subheadline.weight(.regular))
                    Spacer()
                    Text("10 digits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                mobileMoneyAccountField
                if let error = model.validationMessage(for: .accountNumber) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(error)")
                }
            }

            if model.networkSelectorRevealed {
                mobileMoneyNetworkSelector
            }

            Divider()

            Toggle(isOn: $model.savePaymentMethod) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Save for next time")
                        .font(.body.weight(.regular))
                    Text(
                        "Use your Mobile Money account for faster payments with "
                            + "\(model.currentSession?.merchant.displayName ?? "this merchant") next time."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if model.savePaymentMethod {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your details")
                            .font(.headline.weight(.regular))
                        Text(
                            model.paymentMethodOwnerReady
                                ? "We'll save these details with your Mobile Money account. "
                                    + "This won't change the delivery details for this order."
                                : "Add your name to save this Mobile Money account. "
                                    + "This won't change the delivery details for this order."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    labeledField(
                        "Full name",
                        text: $model.billingName,
                        field: .billingName,
                        contentType: .name,
                        error: model.validationMessage(for: .billingName)
                    )
                    labeledField(
                        "Phone number (optional)",
                        text: $model.billingPhoneNumber,
                        field: .billingPhone,
                        contentType: .telephoneNumber,
                        keyboardType: .phonePad
                    )
                    LabeledContent("Country", value: "Ghana")
                    labeledField(
                        "Street address (optional)",
                        text: $model.billingLine1,
                        field: .billingLine1,
                        contentType: .streetAddressLine1
                    )
                    labeledField(
                        "City (optional)",
                        text: $model.billingCity,
                        field: .billingCity,
                        contentType: .addressCity
                    )
                    labeledField(
                        "Region (optional)",
                        text: $model.billingRegion,
                        field: .billingRegion,
                        contentType: .addressState
                    )
                    labeledField(
                        "Postal code (optional)",
                        text: $model.billingPostCode,
                        field: .billingPostCode,
                        contentType: .postalCode
                    )
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var mobileMoneyNetworkSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Network")
                .font(.subheadline.weight(.regular))

            HStack(spacing: 8) {
                ForEach(
                    PaymentSheetMobileMoneyInput.Network.paymentSheetOptions,
                    id: \.self
                ) { network in
                    mobileMoneyNetworkOption(network)
                }
            }

            if let hint = model.networkSuggestionHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.validationMessage(for: .network) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(error)")
            }
        }
    }

    private func mobileMoneyNetworkOption(
        _ network: PaymentSheetMobileMoneyInput.Network
    ) -> some View {
        let selected = model.mobileMoneyNetwork == network
        return Button {
            model.selectMobileMoneyNetwork(network)
        } label: {
            VStack(spacing: 7) {
                Image(
                    network.paymentSheetAssetName,
                    bundle: PaymentSheetResources.bundle
                )
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 20)
                .frame(width: 32, height: 32)
                .background(Color(uiColor: .systemBackground), in: Circle())

                VStack(spacing: 1) {
                    Text(network.displayName)
                        .font(.caption.weight(.regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                    Text(network.productName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 74)
            .padding(.horizontal, 6)
            .background(
                selected
                    ? primaryColor.opacity(0.11)
                    : Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        selected ? primaryColor.opacity(0.34) : .clear,
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(network.displayName) \(network.productName)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var mobileMoneyAccountNumberBinding: Binding<String> {
        Binding(
            get: { model.mobileMoneyAccountNumber },
            set: { value in
                model.mobileMoneyAccountNumber = String(
                    value.filter(\.isNumber).prefix(10)
                )
            }
        )
    }

    private var mobileMoneyAccountField: some View {
        let digits = Array(model.mobileMoneyAccountNumber.filter(\.isNumber).prefix(10))
        let activeIndex = min(digits.count, 9)
        let isFocused = focusedField == .accountNumber

        return ZStack {
            HStack(spacing: 3) {
                ForEach(0 ..< 10, id: \.self) { index in
                    if index == 3 || index == 6 {
                        Spacer().frame(width: 3)
                    }
                    digitCell(
                        digit: index < digits.count ? String(digits[index]) : nil,
                        isActive: isFocused && index == activeIndex
                    )
                }
            }

            TextField("Account number", text: mobileMoneyAccountNumberBinding)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .focused($focusedField, equals: .accountNumber)
                .foregroundStyle(.clear)
                .tint(.clear)
                .opacity(0.02)
                .accessibilityLabel("Account number")
                .accessibilityValue(model.mobileMoneyAccountNumber)
                .accessibilityHint(
                    model.validationMessage(for: .accountNumber) ?? "10 digits"
                )
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .accountNumber }
    }

    private func digitCell(
        digit: String?,
        isActive: Bool
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(uiColor: digit == nil ? .secondarySystemGroupedBackground : .systemBackground))
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isActive ? primaryColor : Color.secondary.opacity(digit == nil ? 0.24 : 0.4),
                    lineWidth: isActive ? 2 : 1
                )
            if let digit {
                Text(digit)
                    .font(.system(.body, design: .monospaced, weight: .regular))
            } else if isActive {
                Capsule()
                    .fill(primaryColor)
                    .frame(width: 2, height: 18)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.42))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .accessibilityHidden(true)
    }

    private func labeledField(
        _ label: String,
        text: Binding<String>,
        field: InputField,
        contentType: UITextContentType? = nil,
        keyboardType: UIKeyboardType = .default,
        error: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.regular))
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .textContentType(contentType)
                .keyboardType(keyboardType)
                .focused($focusedField, equals: field)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
                .accessibilityHint(error ?? "")
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(error)")
            }
        }
    }

    private func inlineFailure(_ failure: PaymentSheetFailure) -> some View {
        Label(failure.message, systemImage: "exclamationmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityLabel("Payment error: \(failure.message)")
    }

    private func confirmationView(
        session: PaymentSheetSession,
        challenge: PaymentSheetConfirmationChallenge,
        isProcessing: Bool,
        failure: PaymentSheetFailure?
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    merchantSummary(session)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Enter your code")
                            .font(.title3.weight(.regular))
                        Text(confirmationInstructions(challenge))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if !challenge.requiresNewCode {
                            confirmationCodeField(challenge)
                            if let error = model.validationMessage(for: .confirmationToken) {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        if let failure {
                            inlineFailure(failure)
                        }
                    }
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    Text(
                        "Nothing will be charged until you approve the payment on your phone."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(20)
            }

            confirmationActions(
                challenge: challenge,
                isProcessing: isProcessing
            )
            .padding(16)
        }
        .onAppear {
            if !challenge.requiresNewCode {
                focusedField = .confirmationToken
            }
        }
    }

    private func awaitingResultView(
        session: PaymentSheetSession,
        action: PaymentSheetExternalAction?,
        isRefreshing: Bool,
        failure: PaymentSheetFailure?
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    merchantSummary(session)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        externalActionCard(action, now: context.date)
                    }
                    if let failure {
                        inlineFailure(failure)
                    }
                    Text("Powered by Inttegro")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(20)
            }

            Button {
                Task {
                    if let result = await model.refreshPayment() {
                        onResult(result)
                    }
                }
            } label: {
                HStack {
                    if isRefreshing { ProgressView() }
                    Text(isRefreshing ? "Checking" : "Check again")
                        .fontWeight(.regular)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isRefreshing)
            .padding(16)
        }
    }

    private func completedView(_ session: PaymentSheetSession) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 16)
            ZStack {
                Circle()
                    .fill(primaryColor.opacity(0.14))
                    .frame(width: 88, height: 88)
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(primaryColor)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Payment complete")
                    .font(.title2.weight(.regular))
                Text(session.amount.formatted)
                    .font(.system(.largeTitle, design: .rounded, weight: .regular))
                    .contentTransition(.numericText())
                Text("Paid to \(session.merchant.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Payment complete. Paid \(session.amount.formatted) to \(session.merchant.displayName)."
            )

            Text("Your payment was completed successfully.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            Button("Done") {
                if let result = model.completedResult {
                    onResult(result)
                }
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(primaryButtonForegroundColor)
            .buttonBorderShape(
                .roundedRectangle(
                    radius: model.configuration.appearance.cornerRadius ?? 16
                )
            )
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding(20)
    }

    @ViewBuilder
    private func externalActionCard(
        _ action: PaymentSheetExternalAction?,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch action {
            case let .redirect(url, expiresAt):
                let expired = expiresAt.map { now >= $0 } ?? false
                Label("Continue to approve", systemImage: "safari")
                    .font(.title3.weight(.regular))
                Text(
                    expired
                        ? "This approval link has expired. Check again for an update."
                        : "Complete the secure steps, then return here. "
                            + "We'll check the result automatically."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if !expired {
                    Button("Continue", systemImage: "arrow.up.right") {
                        redirectDestination = RedirectDestination(url: url)
                    }
                    .buttonStyle(.borderedProminent)
                }
            case let .authorize(scheme, expiresAt):
                Label("Check your phone", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.title3.weight(.regular))
                Text(authorizationInstructions(scheme: scheme, expiresAt: expiresAt, now: now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                waitingIndicator("Waiting for your approval")
            case nil:
                Label("Payment sent", systemImage: "clock.arrow.circlepath")
                    .font(.title3.weight(.regular))
                Text("We're checking whether your payment went through.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                waitingIndicator("Checking your payment")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func authorizationInstructions(
        scheme: String?,
        expiresAt: Date?,
        now: Date
    ) -> String {
        if let expiresAt, now >= expiresAt {
            return "The time to approve has ended. Check again for an update."
        }
        guard let provider = providerDisplayName(scheme) else {
            return "Approve the payment on your phone. We'll update this screen when you're done."
        }
        return "Open the \(provider) prompt on your phone and approve the payment. "
            + "We'll update this screen when you're done."
    }

    private func providerDisplayName(_ scheme: String?) -> String? {
        guard let scheme, !scheme.isEmpty else { return nil }
        return switch scheme.lowercased() {
        case "mtn", "mtn_mobile_money": "MTN Mobile Money"
        case "telecel", "vodafone", "telecel_cash": "Telecel Cash"
        case "airtel", "airteltigo", "airtel_tigo": "AirtelTigo Money"
        default: scheme.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func confirmationActions(
        challenge: PaymentSheetConfirmationChallenge,
        isProcessing: Bool
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let resendAt = challenge.requestAfter ?? challenge.expiresAt
            let canRequest = resendAt.map { context.date >= $0 } ?? true
            let secondsUntilRequest = resendAt.map {
                max(0, Int(ceil($0.timeIntervalSince(context.date))))
            }
            VStack(spacing: 8) {
                Button {
                    Task {
                        let result = challenge.requiresNewCode
                            ? await model.requestNewCode()
                            : await model.submitConfirmation()
                        if let result { onResult(result) }
                    }
                } label: {
                    HStack {
                        if isProcessing {
                            ProgressView().tint(primaryButtonForegroundColor)
                        }
                        Text(
                            challenge.requiresNewCode
                                ? (canRequest
                                    ? "Send new code"
                                    : "Send new code in \(secondsUntilRequest ?? 0)s")
                                : (isProcessing ? "Checking code" : "Continue")
                        )
                        .fontWeight(.regular)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(primaryButtonForegroundColor)
                .controlSize(.large)
                .disabled(
                    isProcessing || (challenge.requiresNewCode && !canRequest)
                )

                if !challenge.requiresNewCode {
                    Button(
                        canRequest
                            ? "Send a new code"
                            : "Send a new code in \(secondsUntilRequest ?? 0)s"
                    ) {
                        Task {
                            if let result = await model.requestNewCode() {
                                onResult(result)
                            }
                        }
                    }
                    .disabled(isProcessing || !canRequest)
                }
            }
        }
    }

    private func confirmationInstructions(
        _ challenge: PaymentSheetConfirmationChallenge
    ) -> String {
        if challenge.requiresNewCode {
            return "That code has expired. Ask for a new one to keep going."
        }
        let channel = confirmationChannel(challenge.sentVia)
        let recipient = challenge.recipient.map { "to \($0)" } ?? ""
        let delivery = [channel, recipient]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let deliveryPhrase = delivery.isEmpty ? "" : " \(delivery)"
        return "We sent you a \(challenge.tokenSize)-digit code\(deliveryPhrase). "
            + "Enter it below to keep going."
    }

    private func confirmationChannel(_ sentVia: String?) -> String {
        switch sentVia?.lowercased() {
        case "sms", "text", "text_message": "by text message"
        case "email": "by email"
        default: ""
        }
    }

    private func confirmationCodeField(
        _ challenge: PaymentSheetConfirmationChallenge
    ) -> some View {
        let limit = max(1, challenge.tokenSize)
        let digits = Array(model.confirmationToken.filter(\.isNumber).prefix(limit))
        let activeIndex = min(digits.count, limit - 1)
        let isFocused = focusedField == .confirmationToken

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Code")
                    .font(.subheadline.weight(.regular))
                Spacer()
                Text("\(limit) digits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                HStack(spacing: 8) {
                    ForEach(0 ..< limit, id: \.self) { index in
                        digitCell(
                            digit: index < digits.count ? String(digits[index]) : nil,
                            isActive: isFocused && index == activeIndex
                        )
                    }
                }

                TextField(
                    "Code",
                    text: confirmationTokenBinding(limit)
                )
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .confirmationToken)
                .foregroundStyle(.clear)
                .tint(.clear)
                .opacity(0.02)
                .accessibilityLabel("\(limit)-digit code")
                .accessibilityValue("\(digits.count) of \(limit) digits entered")
                .accessibilityHint(
                    model.validationMessage(for: .confirmationToken) ?? ""
                )
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .onTapGesture { focusedField = .confirmationToken }
        }
    }

    private func waitingIndicator(_ label: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func confirmationTokenBinding(_ limit: Int) -> Binding<String> {
        Binding(
            get: { model.confirmationToken },
            set: { value in
                model.confirmationToken = String(value.filter(\.isNumber).prefix(limit))
            }
        )
    }

    private func paymentConsent(_ session: PaymentSheetSession) -> some View {
        Text(
            "By confirming your payment, you allow "
                + "\(session.merchant.displayName) to request a Mobile Money payment. "
                + "You may be asked to approve it on your phone."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineSpacing(2)
        .accessibilityLabel(
            "Payment consent. By confirming your payment, you allow "
                + "\(session.merchant.displayName) to request a Mobile Money payment."
        )
    }

    private func payButton(
        _ session: PaymentSheetSession,
        isProcessing: Bool
    ) -> some View {
        Button {
            Task {
                if let result = await model.pay() {
                    onResult(result)
                }
            }
        } label: {
            HStack {
                if isProcessing {
                    ProgressView().tint(primaryButtonForegroundColor)
                }
                Text(isProcessing ? "Starting payment" : "Pay \(session.amount.formatted)")
                    .fontWeight(.regular)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(primaryButtonForegroundColor)
        .buttonBorderShape(
            .roundedRectangle(
                radius: model.configuration.appearance.cornerRadius ?? 16
            )
        )
        .controlSize(.large)
        .disabled(isProcessing || !model.canPay)
    }

    private func symbol(for kind: PaymentSheetSession.PaymentMethod.Kind) -> String {
        switch kind {
        case .zeboWallet:
            "wallet.bifold.fill"
        case .mobileMoney:
            "iphone.gen3"
        }
    }
}

private struct RedirectDestination: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context _: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_: SFSafariViewController, context _: Context) {}
}

private extension Color {
    init?(hex: String?) {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else {
            return nil
        }

        let red = Double((number >> (value.count == 8 ? 24 : 16)) & 0xFF) / 255
        let green = Double((number >> (value.count == 8 ? 16 : 8)) & 0xFF) / 255
        let blue = Double((number >> (value.count == 8 ? 8 : 0)) & 0xFF) / 255
        let alpha = value.count == 8 ? Double(number & 0xFF) / 255 : 1
        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }

    static func contrastingForeground(forHex hex: String?) -> Color? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else {
            return nil
        }

        let red = Double((number >> (value.count == 8 ? 24 : 16)) & 0xFF) / 255
        let green = Double((number >> (value.count == 8 ? 16 : 8)) & 0xFF) / 255
        let blue = Double((number >> (value.count == 8 ? 8 : 0)) & 0xFF) / 255
        let luminance = 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
        return luminance > 0.179 ? .black : .white
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

private enum PaymentSheetResources {
    #if SWIFT_PACKAGE
    static let bundle = Bundle.module
    #else
    private final class BundleToken {}

    static let bundle: Bundle = {
        let containingBundle = Bundle(for: BundleToken.self)
        for candidate in [containingBundle, .main] {
            if let resourceURL = candidate.url(
                forResource: "Inttegro",
                withExtension: "bundle"
            ), let resourceBundle = Bundle(url: resourceURL) {
                return resourceBundle
            }
        }
        return containingBundle
    }()
    #endif
}

#if DEBUG
#Preview("Payment sheet") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PaymentSheetView(
                model: PaymentSheetViewModel(
                    configuration: try! .init(
                        orderID: "or_preview",
                        appearance: .init(primaryColor: "#3956D8", cornerRadius: 16)
                    ),
                    adapter: PreviewPaymentSheetAdapter()
                ),
                onResult: { _ in }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
}
#endif
