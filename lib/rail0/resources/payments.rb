module Rail0
  module Resources
    class Payments
      def initialize(http)
        @http = http
      end

      # Fetch current payment state (DB status + on-chain amounts).
      # @param payment_id [String] bytes32 payment identifier
      # @return [Hash] PaymentResponse: paymentId, status, onChain: { exists, capturableAmount, refundableAmount }, …
      def get(payment_id)
        @http.get("/payments/#{payment_id}")
      end

      # Create a payment intent. Returns the EIP-712 signingPayload for the payer to sign.
      # @param params [Hash] CreatePaymentRequest fields: payment, amount, chainId, mode
      # @return [Hash] CreatePaymentResponse: paymentId, configHash, payment, amount, chainId, rail0Contract, signingPayload
      def create_payment(params)
        @http.post("/payments", params)
      end

      # Submit the payer's EIP-712 signature (v, r, s).
      # @param payment_id [String] bytes32 payment identifier
      # @param params [Hash] PayerSignatureRequest fields: v, r, s
      # @return [Hash] PayerSignatureResponse: paymentId, status
      def sign(payment_id, params)
        @http.put("/payments/#{payment_id}/sign", params)
      end

      # Relay the stored EIP-3009 signature to the RAIL0 authorize() function. Called by the payee.
      # @param payment_id [String]
      # @return [Hash] PrepareTransactionResponse: unsignedTransaction, from
      def authorize(payment_id)
        @http.post("/payments/#{payment_id}/authorize")
      end

      # Broadcast a signed authorize transaction. Called by the payee.
      # @param payment_id [String]
      # @param params [Hash] SubmitTransactionRequest fields: signedTransaction
      # @return [Hash] AuthorizePaymentResponse: paymentId, transactionHash, capturableAmount, authorizationExpiry
      def submit_authorize(payment_id, params)
        @http.post("/payments/#{payment_id}/authorize/submit", params)
      end

      # Relay the stored EIP-3009 signature to the RAIL0 charge() function (one-shot). Called by the payee.
      # @param payment_id [String]
      # @return [Hash] ChargePaymentResponse: paymentId, transactionHash, chargedAmount, feeAmount, refundableAmount
      def charge(payment_id)
        @http.post("/payments/#{payment_id}/charge")
      end

      # Build the unsigned capture() transaction. Called by the payee.
      # @param payment_id [String]
      # @param params [Hash] CapturePaymentRequest fields: amount
      # @return [Hash] PrepareTransactionResponse: unsignedTransaction, to, data, chainId, nonce, maxFeePerGas, maxPriorityFeePerGas, gasLimit
      def prepare_capture(payment_id, params)
        @http.post("/payments/#{payment_id}/capture", params)
      end

      # Broadcast a signed capture transaction. Called by the payee.
      # @param payment_id [String]
      # @param params [Hash] SubmitTransactionRequest fields: signedTransaction
      # @return [Hash] CapturePaymentResponse: paymentId, transactionHash, capturedAmount, capturableAmount, refundableAmount
      def submit_capture(payment_id, params)
        @http.post("/payments/#{payment_id}/capture/submit", params)
      end

      # Build the unsigned void() transaction. Called by the payee.
      # @param payment_id [String]
      # @return [Hash] PrepareTransactionResponse
      def prepare_void(payment_id)
        @http.post("/payments/#{payment_id}/void")
      end

      # Broadcast a signed void transaction. Called by the payee.
      # @param payment_id [String]
      # @param params [Hash] SubmitTransactionRequest fields: signedTransaction
      # @return [Hash] VoidPaymentResponse: paymentId, transactionHash, releasedAmount
      def submit_void(payment_id, params)
        @http.post("/payments/#{payment_id}/void/submit", params)
      end

      # Build the unsigned release() transaction. Optionally pass callerAddress for buyer-initiated release.
      # @param payment_id [String]
      # @param params [Hash] optional: callerAddress
      # @return [Hash] PrepareTransactionResponse: unsignedTransaction, from
      def prepare_release(payment_id, params = {})
        @http.post("/payments/#{payment_id}/release", params)
      end

      # Broadcast a signed release transaction.
      # @param payment_id [String]
      # @param params [Hash] SubmitTransactionRequest fields: signedTransaction
      # @return [Hash] ReleasePaymentResponse: paymentId, transactionHash, releasedAmount
      def submit_release(payment_id, params)
        @http.post("/payments/#{payment_id}/release/submit", params)
      end

      # Build the unsigned ERC-20 approve() transaction needed before a refund. Called by the payee.
      # @param payment_id [String]
      # @param params [Hash] ApproveRequest fields: amount
      # @return [Hash] PrepareTransactionResponse
      def prepare_approve(payment_id, params)
        @http.post("/payments/#{payment_id}/approve", params)
      end

      # Broadcast a signed ERC-20 approve transaction. Called by the payee.
      # @param payment_id [String]
      # @param params [Hash] SubmitTransactionRequest fields: signedTransaction
      # @return [Hash] ApproveResponse: transactionHash, token, spender, amount
      def submit_approve(payment_id, params)
        @http.post("/payments/#{payment_id}/approve/submit", params)
      end

      # Build the unsigned refund() transaction. Called by the payee.
      # @param payment_id [String]
      # @param params [Hash] RefundPaymentRequest fields: amount
      # @return [Hash] PrepareTransactionResponse
      def prepare_refund(payment_id, params)
        @http.post("/payments/#{payment_id}/refund", params)
      end

      # Broadcast a signed refund transaction. Called by the payee.
      # @param payment_id [String]
      # @param params [Hash] SubmitTransactionRequest fields: signedTransaction
      # @return [Hash] RefundPaymentResponse: paymentId, transactionHash, refundedAmount, refundableAmount
      def submit_refund(payment_id, params)
        @http.post("/payments/#{payment_id}/refund/submit", params)
      end
    end
  end
end
