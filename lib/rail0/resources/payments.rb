module Rail0
  module Resources
    class Payments
      def initialize(http)
        @http = http
      end

      # Returns the current on-chain state and config hash for a payment.
      # @param payment_id [String] bytes32 payment identifier
      # @return [Hash] with keys :paymentId, :state, :configHash
      def get(payment_id)
        @http.get("/payments/#{payment_id}")
      end

      # Pull amount from the payer into escrow using an EIP-3009 transferWithAuthorization signature.
      # @param payment_id [String]
      # @param params [Hash] with keys :payment, :amount, :v, :r, :s
      # @return [Hash] with keys :transactionHash, :status
      def authorize(payment_id, params)
        @http.post("/payments/#{payment_id}/authorize", params)
      end

      # Authorize and immediately capture in a single transaction. Uses an EIP-3009 signature.
      # @param payment_id [String]
      # @param params [Hash] with keys :payment, :amount, :v, :r, :s
      # @return [Hash] with keys :transactionHash, :status
      def charge(payment_id, params)
        @http.post("/payments/#{payment_id}/charge", params)
      end

      # Capture escrowed funds. Caller must be the payee.
      # @param payment_id [String]
      # @param params [Hash] with keys :payment, :amount
      # @return [Hash] with keys :transactionHash, :status
      def capture(payment_id, params)
        @http.post("/payments/#{payment_id}/capture", params)
      end

      # Cancel an authorization, returning escrowed funds to the payer. Caller must be the payee.
      # @param payment_id [String]
      # @param params [Hash] with key :payment
      # @return [Hash] with keys :transactionHash, :status
      def void(payment_id, params)
        @http.post("/payments/#{payment_id}/void", params)
      end

      # Return escrowed funds to the payer after authorizationExpiry. Permissionless.
      # @param payment_id [String]
      # @param params [Hash] with key :payment
      # @return [Hash] with keys :transactionHash, :status
      def release(payment_id, params)
        @http.post("/payments/#{payment_id}/release", params)
      end

      # Refund a previously captured amount from the payee to the payer. Caller must be the payee.
      # @param payment_id [String]
      # @param params [Hash] with keys :payment, :amount
      # @return [Hash] with keys :transactionHash, :status
      def refund(payment_id, params)
        @http.post("/payments/#{payment_id}/refund", params)
      end

      # Returns the EIP-3009 nonce the payer must use when signing an authorize call.
      # @param payment_id [String]
      # @param payer [String] Ethereum address
      # @return [Hash] with key :nonce
      def authorize_nonce(payment_id, payer)
        @http.get("/payments/#{payment_id}/authorize-nonce?payer=#{payer}")
      end

      # Returns the EIP-3009 nonce the payer must use when signing a charge call.
      # @param payment_id [String]
      # @param payer [String] Ethereum address
      # @return [Hash] with key :nonce
      def charge_nonce(payment_id, payer)
        @http.get("/payments/#{payment_id}/charge-nonce?payer=#{payer}")
      end

      # Compute the canonical EIP-712 digest of a Payment configuration.
      # @param payment [Hash]
      # @return [Hash] with key :hash
      def hash(payment)
        @http.post("/payments/hash", payment)
      end
    end
  end
end
