# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Public blockchain catalog (GET /blockchains, no auth).
    class Chains
      include Query

      def initialize(http)
        @http = http
      end

      # List active blockchains supported by RAIL0.
      # @param network_type [String, nil] Filter by "testnet" or "mainnet".
      # @param symbol [String, nil] Filter by native symbol (case-insensitive, e.g. "ETH").
      # @return [Array<Hash>] chain_id, name, native_symbol, network_type, explorer_url
      def list(network_type: nil, symbol: nil)
        @http.get("/blockchains#{build_query(network_type: network_type, symbol: symbol)}")
      end
    end
  end
end
