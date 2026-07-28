# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Account-scoped payment analytics (GET /analytics/*). Requires a session whose
    # wallet is attached to an account — a buyer's account-less token is refused with
    # `account_required`, since these numbers are the merchant's own.
    #
    # Every endpoint takes the same filters (mode, status, token, chain_id, from, to)
    # and applies them the same way, so the three views answer the same question at
    # different resolutions: one total, a series over time, a split by dimension.
    class Analytics
      include Query

      # The filters every endpoint accepts, in one place so the three methods cannot
      # drift on what they support.
      FILTERS = %i[mode status token chain_id from to].freeze

      def initialize(http)
        @http = http
      end

      # Totals for the account's payments.
      #
      # Volume is only reported when the query pins BOTH token and chain_id: amounts in
      # different tokens (or the same symbol on different chains) are different units,
      # and summing them would produce a number that looks meaningful and isn't.
      #
      # @param mode [String, nil] "authorize" or "charge"
      # @param status [String, nil] a payment status, e.g. "captured"
      # @param token [String, nil] token address (0x…); with chain_id, unlocks volume
      # @param chain_id [Integer, nil] chain id
      # @param from [String, nil] ISO-8601 — payments created at/after this time
      # @param to [String, nil] ISO-8601 — payments created at/before this time
      # @return [Hash] count, disputed_count and (when token+chain_id are set) volume
      def summary(**filters)
        @http.get("/analytics/summary#{build_query(**only_filters(filters))}")
      end

      # The account's payment count per time bucket, oldest first.
      #
      # @param interval [String, nil] "hour", "day", "week" or "month" (default "day")
      # @return [Array<Hash>] one entry per bucket: bucket, count, and volume when
      #   token+chain_id are set
      def timeseries(interval: nil, **filters)
        query = only_filters(filters).merge(interval: interval)
        @http.get("/analytics/timeseries#{build_query(**query)}")
      end

      # The account's payments aggregated by one dimension.
      #
      # @param by [String] required — "token", "chain", "mode" or "status"
      # @return [Array<Hash>] one row per group. Token and chain rows carry per-token
      #   volume; mode and status rows are counts only, for the reason in #summary —
      #   a mode groups payments across tokens, so there is no single unit to add up.
      def breakdown(by:, **filters)
        raise ArgumentError, "by is required (token, chain, mode or status)" if by.nil? || by.to_s.empty?

        query = only_filters(filters).merge(by: by)
        @http.get("/analytics/breakdown#{build_query(**query)}")
      end

      private

      # Keep only the known filters, and drop a chain_id of 0 the way the other
      # resources do (callers pass 0 for "no filter").
      def only_filters(filters)
        picked = filters.slice(*FILTERS)
        picked[:chain_id] = nil if picked[:chain_id] == 0
        picked
      end
    end
  end
end
