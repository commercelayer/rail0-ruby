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
      def initialize(http)
        @http = http
      end

      # Fetch a single-use SIWE nonce from the API (POST /auth/nonces).
      # @return [Hash] { nonce:, expires_at: }
      def nonce
        @http.post("/auth/nonces", {})
      end

      # Submit a pre-built SIWE message and its signature, returning a JWT.
      # @param message   [String] EIP-4361 formatted message string.
      # @param signature [String] 0x-prefixed hex signature.
      # @return [Hash] { token:, address:, account_id:, name:, expires_at: }
      def verify(message:, signature:)
        @http.post("/auth", { message: message, signature: signature })
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

      # Lazily load the optional signing dependencies, raising a helpful error if
      # they are absent (they are not required for {nonce}/{verify} or the rest of
      # the SDK, so `require "rail0"` never pulls them in).
      def ensure_signing_deps!
        require "eth"
        require "siwe"
      rescue LoadError
        raise LoadError,
          "client.auth.login requires the 'eth' and 'siwe-rb' gems. " \
          "Add them to your Gemfile: gem 'eth', '~> 0.5'; gem 'siwe-rb', '~> 0.2'"
      end

      def build_eth_key(private_key)
        hex = private_key.start_with?("0x") ? private_key[2..] : private_key
        Eth::Key.new(priv: hex)
      end

      # EIP-191 personal_sign: sign "\x19Ethereum Signed Message:\n<len><message>".
      # Returns a 0x-prefixed 65-byte hex string (r ++ s ++ v).
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
