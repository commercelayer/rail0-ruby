# frozen_string_literal: true

require "cgi"

module Rail0
  module Resources
    # Shared query-string builder for resource classes. Included so every
    # resource turns keyword filters into a URL query the same way: nil values
    # are dropped, and booleans/integers are stringified.
    module Query
      private

      # Builds "?k=v&…" from keyword filters, or "" when every value is nil.
      #
      # An Array value becomes ONE comma-separated pair (`status: %w[a b]` →
      # `status=a,b`): the gateway's multi-value filters (e.g. `status` on
      # GET /payments, #367) take the comma form. Each element is escaped on its
      # own and the separating comma is left literal, so a comma can never leak
      # in from an element. nil elements are dropped; an Array left empty drops
      # the whole pair, the same as nil, rather than sending a blank `status=`
      # the gateway would reject with 400.
      def build_query(**params)
        pairs = params.filter_map do |k, v|
          value = query_value(v)
          "#{k}=#{value}" unless value.nil?
        end
        pairs.empty? ? "" : "?#{pairs.join('&')}"
      end

      def query_value(value)
        return nil if value.nil?
        return CGI.escape(value.to_s) unless value.is_a?(Array)

        items = value.compact
        items.map { |item| CGI.escape(item.to_s) }.join(",") unless items.empty?
      end
    end
  end
end
