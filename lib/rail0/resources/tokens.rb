# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Public token catalog (GET /tokens, no auth).
    class Tokens
      include Query

      attr_reader :http

      def initialize(http)
        @http = http
        freeze
      end

      # List tokens, optionally filtered by chain, symbol and/or active flag.
      #
      # Without `active:` this is the HISTORICAL catalogue — retired tokens included — so
      # a payment created long ago still resolves its token. Only an active token may be
      # used for a NEW payment (POST /payments answers 422 unknown_token otherwise), so a
      # checkout picker should pass `active: true`.
      #
      # @param chain_id [Integer, nil] Chain ID to filter by. Pass nil or 0 for all chains.
      # @param symbol [String, nil] Filter by token symbol (case-insensitive, e.g. "USDC").
      # @param active [Boolean, nil] Filter by active flag; omitted returns every token.
      # @return [Array<Hash>] chain_id, symbol, address, decimals, active
      def list(chain_id: nil, symbol: nil, active: nil)
        chain_id = nil if chain_id == 0
        http.get("/tokens#{build_query(chain_id: chain_id, symbol: symbol, active: active)}")
      end
    end
  end
end
