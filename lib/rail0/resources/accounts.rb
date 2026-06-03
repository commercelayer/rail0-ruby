# GENERATED — DO NOT EDIT. Run `ruby gen/generate.rb` to regenerate.
# frozen_string_literal: true

require "cgi"

module Rail0
  module Resources
    class Accounts
      def initialize(http)
        @http = http
      end

      # Fetch accepted payment methods for an account.
      # @param account_id [String] Account UUID.
      # @return [Array<Hash>]
      def payment_methods(account_id)
        @http.get("/accounts/#{account_id}/payment-methods")
      end

      # List wallet tokens for an account. Public — no JWT required.
      # @param account_id [String] Account UUID.
      # @param chain_id [Integer, nil] Filter by EVM chain ID.
      # @param chain_slug [String, nil] Filter by chain slug (e.g. "base").
      # @param token_symbol [String, nil] Filter by token symbol (e.g. "USDC").
      # @param active [Boolean, nil] Filter by active flag; omit to return all.
      # @param page [Integer] Page number (1-based, default 1).
      # @param per_page [Integer] Items per page (default 20, max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def wallets(account_id, chain_id: nil, chain_slug: nil, token_symbol: nil, active: nil, page: nil, per_page: nil)
        query = build_query(chain_id: chain_id, chain_slug: chain_slug, token_symbol: token_symbol,
                            active: active, page: page, per_page: per_page)
        @http.get("/accounts/#{account_id}/wallets#{query}")
      end

      # Fetch a single wallet token by id. Public — no JWT required.
      # @param account_id [String] Account UUID.
      # @param id [String] Wallet token UUID.
      # @return [Hash]
      def wallet(account_id, id)
        @http.get("/accounts/#{account_id}/wallets/#{id}")
      end

      private

      def build_query(**params)
        pairs = params.compact.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }
        pairs.empty? ? "" : "?#{pairs.join("&")}"
      end
    end
  end
end
