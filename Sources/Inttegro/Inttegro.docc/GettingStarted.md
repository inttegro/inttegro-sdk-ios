# Get started with Checkout

Create a finalized Order on your backend, hand its public ID to iOS, and present
Inttegro's native payment sheet.

## Before you begin

Your backend owns merchant authentication and Order creation. Never return an
Inttegro API key to the application. The value passed to
``PaymentSheetConfiguration/init(orderID:returnURL:appearance:telemetry:features:)``
is the public Order ID for Checkout, not a merchant credential.

Add the Inttegro package to your application, link the `Inttegro` product, and
import the module:

```swift
import Inttegro
```

## Create configuration

Construct configuration as close as practical to presentation. The initializer
rejects empty Order IDs, malformed return URLs, invalid color values, unsupported
corner radii, and malformed W3C trace context before UI appears.

```swift
let configuration = try PaymentSheetConfiguration(
    orderID: checkout.orderID,
    returnURL: URL(string: "merchant-app://inttegro-return"),
    appearance: .init(primaryColor: "#0C4A3E"),
    features: .init(
        showLineItems: true,
        showInvoiceDownload: true,
        showReceiptDownload: true
    )
)
```

Feature options affect presentation only. Amount, currency, merchant identity,
line-item totals, saved payment methods, and shipping details remain controlled
by Checkout.

## Present from SwiftUI

Keep presentation state in the host view and handle the terminal result once.

```swift
struct CheckoutButton: View {
    @State private var isPresentingPayment = false
    let configuration: PaymentSheetConfiguration

    var body: some View {
        Button("Pay") {
            isPresentingPayment = true
        }
        .inttegroPaymentSheet(
            isPresented: $isPresentingPayment,
            configuration: configuration
        ) { result in
            handle(result)
        }
    }
}
```

## Present from UIKit

Keep the sheet alive until its completion callback runs:

```swift
let sheet = PaymentSheet(configuration: configuration)
self.paymentSheet = sheet

sheet.present(from: self) { [weak self] result in
    self?.paymentSheet = nil
    self?.handle(result)
}
```

Recoverable failures, confirmation codes, and provider authorization remain
inside the native sheet. The callback runs only for completion, customer
cancellation, or a terminal SDK failure.

## Verify before fulfillment

When the result is `.completed`, send the Order ID to your backend and retrieve
the owner-scoped Order with server credentials. Fulfill only when that
authoritative resource reports the expected successful payment state. This
protects fulfillment from a modified application, stale callback, or replayed
client result.
