# frozen_string_literal: true

require "cgi"

module Rail0
  module Resources
    class Wallets
      def initialize(http)
        @http = http
      end

      # List tokens associated with a wallet.
      # @param wallet_id [String] Wallet UUID.
      # @param symbol [String, nil] Filter by token symbol (case-insensitive).
      # @param active [Boolean, nil] Filter by active flag; omit to return all.
      # @param page [Integer] Page number (1-based, default 1).
      # @param per_page [Integer] Items per page (default 20, max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def tokens(wallet_id, symbol: nil, active: nil, page: nil, per_page: nil)
        query = build_query(symbol: symbol, active: active, page: page, per_page: per_page)
        @http.get("/wallets/#{wallet_id}/tokens#{query}")
      end

      private

      def build_query(**params)
        pairs = params.compact.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }
        pairs.empty? ? "" : "?#{pairs.join("&")}"
      end
    end
  end
end
