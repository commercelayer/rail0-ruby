# frozen_string_literal: true

require "cgi"

module Rail0
  module Resources
    # Shared query-string builder for resource classes. Included so every
    # resource turns keyword filters into a URL query the same way: nil values
    # are dropped, and booleans/integers are stringified.
    module Query
      private

      # @param params [Hash] filter name => value (nil values are omitted).
      # @return [String] "" when empty, otherwise "?k=v&k2=v2" (URL-escaped).
      def build_query(**params)
        pairs = params.compact.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }
        pairs.empty? ? "" : "?#{pairs.join('&')}"
      end
    end
  end
end
