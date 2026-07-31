# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Account-scoped payment analytics (requires JWT — a buyer's account-less token is
    # refused with `account_required`). Every endpoint takes the same filters, so the
    # three views answer one question at different resolutions: a total, a series over
    # time, a split by dimension. Volume is reported only when a query pins both `token`
    # and `chain_id`, since amounts in different tokens are different units.
    class Analytics
      include Query

      FILTERS = %i[mode status token chain_id from to].freeze

      attr_reader :http

      def initialize(http)
        @http = http
        freeze
      end

      # Totals for the account's payments.
      # @param mode [String, nil] "authorize" or "charge".
      # @param status [String, nil] A payment status, e.g. "captured".
      # @param token [String, nil] Token address (0x…); with chain_id, unlocks volume.
      # @param chain_id [Integer, nil] Chain ID. Pass nil or 0 for all chains.
      # @param from [String, nil] ISO-8601 — payments created at/after this time.
      # @param to [String, nil] ISO-8601 — payments created at/before this time.
      # @return [Hash] count, disputed_count and (with token+chain_id) volume.
      def summary(**filters)
        http.get("/analytics/summary#{build_query(**only_filters(filters))}")
      end

      # The account's payment count per time bucket, oldest first.
      # @param interval [String, nil] "hour", "day", "week" or "month" (default "day").
      # @return [Array<Hash>] bucket, count, and volume with token+chain_id.
      def timeseries(interval: nil, **filters)
        http.get("/analytics/timeseries#{build_query(**only_filters(filters).merge(interval: interval))}")
      end

      # The account's payments aggregated by one dimension.
      # @param by [String] Required — "token", "chain", "mode" or "status".
      # @return [Array<Hash>] One row per group; token and chain rows carry volume.
      def breakdown(by:, **filters)
        raise ArgumentError, "by is required (token, chain, mode or status)" if by.nil? || by.to_s.empty?

        http.get("/analytics/breakdown#{build_query(**only_filters(filters).merge(by: by))}")
      end

      private

      def only_filters(filters)
        picked = filters.slice(*FILTERS)
        picked[:chain_id] = nil if picked[:chain_id] == 0
        picked
      end
    end
  end
end
