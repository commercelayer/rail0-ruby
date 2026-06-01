require "uri"

module Rail0
  module Resources
    class Accounts
      def initialize(http)
        @http = http
      end

      # Fetch all accepted payment methods for an account.
      # @param account_id [Integer, String] Account identifier.
      # @param stablecoin_id [Integer, String, nil] Filter by token id.
      # @param stablecoin_symbol [String, nil] Filter by token symbol (case-insensitive).
      # @param blockchain_id [Integer, String, nil] Filter by blockchain id.
      # @param blockchain_slug [String, nil] Filter by blockchain slug (case-insensitive).
      # @return [Array<Hash>] PaymentMethod list: id, tokenId, chainId, chainName, chainSlug,
      #   explorerUrl, tokenAddress, tokenSymbol, tokenDecimals, walletAddress, isDefault
      def payment_methods(account_id, stablecoin_id: nil, stablecoin_symbol: nil, blockchain_id: nil, blockchain_slug: nil)
        query = {
          stablecoin_id:     stablecoin_id,
          stablecoin_symbol: stablecoin_symbol,
          blockchain_id:     blockchain_id,
          blockchain_slug:   blockchain_slug
        }.compact
        path = "/accounts/#{account_id}/payment-methods"
        path += "?#{URI.encode_www_form(query)}" unless query.empty?
        @http.get(path)
      end
    end
  end
end
