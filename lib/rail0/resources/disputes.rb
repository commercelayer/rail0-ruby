# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Account-level dispute list (requires JWT). Complements
    # {Payments#disputes} (one payment's open/close history): this surfaces every
    # dispute — open AND closed — across the authenticated wallet's payments (as
    # payer or payee), each with its parent payment embedded. A closed dispute
    # drops out of the payments `disputed` filter (current-state) but still
    # appears here.
    class Disputes
      include Query

      def initialize(http)
        @http = http
      end

      # List the account's disputes.
      # @param status [String, nil] Filter by "open" or "closed".
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def list(status: nil, sort: nil, page: nil, per_page: nil)
        query = build_query(status: status, sort: sort, page: page, per_page: per_page)
        @http.get_list("/disputes#{query}")
      end
    end
  end
end
