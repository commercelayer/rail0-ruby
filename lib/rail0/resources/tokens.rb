module Rail0
  module Resources
    class Tokens
      def initialize(http)
        @http = http
      end

      # Returns whether the given ERC-20 token is in this deployment's allowlist.
      # @param address [String] ERC-20 token contract address
      # @return [Hash] with keys :address, :accepted
      def is_accepted(address)
        @http.get("/tokens/#{address}")
      end
    end
  end
end
