module Rail0
  module Resources
    class Merchants
      def initialize(http)
        @http = http
      end

      # Fetch all accepted payment methods for a merchant.
      # @param merchant_id [Integer, String] Merchant identifier.
      # @return [Array<Hash>] PaymentMethod list: id, tokenId, chainId, chainName, chainSlug,
      #   explorerUrl, tokenAddress, tokenSymbol, tokenDecimals, walletAddress, isDefault
      def payment_methods(merchant_id)
        @http.get("/merchants/#{merchant_id}/payment-methods")
      end
    end
  end
end
