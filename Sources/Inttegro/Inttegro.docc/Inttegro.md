# ``Inttegro``

Collect payment with a native iOS experience backed by Inttegro Checkout.

## Overview

The Inttegro SDK presents the same payment journey used by hosted Checkout,
adapted to system sheets, Dynamic Type, VoiceOver, keyboard behavior, and the
interaction conventions of iPhone and iPad. Checkout supplies merchant identity,
amount, payment-method choices, and optional line items; the application supplies
only a public finalized Order ID and presentation preferences.

Use ``PaymentSheet`` from UIKit or ``InttegroPaymentSheet`` from SwiftUI. Both
entry points share the same state machine, public Checkout transport, result
contract, and privacy-safe telemetry stream.

> Important: Never place an Inttegro merchant API key in an iOS application.
> A completed sheet is client experience state, not permission to fulfill an
> Order. Retrieve the owner-scoped Order from your backend before fulfillment.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:PresentingCheckout>
- <doc:HandlingThePaymentLifecycle>

### Presentation

- ``PaymentSheet``
- ``InttegroPaymentSheet``
- ``PaymentSheetConfiguration``
- ``PaymentSheetResult``
- ``PaymentSheetFailure``

### Checkout and payment collection

- ``CheckoutPaymentSheetAdapter``
- ``PaymentSheetAdapter``
- ``PaymentSheetSession``
- ``PaymentSheetMobileMoneyInput``
- ``PaymentSheetPaymentSelection``
- ``PaymentSheetPaymentOutcome``
- ``PaymentSheetConfirmationChallenge``
- ``PaymentSheetExternalAction``
- ``PaymentSheetError``

### Observability

- <doc:ObservingPaymentTelemetry>
- ``PaymentSheetTelemetry``
- ``PaymentSheetTelemetryEvent``
