# frozen_string_literal: true

module Rail0
  module Resources
    # SIWE (Sign-In With Ethereum) authentication.
    #
    # {nonce} and {verify} are plain HTTP calls with no extra dependencies.
    # {login} runs the full handshake and needs the optional signing gems
    # ('eth' and 'siwe-rb'), which are required lazily so `require "rail0"`
    # works without them.
    #
    # The JWT returned by {verify}/{login} is NOT stored on the client — pass it
    # yourself on subsequent requests via the client's +headers+:
    #   auth = client.auth.login(private_key: "0x...", domain: "api.rail0.xyz")
    #   client = Rail0::Client.new(base_url: BASE, headers: { "Authorization" => "Bearer #{auth[:token]}" })
    class Auth
      attr_reader :http

      def initialize(http)
        @http = http
        freeze
      end

      # Fetch a single-use SIWE nonce from the API (POST /auth/nonces).
      # @return [Hash] { nonce:, expires_at: }
      def nonce
        http.post("/auth/nonces", {})
      end

      # Submit a pre-built SIWE message and its signature, returning a JWT.
      # @param message   [String] EIP-4361 formatted message string.
      # @param signature [String] 0x-prefixed hex signature.
      # @return [Hash] { token:, address:, account_id:, name:, expires_at: }
      def verify(message:, signature:)
        http.post("/auth", { message: message, signature: signature })
      end

      # End the session whose token this client carries.
      #
      # Per TOKEN, not per address: signing out one process leaves the others signed in.
      # Requires the session it revokes, so the client must be holding one — a client
      # built without a token gets a 401 rather than a silent no-op.
      #
      # `revoked` is the OUTCOME, not a formality, and the reason this returns the body
      # instead of nil. The gateway's denylist fails open by design — a store outage must
      # not sign out the whole platform — so `false` means the token is STILL USABLE until
      # its own expiry, and a caller should treat its copy as compromised rather than
      # assume the session is gone. rail0-go and rail0-ts have had this; Ruby was the one
      # SDK where a long-lived process could not hand a session back. (#19)
      #
      # @return [Hash] { revoked: true|false }
      def logout
        http.post("/auth/logout", {})
      end

      # End EVERY session of the calling address (POST /auth/revoke_all).
      #
      # The answer to a key you no longer trust, and {#logout} cannot be that answer: it
      # is per TOKEN, so an address with five live sessions needs five tokens the caller
      # does not have. This is per ADDRESS and reaches the ones it never saw — including
      # any an attacker is holding.
      #
      # The gateway records a cutoff INSTANT rather than enumerating tokens, so a session
      # minted a moment before the call is refused by its own `iat`. That is what makes it
      # durable where a denylist is not: there is nothing to enumerate and nothing to miss.
      #
      # `cutoff` is the field worth logging. It says exactly which sessions died, which
      # `revoked: true` cannot.
      #
      # @return [Hash] { revoked: true|false, cutoff: "2026-08-27T21:00:00Z" }
      def revoke_all
        http.post("/auth/revoke_all", {})
      end

      # Perform the full SIWE authentication flow:
      #   1. Fetch a nonce
      #   2. Build an EIP-4361 message via siwe-rb
      #   3. Sign it with personal_sign (EIP-191)
      #   4. Verify with the API and return a JWT
      #
      # Requires the optional 'eth' and 'siwe-rb' gems.
      #
      # @param private_key [String] 0x-prefixed hex private key of the account wallet.
      # @param domain      [String] Host of the API server (e.g. "api.rail0.xyz").
      # @param chain_id    [Integer] Chain ID to embed in the SIWE message. Must match
      #   the gateway's SIWE_CHAIN_ID policy (default 1); override only when the
      #   gateway is configured with a different login chain.
      # @return [Hash] { token:, address:, account_id:, name:, expires_at: }
      def login(private_key:, domain:, chain_id: 1)
        ensure_signing_deps!

        nonce_resp = nonce
        key        = build_eth_key(private_key)
        address    = key.address.to_s

        msg = Siwe::Message.new(
          domain:    domain,
          address:   address,
          uri:       "https://#{domain}",
          chain_id:  chain_id,
          nonce:     nonce_resp[:nonce] || nonce_resp["nonce"],
          statement: "Sign in to RAIL0"
        )
        message_str = msg.prepare_message

        sig = personal_sign(key, message_str)
        verify(message: message_str, signature: sig)
      end

      private

      def ensure_signing_deps!
        original_verbose = $VERBOSE
        $VERBOSE = nil
        require "eth"
        require "siwe"
        # rubocop:disable Lint/Void -- referencing these constants IS the point: it forces the
        # autoloaded parser/message files to load here, while warnings are muted, instead of
        # at the first login where the gem's own warnings would reach the caller's output.
        Siwe::Parser
        Siwe::Message
        # rubocop:enable Lint/Void
      rescue LoadError => e
        raise e,
              "client.auth.login requires the 'eth' and 'siwe-rb' gems. " \
              "Add them to your Gemfile: gem 'eth', '~> 0.5'; gem 'siwe-rb', '~> 0.2'"
      ensure
        $VERBOSE = original_verbose
      end

      def build_eth_key(private_key)
        hex = private_key.start_with?("0x") ? private_key[2..] : private_key
        Eth::Key.new(priv: hex)
      end

      def personal_sign(key, message)
        prefixed  = "\x19Ethereum Signed Message:\n#{message.bytesize}#{message}"
        digest    = Eth::Util.keccak256(prefixed)
        sig       = key.sign(digest)
        sig_bytes = [sig].pack("H*")
        "0x#{sig_bytes.unpack1('H*')}"
      end
    end
  end
end
