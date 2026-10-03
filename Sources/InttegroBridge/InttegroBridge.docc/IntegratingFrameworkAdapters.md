# Integrate a framework adapter

Delegate React Native and Flutter presentation to the native SDK instead of
reimplementing payment behavior in JavaScript or Dart.

## Use the bridge boundary

``PaymentSheetCoordinator`` is the Objective-C-compatible boundary used by
Inttegro's official framework packages. One coordinator belongs to one framework
module or engine instance. It owns validated configuration and the active sheet,
which prevents state from leaking across multiple React Native bridges or
Flutter engines in the same process.

The bridge accepts a versioned dictionary containing the public Order ID,
optional return URL, restrained appearance values, telemetry context, and
presentation features. It rejects unsupported wallet configuration and never
accepts merchant credentials or client-authored commercial terms.

## Preserve native ownership

A framework adapter should do only four things:

1. Validate and normalize the framework's typed public input.
2. Forward configuration to the coordinator.
3. present from the framework's current native view controller.
4. Decode the single terminal result and ordered telemetry payloads.

Payment UI, network requests, confirmation, provider authorization,
accessibility, dismissal rules, and retry semantics remain native. This keeps
the experience consistent between UIKit, SwiftUI, React Native, and Flutter and
prevents framework runtimes from receiving payer collection data unnecessarily.

Native Swift applications should use `PaymentSheet` or
`InttegroPaymentSheet` from the `Inttegro` product directly rather than calling
the bridge.
