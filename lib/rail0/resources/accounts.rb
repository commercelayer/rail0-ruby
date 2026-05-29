module Rail0
  module Resources
    class Accounts
      def initialize(http)
        @http = http
      end

      # Fetch all accepted payment methods for an account.
      # @param account_id [Integer, String] Account identifier.
      # @return [Array<Hash>] PaymentMethod list: id, tokenId, chainId, chainName, chainSlug,
      #   explorerUrl, tokenAddress, tokenSymbol, tokenDecimals, walletAddress, isDefault
      def payment_methods(account_id)
        @http.get("/accounts/#{account_id}/payment-methods")
      end
    end
  end
end
