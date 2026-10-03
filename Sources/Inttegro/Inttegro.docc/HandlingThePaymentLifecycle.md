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

- `completed` means the native flow reached a Checkout-confirmed success state.
- `canceled` means the payer dismissed the sheet before completion.
- `failed` means configuration, transport, or an unsupported state made the
  presentation unable to continue.

Use the stable code in ``PaymentSheetFailure`` for application branching. A
message may be displayed or logged according to your product's policy, but
should not be parsed.

```swift
func handle(_ result: PaymentSheetResult) {
    switch result {
    case .completed:
        Task { await verifyAndFulfillOrder() }
    case .canceled:
        restoreCheckoutControls()
    case let .failed(failure):
        recordTerminalFailure(code: failure.code)
        showPaymentUnavailable()
    }
}
```

## Reconcile on the backend

Client completion is not fulfillment authority. Send the Order ID to your
backend, retrieve the owner-scoped Order using server credentials, verify the
expected amount and successful payment state, and make fulfillment idempotent.
Webhooks may update the same backend state for delayed methods; the application
should render that server-owned result rather than trying to resolve competing
client and webhook timelines itself.
