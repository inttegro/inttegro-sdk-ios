# ``InttegroBridge``

Connect a cross-platform framework adapter to Inttegro's native iOS payment UI.

## Overview

This module is intended for framework authors and Inttegro's official React
Native and Flutter packages. Native Swift applications should import `Inttegro`
and use `PaymentSheet` or `InttegroPaymentSheet` directly.

The bridge keeps one validated configuration and active presentation per
framework engine, crosses only versioned configuration, terminal results, and
privacy-safe telemetry, and leaves payer collection inside native code.

## Topics

### Framework integration

- <doc:IntegratingFrameworkAdapters>
- ``PaymentSheetCoordinator``
