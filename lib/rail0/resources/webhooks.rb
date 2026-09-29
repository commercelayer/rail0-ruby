# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Webhook subscription management (requires JWT).
    #
    # A subscription covers a SET of topics — one shared secret and one circuit breaker
    # for all of them — and each delivery names the event that fired in `X-Rail0-Topic`.
    # Two subscriptions for the same callback_url must not overlap: one event delivered
    # twice under two different secrets is indistinguishable from a duplicate at the
    # receiving end, so the gateway answers 409 and names the topic that collided.
    # See {TOPICS} for the accepted values.
    class Webhooks
      include Query

      # Event topics a subscription can carry. It may carry any non-empty subset.
      TOPICS = %w[
        payments.created
        payments.signed
        payments.authorized
        payments.charged
        payments.captured
        payments.voided
        payments.released
        payments.refunded
        payments.authorization_expiring
        payments.expired
        payments.failed
        payments.disputed
        payments.dispute_closed
      ].freeze

      attr_reader :http

      def initialize(http)
        @http = http
        freeze
      end

      # List the account's webhooks.
      # @param topic [String, nil] Narrow to subscriptions that INCLUDE this event
      #   (see {TOPICS}). Singular on purpose: the question is which subscriptions
      #   deliver one event, whatever else they also deliver.
      # @param active [Boolean, nil] Filter by active flag.
      # @param circuit_state [String, nil] Filter by circuit state ("closed" or "open").
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based; 1..1,000,000, 400 outside).
      # @param per_page [Integer, nil] Items per page (max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def list(topic: nil, active: nil, circuit_state: nil, sort: nil, page: nil, per_page: nil)
        query = build_query(topic: topic, active: active, circuit_state: circuit_state,
                            sort: sort, page: page, per_page: per_page)
        http.get_list("/webhooks#{query}")
      end

      # Register a new webhook. The response includes the one-time shared_secret
      # used to verify delivery signatures — it is shown only on create and rotate.
      # @param name [String] Human-readable name.
      # @param callback_url [String] HTTPS URL the gateway POSTs events to.
      # @param topics [Array<String>] One or more of {TOPICS}. Repeats are collapsed by
      #   the gateway; overlapping another subscription on the same callback_url is a 409
      #   naming the topic that collided.
      # @return [Hash] webhook record including shared_secret
      def create(name:, callback_url:, topics:)
        http.post("/webhooks", { name: name, callback_url: callback_url, topics: Array(topics) })
      end

      # Fetch a single webhook.
      # @param id [String] Webhook UUID.
      # @return [Hash]
      def get(id)
        http.get("/webhooks/#{segment(id)}")
      end

      # Update a webhook's name, callback_url, and/or topics.
      # @param id [String] Webhook UUID.
      # @param name [String, nil]
      # @param callback_url [String, nil]
      # @param topics [Array<String>, nil] REPLACES the whole set, which is also how a
      #   topic is removed: send the union to add one, the remainder to drop one. The
      #   shared secret is untouched.
      # @return [Hash]
      def update(id, name: nil, callback_url: nil, topics: nil)
        body = {}
        body[:name]         = name          unless name.nil?
        body[:callback_url] = callback_url  unless callback_url.nil?
        body[:topics]       = Array(topics) unless topics.nil?
        http.patch("/webhooks/#{segment(id)}", body)
      end

      # Re-enable a disabled webhook.
      # @param id [String] Webhook UUID.
      # @return [Hash]
      def enable(id)
        http.put("/webhooks/#{segment(id)}/enable")
      end

      # Disable a webhook (stops deliveries without deleting it).
      # @param id [String] Webhook UUID.
      # @return [Hash]
      def disable(id)
        http.put("/webhooks/#{segment(id)}/disable")
      end

      # Generate a new shared secret, returned once on the response.
      # @param id [String] Webhook UUID.
      # @return [Hash] webhook record including the new shared_secret
      def rotate_secret(id)
        http.put("/webhooks/#{segment(id)}/rotate_secret")
      end

      # Reset the delivery circuit breaker and re-enable the webhook.
      # @param id [String] Webhook UUID.
      # @return [Hash]
      def reset_circuit(id)
        http.put("/webhooks/#{segment(id)}/reset_circuit")
      end

      # List delivery attempts for a webhook.
      # @param id [String] Webhook UUID.
      # @param status [String, nil] Filter by delivery status: "delivered" or "failed" only
      #   (anything else, "pending" included, is a 400).
      # @param topic [String, nil] Filter by event topic.
      # @param payment_id [String, nil] Filter by the payment the delivery is for: its UUID
      #   or its rail0_id (0x…). One that names no payment matches nothing rather than erroring.
      # @param response_code [String, Integer, nil] Filter by the subscriber's exact HTTP
      #   response code (e.g. 500) — `status: "failed"` finds the failures, this says which.
      # @param since [String, nil] Only deliveries at/after this ISO-8601 time.
      # @param until_time [String, nil] Only deliveries at/before this ISO-8601 time (query key: "until").
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based; 1..1,000,000, 400 outside).
      # @param per_page [Integer, nil] Items per page (max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def event_callbacks(id, status: nil, topic: nil, payment_id: nil, response_code: nil,
                          since: nil, until_time: nil, sort: nil, page: nil, per_page: nil)
        query = build_query(status: status, topic: topic, payment_id: payment_id,
                            response_code: response_code, since: since, until: until_time,
                            sort: sort, page: page, per_page: per_page)
        http.get_list("/webhooks/#{segment(id)}/event_callbacks#{query}")
      end

      # Re-deliver one recorded delivery's exact payload
      # (POST /webhooks/:id/event_callbacks/:callback_id/redeliver).
      #
      # The recovery lever for events lost while the circuit breaker was open: the
      # gateway stores each delivery's payload and replays THAT payload verbatim — the
      # same embedded event id, so a receiver that already processed it deduplicates —
      # under a fresh timestamped signature.
      #
      # Delivery is ASYNC (the standard dispatcher: same SSRF checks, retries and circuit
      # accounting), and the dispatcher drops a delivery for a webhook that is not active.
      # So re-activate the webhook FIRST — {enable} if it was disabled, {reset_circuit} if
      # the breaker opened — or the 202 below is answered and the replay silently dropped.
      #
      # A callback id that is malformed, unknown, belongs to another webhook, or was
      # recorded before payloads were stored all answer 404.
      #
      # @param id [String] Webhook UUID.
      # @param callback_id [String] The event callback's UUID (from {event_callbacks}).
      # @return [Hash] `{ status: "queued" }` (HTTP 202).
      def redeliver(id, callback_id)
        http.post("/webhooks/#{segment(id)}/event_callbacks/#{segment(callback_id)}/redeliver", {})
      end

      # Delete a webhook. Returns HTTP 204.
      # @param id [String] Webhook UUID.
      # @return [nil]
      def delete(id)
        http.delete("/webhooks/#{segment(id)}")
      end
    end
  end
end
