# Present Checkout consistently

Understand what the native sheet owns, what the application may configure, and
how the experience expands as the payer moves through payment.

## Preserve the Checkout experience

The native sheet follows the same information hierarchy and language as hosted
invoice payment. It uses platform presentation rather than inventing a separate
mobile checkout: a system sheet on compact iOS devices, native controls,
accessible segmented number entry, and native browser surfaces for secure
provider redirects.

The host may supply restrained values through
``PaymentSheetConfiguration/Appearance``. Omitted colors inherit the application
and platform environment. Inttegro retains control of validation, state
transitions, payment-method semantics, accessibility labels, and security copy.

## Choose optional content

``PaymentSheetConfiguration/Features`` keeps the current behavior as its
default:

- Line items are unavailable unless `showLineItems` is enabled. When enabled,
  the Order summary starts collapsed and the payer decides whether to open it.
- Invoice and receipt actions are hidden unless explicitly enabled and Checkout
  returns the corresponding secure URL after completion.
- Replacing an attached payment method is allowed by default.

Disabling payment-method changes does not strand an Order that has no attached
method. In that case, the sheet still collects a supported method.

## Handle changing sheet height

The flow begins with merchant, amount, payment-method selection, and—when
enabled—a collapsed Order summary. Opening that summary promotes the system
sheet to its large detent as it reveals the line items. The sheet also expands
when the payer enters a new Mobile Money number, supplies personal and billing
details for a saved method, enters a confirmation code, or waits for provider
authorization. Let the system sheet manage its detents and keyboard avoidance;
do not place the payment content inside another independently scrolling modal.

Interactive dismissal is disabled while an authorization mutation is in
flight. When dismissal is permitted, a downward gesture is reported as
``PaymentSheetResult/canceled``.

## Return from another application

Set an application-owned absolute URL in
``PaymentSheetConfiguration/returnURL`` when a payment provider may hand control
back to your app. Register the URL with iOS and route it to the screen that owns
the active payment presentation. The SDK continues polling Checkout and reports
completion only after the server confirms it.
