import Foundation
import Testing
@testable import Inttegro

@Suite("Checkout payment sheet adapter")
struct CheckoutPaymentSheetAdapterTests {
    @Test("Maps the public checkout without retaining customer details")
    func mapsLookupResponse() async throws {
        let transport = StubTransport(responses: [
            "/checkout/lookup": """
            {
              "order": {
                "id": "or_test",
                "status": "requires_payment",
                "expires_at": "2030-01-02T03:04:05Z",
                "customer": {
                  "id": "cus_private",
                  "name": "Private Customer",
                  "email_address": "private@example.com"
                },
                "payment": {
                  "id": "py_test",
                  "status": "initiated",
                  "amount": {"value": 12500, "currency": "ghs"},
                  "payment_method": {
                    "id": "pm_test",
                    "type": "mobile_money",
                    "mobile_money": {
                      "network": "mtn",
                      "account_number": "****0042",
                      "last4": "0042"
                    }
                  }
                },
                "invoice": {
                  "beneficiary": {
                    "name": "Field & Form",
                    "invoice_support_line": "Questions? Contact the merchant."
                  }
                }
              }
            }
            """,
        ])
        let adapter = makeAdapter(transport)

        let session = try await adapter.retrieveCheckout(orderID: "or_test")

        #expect(session.id == "or_test")
        #expect(session.merchant.displayName == "Field & Form")
        #expect(session.amount == .init(value: 12_500, currency: "GHS"))
        #expect(session.paymentMethods == [
            .init(
                id: "pm_test",
                kind: .mobileMoney,
                label: "MTN Mobile Money",
                detail: "Account ending in 0042"
            ),
        ])
        let request = try #require(await transport.request(for: "/checkout/lookup"))
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["order_id": "or_test"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Maps line items and document links from Checkout")
    func mapsOptionalCheckoutContent() async throws {
        let transport = StubTransport(responses: [
            "/checkout/lookup": """
            {
              "order": {
                "id": "or_test",
                "status": "requires_payment",
                "expires_at": "2030-01-02T03:04:05Z",
                "line_item_group": {
                  "line_items": [
                    {
                      "type": "product",
                      "product": {
                        "id": "li_product",
                        "name": "Woven basket",
                        "price": {"value": 5000, "currency": "GHS"},
                        "quantity": 2
                      }
                    },
                    {
                      "type": "shipping",
                      "shipping": {
                        "id": "li_shipping",
                        "label": "Delivery",
                        "fee": {"value": 2500, "currency": "GHS"}
                      }
                    }
                  ],
                  "total": {"value": 12500, "currency": "GHS"}
                },
                "payment": {
                  "status": "initiated",
                  "amount": {"value": 12500, "currency": "GHS"},
                  "payment_method_types": ["mobile_money"]
                },
                "invoice": {
                  "format": {
                    "pdf": {"url": "https://pages.inttegro.com/invoices/or_test/pdf"}
                  },
                  "beneficiary": {"name": "Field & Form"}
                }
              }
            }
            """,
        ])

        let session = try await makeAdapter(transport).retrieveCheckout(orderID: "or_test")

        #expect(session.lineItems == [
            .init(
                id: "li_product",
                name: "Woven basket",
                quantity: 2,
                total: .init(value: 10_000, currency: "GHS")
            ),
            .init(
                id: "li_shipping",
                name: "Delivery",
                total: .init(value: 2_500, currency: "GHS")
            ),
        ])
        #expect(
            session.documents.invoiceURL?.absoluteString
                == "https://pages.inttegro.com/invoices/or_test/pdf"
        )
        #expect(session.documents.receiptURL == nil)
    }

    @Test("Returns paid document links with the completion outcome")
    func mapsCompletionDocuments() async throws {
        let transport = StubTransport(responses: [
            "/checkout/pay": """
            {
              "order": {
                "id": "or_test",
                "status": "paid",
                "payment": {
                  "id": "py_test",
                  "status": "paid",
                  "receipt": {
                    "format": {
                      "pdf": {"url": "https://pages.inttegro.com/invoices/or_test/receipt"}
                    }
                  }
                },
                "invoice": {
                  "format": {
                    "pdf": {"url": "https://pages.inttegro.com/invoices/or_test/pdf"}
                  }
                }
              }
            }
            """,
        ])
        let method = PaymentSheetSession.PaymentMethod(
            id: "pm_test",
            kind: .mobileMoney,
            label: "MTN Mobile Money"
        )
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [method],
            expiresAt: .distantFuture
        )

        let outcome = try await makeAdapter(transport).pay(
            session: session,
            selection: .saved(method)
        )

        #expect(outcome == .completed(
            paymentID: "py_test",
            documents: .init(
                invoiceURL: URL(string: "https://pages.inttegro.com/invoices/or_test/pdf"),
                receiptURL: URL(string: "https://pages.inttegro.com/invoices/or_test/receipt")
            )
        ))
    }

    @Test("Rejects attached card methods until card payments are supported")
    func rejectsAttachedCardMethod() async throws {
        let transport = StubTransport(responses: [
            "/checkout/lookup": """
            {
              "order": {
                "id": "or_test",
                "status": "requires_payment",
                "expires_at": "2030-01-02T03:04:05Z",
                "payment": {
                  "id": "py_test",
                  "status": "initiated",
                  "amount": {"value": 12500, "currency": "GHS"},
                  "payment_method_types": ["mobile_money"],
                  "payment_method": {
                    "id": "pm_card",
                    "type": "card",
                    "card": {"brand": "visa"}
                  }
                },
                "invoice": {"beneficiary": {"name": "Field & Form"}}
              }
            }
            """,
        ])

        do {
            _ = try await makeAdapter(transport).retrieveCheckout(orderID: "or_test")
            Issue.record("Expected the attached card method to be rejected")
        } catch let error as PaymentSheetError {
            #expect(error.code == "unsupported_payment_method")
        }
    }

    @Test("Pays with the attached method and an idempotency key")
    func paysAttachedMethod() async throws {
        let transport = StubTransport(responses: [
            "/checkout/pay": """
            {
              "order": {
                "id": "or_test",
                "status": "paid",
                "customer": {"id": "cus_private", "name": "Private Customer"},
                "payment": {
                  "id": "py_test",
                  "status": "paid",
                  "amount": {"value": 12500, "currency": "GHS"}
                }
              }
            }
            """,
        ])
        let adapter = makeAdapter(transport)
        let method = PaymentSheetSession.PaymentMethod(
            id: "pm_test",
            kind: .mobileMoney,
            label: "MTN Mobile Money"
        )
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [method],
            expiresAt: .distantFuture
        )

        let outcome = try await adapter.pay(
            session: session,
            selection: .saved(method)
        )
        _ = try await adapter.pay(
            session: session,
            selection: .saved(method)
        )

        #expect(outcome == .completed(paymentID: "py_test"))
        let request = try #require(await transport.request(for: "/checkout/pay"))
        let key = try #require(request.value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(UUID(uuidString: key) != nil)
        #expect(await transport.idempotencyKeys(for: "/checkout/pay") == [key, key])
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == [
            "order_id": "or_test",
            "payment_method_id": "pm_test",
        ])
    }

    @Test("Returns a native confirmation challenge")
    func returnsConfirmationChallenge() async throws {
        let transport = StubTransport(responses: [
            "/checkout/pay": """
            {
              "order": {
                "id": "or_test",
                "status": "requires_payment",
                "customer": {"id": "cus_private", "name": "Private Customer"},
                "payment": {
                  "id": "py_test",
                  "status": "requires_action",
                  "amount": {"value": 12500, "currency": "GHS"},
                  "next_action": {
                    "type": "confirm_payment",
                    "confirm_payment": {
                      "expires_at": "2030-01-02T03:04:05Z",
                      "request": {
                        "id": "sc_test",
                        "recipient": "+233244000042",
                        "sent_via": "sms",
                        "token_size": 6
                      }
                    }
                  }
                }
              }
            }
            """,
        ])
        let adapter = makeAdapter(transport)
        let method = PaymentSheetSession.PaymentMethod(
            id: "pm_test",
            kind: .mobileMoney,
            label: "MTN Mobile Money"
        )
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [method],
            expiresAt: .distantFuture
        )

        let outcome = try await adapter.pay(session: session, selection: .saved(method))

        guard case let .requiresConfirmation(challenge) = outcome else {
            Issue.record("Expected a confirmation challenge")
            return
        }
        #expect(challenge.paymentID == "py_test")
        #expect(challenge.confirmationID == "sc_test")
        #expect(challenge.recipient == "••• ••• 0042")
        #expect(challenge.sentVia == "sms")
        #expect(challenge.tokenSize == 6)
    }

    @Test("Explains when no supported payment method is available")
    func requiresAttachedMethod() async throws {
        let transport = StubTransport(responses: [
            "/checkout/lookup": """
            {
              "order": {
                "id": "or_test",
                "status": "requires_payment",
                "customer": {"id": "cus_private", "name": "Private Customer"},
                "payment": {
                  "id": "py_test",
                  "status": "initiated",
                  "amount": {"value": 12500, "currency": "GHS"}
                }
              }
            }
            """,
        ])
        let adapter = makeAdapter(transport)

        do {
            _ = try await adapter.retrieveCheckout(orderID: "or_test")
            Issue.record("Expected an attached payment method to be required")
        } catch let error as PaymentSheetError {
            #expect(error.code == "payment_method_required")
        }
    }

    @Test("Maps a new mobile money option without an attached method")
    func mapsNewMobileMoneyOption() async throws {
        let transport = StubTransport(responses: [
            "/checkout/lookup": """
            {
              "order": {
                "id": "or_test",
                "status": "requires_payment",
                "payment": {
                  "id": "py_test",
                  "status": "initiated",
                  "amount": {"value": 12500, "currency": "GHS"},
                  "payment_method_types": ["mobile_money"]
                }
              }
            }
            """,
        ])

        let session = try await makeAdapter(transport).retrieveCheckout(orderID: "or_test")

        #expect(session.paymentMethods.count == 1)
        #expect(session.paymentMethods[0].source == .new)
        #expect(session.paymentMethods[0].kind == .mobileMoney)
    }

    @Test("Saves a new mobile money method with owner details")
    func paysWithNewMobileMoney() async throws {
        let transport = StubTransport(responses: [
            "/checkout/pay": """
            {
              "order": {
                "id": "or_test",
                "status": "paid",
                "customer": {"id": "cus_private", "name": "Private Customer"},
                "payment": {
                  "id": "py_test",
                  "status": "paid",
                  "amount": {"value": 12500, "currency": "GHS"}
                }
              }
            }
            """,
        ])
        let adapter = makeAdapter(transport)
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [],
            expiresAt: .distantFuture
        )
        let input = PaymentSheetMobileMoneyInput(
            network: .mtn,
            accountNumber: "+233244000042",
            billingDetails: .init(
                name: "A Payer",
                phoneNumber: "+353850000042",
                address: .init(line1: "1 Main Street", city: "Dublin", country: "IE")
            ),
            savePaymentMethod: true
        )

        let outcome = try await adapter.pay(session: session, selection: .mobileMoney(input))

        #expect(outcome == .completed(paymentID: "py_test"))
        let request = try #require(await transport.request(for: "/checkout/pay"))
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["order_id"] as? String == "or_test")
        #expect(json["save_payment_method"] as? Bool == true)
        let method = try #require(json["payment_method_data"] as? [String: Any])
        #expect(method["type"] as? String == "mobile_money")
        let mobileMoney = try #require(method["mobile_money"] as? [String: Any])
        #expect(mobileMoney["network"] as? String == "mtn")
        #expect(mobileMoney["account_number"] as? String == "+233244000042")
        let billing = try #require(method["billing_details"] as? [String: Any])
        #expect(billing["name"] as? String == "A Payer")
        let address = try #require(billing["address"] as? [String: Any])
        #expect(address["country"] as? String == "IE")
        #expect(json["shipping"] == nil)
    }

    @Test("Requests a new confirmation code")
    func requestsNewConfirmationCode() async throws {
        let transport = StubTransport(responses: [
            "/checkout/request_confirmation": """
            {
              "order": {
                "id": "or_test",
                "status": "requires_payment",
                "payment": {
                  "id": "py_test",
                  "status": "requires_action",
                  "next_action": {
                    "type": "confirm_payment",
                    "confirm_payment": {
                      "expires_at": "2030-01-02T03:04:05Z",
                      "request": {
                        "id": "sc_test",
                        "recipient": "****0042",
                        "sent_via": "sms",
                        "token_size": 6
                      }
                    }
                  }
                }
              }
            }
            """,
        ])
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [],
            expiresAt: .distantFuture
        )

        let outcome = try await makeAdapter(transport).requestConfirmation(
            session: session,
            challenge: .init(confirmationID: "sc_previous", requiresNewCode: true)
        )

        guard case let .requiresConfirmation(challenge) = outcome else {
            Issue.record("Expected a confirmation challenge")
            return
        }
        #expect(challenge.confirmationID == "sc_test")
        let request = try #require(
            await transport.request(for: "/checkout/request_confirmation")
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["order_id": "or_test"])
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") != nil)
    }

    @Test("Confirms a payment with the challenge identifiers")
    func confirmsPaymentToken() async throws {
        let transport = StubTransport(responses: [
            "/checkout/confirm_payment": """
            {
              "order": {
                "id": "or_test",
                "status": "paid",
                "customer": {"id": "cus_private", "name": "Private Customer"},
                "payment": {"id": "py_test", "status": "paid"}
              }
            }
            """,
        ])
        let adapter = makeAdapter(transport)
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [],
            expiresAt: .distantFuture
        )
        let challenge = PaymentSheetConfirmationChallenge(
            paymentID: "py_test",
            confirmationID: "sc_test"
        )

        let outcome = try await adapter.confirmPayment(
            session: session,
            challenge: challenge,
            token: "123456"
        )

        #expect(outcome == .completed(paymentID: "py_test"))
        let request = try #require(await transport.request(for: "/checkout/confirm_payment"))
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == [
            "order_id": "or_test",
            "payment_id": "py_test",
            "confirmation_id": "sc_test",
            "token": "123456",
        ])
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") != nil)
    }

    @Test("Returns a secure provider redirect without retaining its beneficiary")
    func returnsProviderRedirect() async throws {
        let transport = StubTransport(responses: [
            "/checkout/pay": """
            {
              "order": {
                "id": "or_test",
                "status": "requires_payment",
                "payment": {
                  "id": "py_test",
                  "status": "requires_action",
                  "next_action": {
                    "type": "redirect",
                    "redirect": {
                      "redirect_url": "https://pay.example.test/authorize",
                      "valid_until": "2030-01-02T03:04:05Z",
                      "latest_visit": {"ip_address": "192.0.2.42"}
                    }
                  }
                }
              }
            }
            """,
        ])
        let method = PaymentSheetSession.PaymentMethod(
            id: "pm_test",
            kind: .mobileMoney,
            label: "MTN Mobile Money"
        )
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [method],
            expiresAt: .distantFuture
        )

        let outcome = try await makeAdapter(transport).pay(
            session: session,
            selection: .saved(method)
        )

        guard case let .pending(.redirect(url, expiresAt)) = outcome else {
            Issue.record("Expected a provider redirect")
            return
        }
        #expect(url.absoluteString == "https://pay.example.test/authorize")
        #expect(expiresAt == ISO8601DateFormatter().date(from: "2030-01-02T03:04:05Z"))
    }

    @Test("Returns provider authorization without exposing its beneficiary")
    func returnsProviderAuthorization() async throws {
        let transport = StubTransport(responses: [
            "/checkout/lookup": """
            {
              "order": {
                "id": "or_test",
                "status": "requires_payment",
                "payment": {
                  "id": "py_test",
                  "status": "requires_action",
                  "next_action": {
                    "type": "authorize_payment",
                    "authorize": {
                      "scheme": "mobile_money",
                      "expires_at": "2030-01-02T03:04:05Z",
                      "beneficiary": "Private provider reference"
                    }
                  }
                }
              }
            }
            """,
        ])
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [],
            expiresAt: .distantFuture
        )

        let outcome = try await makeAdapter(transport).refreshPayment(session: session)

        guard case let .pending(.authorize(scheme, expiresAt)) = outcome else {
            Issue.record("Expected provider authorization")
            return
        }
        #expect(scheme == "mobile_money")
        #expect(expiresAt == ISO8601DateFormatter().date(from: "2030-01-02T03:04:05Z"))
        let request = try #require(await transport.request(for: "/checkout/lookup"))
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
    }

    @Test("Rejects a non-HTTPS provider redirect")
    func rejectsInsecureProviderRedirect() async throws {
        let transport = StubTransport(responses: [
            "/checkout/lookup": """
            {
              "order": {
                "id": "or_test",
                "status": "requires_payment",
                "payment": {
                  "id": "py_test",
                  "status": "requires_action",
                  "next_action": {
                    "type": "redirect",
                    "redirect": {"redirect_url": "http://pay.example.test/authorize"}
                  }
                }
              }
            }
            """,
        ])
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [],
            expiresAt: .distantFuture
        )

        do {
            _ = try await makeAdapter(transport).refreshPayment(session: session)
            Issue.record("Expected the provider redirect to be rejected")
        } catch let error as PaymentSheetError {
            #expect(error.code == "invalid_redirect_url")
        }
    }

    @Test("Refreshes a paid checkout without an idempotency key")
    func refreshesPaidCheckout() async throws {
        let transport = StubTransport(responses: [
            "/checkout/lookup": """
            {
              "order": {
                "id": "or_test",
                "status": "paid",
                "payment": {"id": "py_test", "status": "paid"}
              }
            }
            """,
        ])
        let session = PaymentSheetSession(
            id: "or_test",
            merchant: .init(displayName: "Field & Form"),
            amount: .init(value: 12_500, currency: "GHS"),
            paymentMethods: [],
            expiresAt: .distantFuture
        )

        let outcome = try await makeAdapter(transport).refreshPayment(session: session)

        #expect(outcome == .completed(paymentID: "py_test"))
        let request = try #require(await transport.request(for: "/checkout/lookup"))
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
    }

    private func makeAdapter(_ transport: StubTransport) -> CheckoutPaymentSheetAdapter {
        CheckoutPaymentSheetAdapter(
            baseURL: URL(string: "https://example.test")!,
            executeRequest: { request in
                try await transport.execute(request)
            }
        )
    }
}

private actor StubTransport {
    private let responses: [String: Data]
    private var requests: [String: URLRequest] = [:]
    private var keys: [String: [String]] = [:]

    init(responses: [String: String]) {
        self.responses = responses.mapValues { Data($0.utf8) }
    }

    func execute(_ request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        requests[path] = request
        if let key = request.value(forHTTPHeaderField: "Idempotency-Key") {
            keys[path, default: []].append(key)
        }
        guard let data = responses[path], let url = request.url else {
            throw URLError(.badServerResponse)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    func request(for path: String) -> URLRequest? {
        requests[path]
    }

    func idempotencyKeys(for path: String) -> [String] {
        keys[path, default: []]
    }
}
