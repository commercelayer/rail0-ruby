# frozen_string_literal: true

module Rail0
  module Resources
    # Gateway liveness/readiness check (GET /health, no auth).
    class Health
      def initialize(http)
        @http = http
      end

      # Report gateway health, including database connectivity. The gateway
      # returns HTTP 503 (raised as Rail0::ApiError) when the database is
      # unreachable.
      # @return [Hash] status, api_version, contract_version, db, active_chains, active_contracts, timestamp
      def get
        @http.get("/health")
      end
    end
  end
end
