# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Public, buyer-facing payment-method discovery (GET /payment_methods, no JWT).
    #
    # A payer that only knows the merchant — by account id, or by one of the
    # merchant's wallet addresses — can list the active wallet/token combinations
    # the merchant accepts, without holding the merchant's session. This is the
    # public counterpart to the SIWE-gated {Wallets} resource: it exposes only the
    # active wallets and their active token holdings, never operational fields.
    class PaymentMethods
      include Query

      def initialize(http)
        @http = http
      end

      # List a merchant's active payment methods. Provide EXACTLY ONE handle:
      # +account_id+ returns all the merchant's active wallets; +address+ returns
      # just that one wallet. Passing both (or neither) is rejected by the gateway
      # with HTTP 400. An unknown account/address yields an empty array.
      #
      # @param account_id [String, nil] Merchant account UUID.
      # @param address [String, nil] A single merchant wallet address (0x).
      # @return [Array<Hash>] wallets, each with nested active tokens.
      def list(account_id: nil, address: nil)
        @http.get("/payment_methods#{build_query(account_id: account_id, address: address)}")
      end
    end
  end
end
