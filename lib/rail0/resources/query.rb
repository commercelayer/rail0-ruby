# frozen_string_literal: true

require "cgi"
require "erb"

module Rail0
  module Resources
    # Shared URL builders for resource classes. Included so every resource turns
    # keyword filters into a URL query the same way (nil values are dropped,
    # booleans/integers are stringified) and escapes every caller-supplied path
    # segment the same way ({#segment}).
    module Query
      # Segments that would not stay put once interpolated: "." and ".." are dot
      # segments that a URL normaliser (a proxy, a CDN, the server's router) may
      # resolve away, and an empty one collapses the path onto its parent.
      UNSAFE_SEGMENTS = ["", ".", ".."].freeze
      private_constant :UNSAFE_SEGMENTS

      private

      # Escapes ONE caller-supplied value for interpolation into a request path:
      #
      #   http.get("/payments/#{segment(id)}/transactions/#{segment(transaction_id)}")
      #
      # Paths used to be plain interpolation, so an id was pasted in raw: one
      # containing `/`, `?`, `#` or `..` addressed a different route than the method
      # named — `payments.get("../webhooks/x")` was a GET on /webhooks/x with the
      # caller's token. The ids this SDK is handed normally come from the gateway, but
      # a caller that forwards one from a URL (a proxy route, a CLI argument) passes
      # along whatever it was given.
      #
      # ERB::Util.url_encode percent-encodes everything outside the RFC 3986
      # unreserved set (A-Z a-z 0-9 - . _ ~), UTF-8 byte by byte, with a space as
      # %20 — the path-correct form (CGI.escape, used for queries, would turn a
      # space into `+`, which in a path is a literal plus). For the values legitimately
      # passed (UUIDs, 0x hex, operation names, integer ids) it changes nothing. This
      # matches rail0-ts's `path` tag, which uses encodeURIComponent.
      #
      # A value that is exactly "", "." or ".." raises ArgumentError instead: encoding
      # leaves the dots as they are (they are unreserved), so the segment would still
      # be a dot segment, and an empty one silently re-targets the parent route
      # (`payments.get("")` would list payments). None of them is a valid id, so
      # failing before the request is the only honest answer.
      #
      # @param value [#to_s] The id (or other caller-supplied value) to interpolate.
      # @return [String] The percent-encoded segment.
      # @raise [ArgumentError] If the value is nil, empty, "." or "..".
      def segment(value)
        str = value.to_s
        if value.nil? || UNSAFE_SEGMENTS.include?(str)
          raise ArgumentError, "invalid path segment #{value.inspect}: an id must not be nil, empty, \".\" or \"..\""
        end

        ERB::Util.url_encode(str)
      end

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
