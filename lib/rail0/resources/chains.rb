# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Public blockchain catalog (GET /blockchains, no auth).
    class Chains
      include Query

      attr_reader :http

      def initialize(http)
        @http = http
        freeze
      end

      # List active blockchains supported by RAIL0.
      # @param network_type [String, nil] Filter by "testnet" or "mainnet".
      # @param symbol [String, nil] Filter by native symbol (case-insensitive, e.g. "ETH").
      # @return [Array<Hash>] chain_id, slug (shared by a chain's testnet and mainnet, e.g.
      #   "arc"; unique per network_type), name, native_symbol, network_type, explorer_url,
      #   public_rpc_urls (keyless RPC endpoints published for clients),
      #   required_confirmations, finality_tag (the settlement rule: the tag where the
      #   chain serves one, the count only where it does not), and contract — the chain's
      #   active RAIL0 deployment as `{ address:, version:, deployed_at: }` (what holds
      #   the money; nullable in principle, present in practice), and settlement — how long
      #   an operation on the chain has taken to confirm ON THIS GATEWAY, as
      #   `{ p50_seconds:, p90_seconds:, sample_size:, window_days: }`: broadcast-to-confirmation
      #   percentiles (whole seconds, rounded up) over the trailing `window_days`. Always
      #   present; the percentiles are nil below the gateway's minimum sample (20), so check
      #   `sample_size` and keep a fixed fallback. A wait-deadline hint (e.g. 3 × p90_seconds,
      #   floored at your fallback), not a guarantee.
      def list(network_type: nil, symbol: nil)
        http.get("/blockchains#{build_query(network_type: network_type, symbol: symbol)}")
      end

      # Picks one chain out of a {list} result by numeric chain id OR slug. No request.
      #
      # +ref+ is an Integer or an all-digit String (a chain id: "5042002", 5042002) or a
      # slug, compared case-insensitively ("Arc"). A slug is shared by a chain's testnet
      # and mainnet, so when the list holds both it is AMBIGUOUS and raises rather than
      # guessing which network the caller meant: pass the chain id, or a list filtered
      # with +network_type:+. Nothing matching raises too, naming the slugs available.
      #
      #   chains = client.chains.list(network_type: "testnet")
      #   Rail0::Resources::Chains.resolve(chains, "arc")    # => { chain_id: 5042002, slug: "arc", ... }
      #   Rail0::Resources::Chains.resolve(chains, 5042002)  # the same chain
      #
      # @param chains [Array<Hash>] blockchains, as {list} returns them (symbol or string keys)
      # @param ref [Integer, String] chain id or slug
      # @return [Hash] the matching chain
      # @raise [ArgumentError] when nothing matches, or the slug matches several chains
      def self.resolve(chains, ref)
        key = ref.to_s.strip
        raise ArgumentError, "a chain id or slug is required" if key.empty?

        rows = Array(chains).map { |c| c.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k } }
        return resolve_id(rows, key) if key.match?(/\A\d+\z/)

        matches = rows.select { |c| c[:slug].to_s.casecmp(key).zero? }
        return matches.first if matches.size == 1

        if matches.empty?
          raise ArgumentError, "no chain with slug #{key.inspect} (available slugs: #{describe_available(rows)})"
        end

        ids = matches.map { |c| "#{c[:chain_id]} (#{c[:network_type] || 'unknown network'})" }.join(", ")
        raise ArgumentError, "slug #{key.inspect} is ambiguous: it matches chains #{ids} — pass the chain id, " \
                             "or list with network_type:"
      end

      def self.resolve_id(rows, key)
        found = rows.find { |c| c[:chain_id].to_s == key.sub(/\A0+(?=\d)/, "") }
        return found if found

        raise ArgumentError, "no chain with id #{key} (available: #{describe_available(rows)})"
      end

      def self.describe_available(rows)
        slugs = rows.map { |c| c[:slug].to_s.downcase }.reject(&:empty?).uniq.sort
        slugs.empty? ? "none" : slugs.join(", ")
      end
      private_class_method :resolve_id, :describe_available
    end
  end
end
