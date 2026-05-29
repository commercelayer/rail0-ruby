# frozen_string_literal: true

module Rail0
  module Resources
    class Chains
      def initialize(http)
        @http = http
      end

      # List all active blockchains supported by RAIL0.
      # @return [Array<Hash>] Blockchain list: chain_id, name, slug, network_type, explorer_url
      def list
        @http.get("/blockchains")
      end
    end
  end
end
