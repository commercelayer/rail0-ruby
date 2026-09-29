# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Public blockchain catalog (GET /blockchains, no auth).
    class Chains
      include Query

      attr_reader :http

      def initialize(http)
        @http = http
        freeze
      end

      # List active blockchains supported by RAIL0.
      # @param network_type [String, nil] Filter by "testnet" or "mainnet".
      # @param symbol [String, nil] Filter by native symbol (case-insensitive, e.g. "ETH").
      # @return [Array<Hash>] chain_id, name, native_symbol, network_type, explorer_url,
      #   required_confirmations, finality_tag (the settlement rule: the tag where the
      #   chain serves one, the count only where it does not), and contract — the chain's
      #   active RAIL0 deployment as `{ address:, version:, deployed_at: }` (what holds
      #   the money; nullable in principle, present in practice), and settlement — how long
      #   an operation on the chain has taken to confirm ON THIS GATEWAY, as
      #   `{ p50_seconds:, p90_seconds:, sample_size:, window_days: }`: broadcast-to-confirmation
      #   percentiles (whole seconds, rounded up) over the trailing `window_days`. Always
      #   present; the percentiles are nil below the gateway's minimum sample (20), so check
      #   `sample_size` and keep a fixed fallback. A wait-deadline hint (e.g. 3 × p90_seconds,
      #   floored at your fallback), not a guarantee.
      def list(network_type: nil, symbol: nil)
        http.get("/blockchains#{build_query(network_type: network_type, symbol: symbol)}")
      end
    end
  end
end
