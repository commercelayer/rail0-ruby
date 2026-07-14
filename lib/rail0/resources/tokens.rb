# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Public token catalog (GET /tokens, no auth).
    class Tokens
      include Query

      def initialize(http)
        @http = http
      end

      # List active tokens, optionally filtered by chain and/or symbol.
      # @param chain_id [Integer, nil] Chain ID to filter by. Pass nil or 0 for all chains.
      # @param symbol [String, nil] Filter by token symbol (case-insensitive, e.g. "USDC").
      # @return [Array<Hash>] chain_id, symbol, address, decimals
      def list(chain_id: nil, symbol: nil)
        chain_id = nil if chain_id == 0
        @http.get("/tokens#{build_query(chain_id: chain_id, symbol: symbol)}")
      end
    end
  end
end
