# Observe payment telemetry

Connect Inttegro's privacy-safe event stream to diagnostics owned by the host
application.

## Install a handler

Create a sheet with a telemetry callback or pass one to the SwiftUI entry point:

```swift
let sheet = PaymentSheet(
    configuration: configuration,
    telemetryEventHandler: { event in
        diagnostics.record(
            name: event.name.rawValue,
            flowID: event.flowID,
            sequence: event.sequence,
            operation: event.operation,
            statusCode: event.httpStatusCode,
            requestID: event.requestID,
            retryAfterSeconds: event.retryAfterSeconds,
            errorType: event.errorType
        )
    }
)
```

Events cover presentation, Checkout retrieval, payment attempts, confirmation,
authorization waits, polling, terminal sheet state, and public Checkout network
operations. `sequence` is monotonic within `flowID`, which lets a host reconstruct
ordering even when its exporter batches work.

For an idempotent Checkout mutation that receives `503` with a valid
`Retry-After` header, the adapter waits and retries once with the original
idempotency key. ``PaymentSheetTelemetryEvent/retryAfterSeconds`` records the
bounded delay. A terminal ``PaymentSheetFailure`` preserves the request ID and
retry delay when they are available.

## Propagate trace context

Supply a valid W3C `traceparent` and optional `tracestate` through
``PaymentSheetConfiguration/Telemetry``. The native Checkout adapter forwards
them on public Checkout requests while telemetry is enabled. Inttegro does not
create an OpenTelemetry provider or choose an exporter for the application.

## Keep event data low sensitivity

The stream excludes Order and Payment IDs, customer and payer data,
payment-method details, billing and shipping addresses, request and response
bodies, redirect URLs, and raw error messages. Preserve this boundary when
mapping events into another system. Use `flowID` and `requestID` for targeted
correlation rather than high-cardinality metric labels.

Set `enabled` to `false` when the application must disable both event emission
and trace-header propagation for a presentation.
