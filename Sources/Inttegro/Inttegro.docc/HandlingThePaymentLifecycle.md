# Handle the payment lifecycle

Separate recoverable collection states, terminal client results, and
authoritative server-side payment state.

## Keep recoverable states inside the sheet

The payment state machine retrieves Checkout, validates expiration, starts an
idempotent payment attempt, and then follows the server response:

1. A confirmation challenge asks the payer for the exact numeric token size and
   observes server-controlled expiry and resend timing.
2. A secure redirect opens in a system browser surface.
3. Provider or device authorization keeps the sheet waiting while Checkout is
   polled.
4. A recoverable attempt failure returns to a usable form with safe guidance.

These states do not invoke the host completion handler. This prevents an
application from mistaking a retryable provider response for a terminal SDK
failure.

## Interpret the terminal result

``PaymentSheetResult`` has three cases:

- `completed(event)` means the native flow reached a Checkout-confirmed success
  state. `event.order` contains the client-safe Order snapshot.
- `canceled(event)` means the payer dismissed the sheet before completion.
- `failed(event)` means configuration, transport, or an unsupported state made
  the presentation unable to continue. Inspect `event.failure` for safe details.

Use the stable code in ``CheckoutFailure`` for application branching. A message
may be displayed or logged according to your product's policy, but should not
be parsed.

```swift
func handle(_ result: PaymentSheetResult) {
    switch result {
    case let .completed(event):
        Task { await verifyAndFulfillOrder(event.order!.id) }
    case .canceled:
        restoreCheckoutControls()
    case let .failed(event):
        recordTerminalFailure(code: event.failure!.code)
        showPaymentUnavailable()
    }
}
```

## Observe progress consistently

Pass an `eventHandler` to UIKit, SwiftUI, React Native, or Flutter to receive the
same ordered lifecycle. Every event has `occurredAt`, `flowID`, and a monotonic
`sequence` for one presentation. Once an Order exists, subsequent events carry
its client-safe snapshot.

| Event | Additional payload |
| --- | --- |
| `presented`, `ready` | Envelope only |
| `change` | `complete`, optional `paymentMethod` |
| `orderPrepared`, `paymentAttemptStarted`, `paymentProcessing`, `completed`, `canceled` | `order` when one exists |
| `paymentActionRequired` | `order`, sanitized `action` |
| `paymentAttemptFailed` | `order`, recoverable `failure` |
| `failed` | terminal `failure`, plus `order` when one exists |

Lifecycle events remain available when diagnostic telemetry is disabled. Use
telemetry for transport and observability data, not to infer payment state.

## Reconcile on the backend

Client completion is not fulfillment authority. Send the Order ID to your
backend, retrieve the owner-scoped Order using server credentials, verify the
expected amount and successful payment state, and make fulfillment idempotent.
Webhooks may update the same backend state for delayed methods; the application
should render that server-owned result rather than trying to resolve competing
client and webhook timelines itself.
