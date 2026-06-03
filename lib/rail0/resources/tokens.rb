# GENERATED — DO NOT EDIT. Run `ruby gen/generate.rb` to regenerate.
# frozen_string_literal: true

module Rail0
  module Resources
    class Tokens
      def initialize(http)
        @http = http
      end

      # List active tokens, optionally filtered by chain.
      # @param chain_id [Integer] Chain ID to filter by. Pass nil or omit for all chains.
      # @return [Array<Hash>] Token list: chain_id, chain_slug, symbol, address, decimals
      def list(chain_id: nil)
        path = chain_id && chain_id != 0 ? "/tokens?chain_id=#{chain_id}" : "/tokens"
        @http.get(path)
      end
    end
  end
end
