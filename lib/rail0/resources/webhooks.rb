# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Webhook subscription management (requires JWT). A webhook subscribes to
    # exactly one topic; see {TOPICS} for the accepted values.
    class Webhooks
      include Query

      # Event topics a webhook can subscribe to. A webhook subscribes to one.
      TOPICS = %w[
        payments.created
        payments.signed
        payments.authorized
        payments.charged
        payments.captured
        payments.voided
        payments.released
        payments.refunded
        payments.failed
        payments.disputed
        payments.dispute_closed
      ].freeze

      def initialize(http)
        @http = http
      end

      # List the account's webhooks.
      # @param topic [String, nil] Filter by topic (see {TOPICS}).
      # @param active [Boolean, nil] Filter by active flag.
      # @param circuit_state [String, nil] Filter by circuit state ("closed" or "open").
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def list(topic: nil, active: nil, circuit_state: nil, sort: nil, page: nil, per_page: nil)
        query = build_query(topic: topic, active: active, circuit_state: circuit_state,
                            sort: sort, page: page, per_page: per_page)
        @http.get_list("/webhooks#{query}")
      end

      # Register a new webhook. The response includes the one-time shared_secret
      # used to verify delivery signatures — it is shown only on create and rotate.
      # @param name [String] Human-readable name.
      # @param callback_url [String] HTTPS URL the gateway POSTs events to.
      # @param topic [String] One of {TOPICS}.
      # @return [Hash] webhook record including shared_secret
      def create(name:, callback_url:, topic:)
        @http.post("/webhooks", { name: name, callback_url: callback_url, topic: topic })
      end

      # Fetch a single webhook.
      # @param id [String] Webhook UUID.
      # @return [Hash]
      def get(id)
        @http.get("/webhooks/#{id}")
      end

      # Update a webhook's name, callback_url, and/or topic.
      # @param id [String] Webhook UUID.
      # @param name [String, nil]
      # @param callback_url [String, nil]
      # @param topic [String, nil] One of {TOPICS}.
      # @return [Hash]
      def update(id, name: nil, callback_url: nil, topic: nil)
        body = {}
        body[:name]         = name         unless name.nil?
        body[:callback_url] = callback_url unless callback_url.nil?
        body[:topic]        = topic        unless topic.nil?
        @http.patch("/webhooks/#{id}", body)
      end

      # Re-enable a disabled webhook.
      # @param id [String] Webhook UUID.
      # @return [Hash]
      def enable(id)
        @http.put("/webhooks/#{id}/enable")
      end

      # Disable a webhook (stops deliveries without deleting it).
      # @param id [String] Webhook UUID.
      # @return [Hash]
      def disable(id)
        @http.put("/webhooks/#{id}/disable")
      end

      # Generate a new shared secret, returned once on the response.
      # @param id [String] Webhook UUID.
      # @return [Hash] webhook record including the new shared_secret
      def rotate_secret(id)
        @http.put("/webhooks/#{id}/rotate_secret")
      end

      # Reset the delivery circuit breaker and re-enable the webhook.
      # @param id [String] Webhook UUID.
      # @return [Hash]
      def reset_circuit(id)
        @http.put("/webhooks/#{id}/reset_circuit")
      end

      # List delivery attempts for a webhook.
      # @param id [String] Webhook UUID.
      # @param status [String, nil] Filter by delivery status ("pending", "delivered", "failed").
      # @param topic [String, nil] Filter by event topic.
      # @param payment_id [String, nil] Filter by the payment the delivery is for.
      # @param since [String, nil] Only deliveries at/after this ISO-8601 time.
      # @param until_time [String, nil] Only deliveries at/before this ISO-8601 time (query key: "until").
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def event_callbacks(id, status: nil, topic: nil, payment_id: nil, since: nil,
                          until_time: nil, sort: nil, page: nil, per_page: nil)
        query = build_query(status: status, topic: topic, payment_id: payment_id, since: since,
                            until: until_time, sort: sort, page: page, per_page: per_page)
        @http.get_list("/webhooks/#{id}/event_callbacks#{query}")
      end

      # Delete a webhook. Returns HTTP 204.
      # @param id [String] Webhook UUID.
      # @return [nil]
      def delete(id)
        @http.delete("/webhooks/#{id}")
      end
    end
  end
end
