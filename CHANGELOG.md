# Changelog

## 0.3.0 - 2026-10-03

- Retry a transient Checkout mutation once after the server-directed delay while
  retaining the original idempotency key.
- Include bounded request IDs and retry delays in native failures and telemetry.
- Let customers choose and revise amounts for `customer_selected_amount` prices,
  including the affected item in mixed-price Orders.
- Keep fixed-price items locked while exposing an accessible, compact amount-change
  affordance for editable line items.
- Refine the native payment sheet's entry, confirmation, authorization, and
  completion states on iOS and Android.
- Split native framework bridges from the focused iOS and Android payment modules.

## 0.2.0 - 2026-09-10

- Add the native iOS and Android payment sheet, Checkout transport, lifecycle
  telemetry, optional line items, and post-payment document actions.
