# frozen_string_literal: true

require "cgi"

module Rail0
  module Resources
    class Accounts
      def initialize(http)
        @http = http
      end

      # List wallets for an account.
      # @param account_id [String] Account UUID.
      # @param active [Boolean, nil] Filter by active flag; omit to return all.
      # @param page [Integer] Page number (1-based, default 1).
      # @param per_page [Integer] Items per page (default 20, max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def wallets(account_id, active: nil, page: nil, per_page: nil)
        query = build_query(active: active, page: page, per_page: per_page)
        @http.get("/accounts/#{account_id}/wallets#{query}")
      end

      # Fetch a single wallet by id.
      # @param account_id [String] Account UUID.
      # @param id [String] Wallet UUID.
      # @return [Hash]
      def wallet(account_id, id)
        @http.get("/accounts/#{account_id}/wallets/#{id}")
      end

      # Add a wallet to the account.
      # @param account_id [String] Account UUID.
      # @param address [String] EVM wallet address (0x, 42 chars).
      # @param label [String, nil] Human-readable label.
      # @return [Hash]
      def create_wallet(account_id, address:, label: nil)
        body = { address: address }
        body[:label] = label unless label.nil?
        @http.post("/accounts/#{account_id}/wallets", body)
      end

      # Update a wallet label or active status.
      # @param account_id [String] Account UUID.
      # @param id [String] Wallet UUID.
      # @param label [String, nil] New label.
      # @param active [Boolean, nil] New active status.
      # @return [Hash]
      def update_wallet(account_id, id, label: nil, active: nil)
        body = {}
        body[:label]  = label  unless label.nil?
        body[:active] = active unless active.nil?
        @http.patch("/accounts/#{account_id}/wallets/#{id}", body)
      end

      # Soft-delete (deactivate) a wallet.
      # @param account_id [String] Account UUID.
      # @param id [String] Wallet UUID.
      # @return [nil]
      def delete_wallet(account_id, id)
        @http.delete("/accounts/#{account_id}/wallets/#{id}")
      end

      private

      def build_query(**params)
        pairs = params.compact.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }
        pairs.empty? ? "" : "?#{pairs.join("&")}"
      end
    end
  end
end
