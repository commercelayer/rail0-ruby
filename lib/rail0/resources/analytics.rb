# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Account-scoped payment analytics (requires JWT — a buyer's account-less token is
    # refused with `account_required`). Every endpoint takes the same filters, so the
    # three views answer one question at different resolutions: a total, a series over
    # time, a split by dimension.
    #
    # Money is never summed across units, and each view obeys that differently: `summary`
    # and `breakdown` GROUP by (token, chain) and always report volume, while `timeseries`
    # can only carry volume when a query pins both `token` and `chain_id` — a bucket is one
    # number, so it has nowhere to keep two tokens apart. Gas follows the same rule per
    # chain: it is denominated in the chain's native token, so it is reported per chain and
    # never totalled.
    #
    # These methods return the parsed JSON as-is, so the keys documented below are the
    # contract this SDK offers — there is no typed wrapper standing between them and the
    # gateway.
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
      # @param token [String, nil] Token address (0x…).
      # @param chain_id [Integer, nil] Chain ID. Pass nil or 0 for all chains.
      # @param from [String, nil] ISO-8601 — payments created at/after this time.
      # @param to [String, nil] ISO-8601 — payments created at/before this time.
      # @return [Hash] the headline KPIs:
      #   * `orders`, `disputed` — counts.
      #   * `refund_rate`, `dispute_rate` — fractions in [0,1], per ORDER.
      #   * `failed_rate` — per resolved TRANSACTION, not per order: one order can carry
      #     several attempts, and a retried capture that eventually confirms is what this
      #     surfaces.
      #   * `by_status` — status => count, for the statuses present.
      #   * `volume` — one row per (token, chain) with base-unit integer strings: `gross`
      #     authorized, `settled` held by the payee net of refunds, `escrowed` still in
      #     escrow, and gross `captured`/`refunded` from the confirmed transactions. The
      #     first two say where the money IS, the last two what HAPPENED.
      #   * `gas` — one row per CHAIN, in that chain's NATIVE token (`decimals` 18, never
      #     the payment token): `spent` on confirmed transactions, `wasted` burned by
      #     on-chain reverts, `confirmed`/`failed` counts, and `orders` — the payments
      #     behind the figures, which is the denominator for the average cost of an order.
      #     Never sum across chains: Base ETH and Polygon POL are different currencies.
      #   * `gas_by_status`, `gas_by_operation` — those same rows regrouped, each carrying
      #     a `key` (the status / the operation). Every cut adds back up to its chain's
      #     `gas` row. `orders` is null on the operation cut, since one order spans several
      #     operations. The status cut is a SNAPSHOT: status moves, so an authorize's gas
      #     sits under "authorized" until the payment is captured and then under
      #     "captured".
      #
      #   Gas covers only the operations the merchant broadcasts — dispute/close_dispute
      #   are the buyer's cost on-chain and release records no sender, so both are out.
      def summary(**filters)
        http.get("/analytics/summary#{build_query(**only_filters(filters))}")
      end

      # The account's payment count per time bucket, oldest first.
      # @param interval [String, nil] "day" (default), "week" or "month". Anything else is
      #   rejected by the gateway — there is no hourly bucket.
      # @return [Array<Hash>] `bucket` (ISO-8601 start), `orders`, and `volume` — a
      #   base-unit string only when BOTH token and chain_id are filtered, else null.
      def timeseries(interval: nil, **filters)
        http.get("/analytics/timeseries#{build_query(**only_filters(filters).merge(interval: interval))}")
      end

      # The account's payments aggregated by one dimension.
      # @param by [String] Required — "token", "chain", "mode" or "status".
      # @return [Array<Hash>] one row per group: `key` (the dimension value) and `orders`.
      #   token/chain rows also carry `token`, `chain_id`, `decimals` and `volume`;
      #   mode/status rows leave those null, since summing money across tokens would add
      #   different currencies.
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
