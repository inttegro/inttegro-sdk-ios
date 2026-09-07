import Foundation
import Testing
@testable import Inttegro

@Suite("Payment sheet telemetry")
struct PaymentSheetTelemetryTests {
    private let traceParent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

    @Test("Emits ordered privacy-safe events and trace context")
    func emitsEventsAndTraceContext() throws {
        let events = TelemetryEventStore()
        let configuration = PaymentSheetConfiguration.Telemetry(
            traceParent: traceParent,
            traceState: "vendor=value"
        )
        let telemetry = PaymentSheetTelemetry(
            configuration: configuration,
            flowID: "550e8400-e29b-41d4-a716-446655440000",
            eventHandler: events.append
        )

        telemetry.emit(.requestPrepared, operation: "checkout.lookup")
        telemetry.emit(
            .responseReceived,
            operation: "checkout.lookup",
            httpStatusCode: 200,
            requestID: "req_test"
        )

        let emitted = events.snapshot()
        #expect(emitted.map(\.sequence) == [1, 2])
        #expect(emitted.allSatisfy { $0.flowID == "550e8400-e29b-41d4-a716-446655440000" })
        #expect(emitted.map(\.name) == [.requestPrepared, .responseReceived])

        let payload = emitted[1].bridgePayload
        #expect(Set(payload.keys) == [
            "flowId",
            "sequence",
            "name",
            "timestamp",
            "operation",
            "httpStatusCode",
            "requestId",
        ])
        #expect(payload["orderId"] == nil)
        #expect(payload["paymentId"] == nil)
        let timestamp = try #require(payload["timestamp"] as? String)
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(timestampFormatter.date(from: timestamp) != nil)

        var request = URLRequest(url: URL(string: "https://api.inttegro.com/checkout/lookup")!)
        telemetry.applyTraceContext(to: &request)
        #expect(request.value(forHTTPHeaderField: "traceparent") == traceParent)
        #expect(request.value(forHTTPHeaderField: "tracestate") == "vendor=value")
    }

    @Test("Drops unbounded server request identifiers")
    func dropsUnboundedRequestIdentifiers() {
        let events = TelemetryEventStore()
        let telemetry = PaymentSheetTelemetry(
            configuration: .init(),
            flowID: "550e8400-e29b-41d4-a716-446655440000",
            eventHandler: events.append
        )

        telemetry.emit(.responseReceived, requestID: String(repeating: "x", count: 256))

        #expect(events.snapshot().single?.requestID == nil)
    }

    @Test("Can disable events and trace propagation together")
    func disablesEventsAndTracePropagation() {
        let events = TelemetryEventStore()
        let telemetry = PaymentSheetTelemetry(
            configuration: .init(enabled: false, traceParent: traceParent),
            eventHandler: events.append
        )
        var request = URLRequest(url: URL(string: "https://api.inttegro.com/checkout/lookup")!)

        telemetry.emit(.sheetPresented)
        telemetry.applyTraceContext(to: &request)

        #expect(events.snapshot().isEmpty)
        #expect(request.value(forHTTPHeaderField: "traceparent") == nil)
    }

    @Test("Rejects zero and reserved W3C trace identifiers")
    func rejectsInvalidTraceIdentifiers() {
        #expect(throws: PaymentSheetError.self) {
            try PaymentSheetConfiguration(
                orderID: "or_test",
                telemetry: .init(
                    traceParent: "00-00000000000000000000000000000000-00f067aa0ba902b7-01"
                )
            )
        }
        #expect(throws: PaymentSheetError.self) {
            try PaymentSheetConfiguration(
                orderID: "or_test",
                telemetry: .init(
                    traceParent: "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
                )
            )
        }
    }
}

private final class TelemetryEventStore: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PaymentSheetTelemetryEvent] = []

    func append(_ event: PaymentSheetTelemetryEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [PaymentSheetTelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}
