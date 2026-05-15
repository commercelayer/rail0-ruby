module Rail0
  module Resources
    class Utils
      def initialize(http)
        @http = http
      end

      # Returns the EIP-712 domain separator for the RAIL0 contract on the current chain.
      # @return [Hash] with key :domainSeparator
      def domain_separator
        @http.get("/domain-separator")
      end

      # Returns the contract version number.
      # @return [Hash] with key :version
      def version
        @http.get("/version")
      end
    end
  end
end
