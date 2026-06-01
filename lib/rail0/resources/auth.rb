# frozen_string_literal: true

require "uri"

begin
  require "eth"
  require "siwe"
rescue LoadError => e
  raise LoadError,
    "Rail0::Resources::Auth requires the 'eth' and 'siwe-rb' gems. " \
    "Add them to your Gemfile: gem 'eth', '~> 0.5'; gem 'siwe-rb', '~> 0.2'"
end

module Rail0
  module Resources
    class Auth
      def initialize(http)
        @http = http
      end

      # Fetch a single-use SIWE nonce from the API.
      # @return [Hash] { nonce:, expires_at: }
      def nonce
        @http.post("/nonces", {})
      end

      # Submit a pre-built SIWE message and its signature, return a JWT.
      # @param message   [String] EIP-4361 formatted message string.
      # @param signature [String] 0x-prefixed hex signature.
      # @return [Hash] { token:, address:, account_id:, expires_at: }
      def verify(message:, signature:)
        @http.post("/auth", { message: message, signature: signature })
      end

      # Perform the full SIWE authentication flow:
      #   1. Fetch a nonce
      #   2. Build an EIP-4361 message via siwe-rb
      #   3. Sign it with personal_sign (EIP-191)
      #   4. Verify with the API and return a JWT
      #
      # @param private_key [String] 0x-prefixed hex private key of the account wallet.
      # @param domain      [String] Host of the API server (e.g. "api.rail0.xyz").
      # @return [Hash] { token:, address:, account_id:, expires_at: }
      def login(private_key:, domain:)
        nonce_resp = nonce
        key        = build_eth_key(private_key)
        address    = key.address.to_s

        msg = Siwe::Message.new(
          domain:    domain,
          address:   address,
          uri:       "https://#{domain}",
          chain_id:  1,
          nonce:     nonce_resp[:nonce] || nonce_resp["nonce"],
          statement: "Sign in to RAIL0"
        )
        message_str = msg.prepare_message

        sig = personal_sign(key, message_str)
        verify(message: message_str, signature: sig)
      end

      private

      def build_eth_key(private_key)
        hex = private_key.start_with?("0x") ? private_key[2..] : private_key
        Eth::Key.new(priv: hex)
      end

      # EIP-191 personal_sign: sign "\x19Ethereum Signed Message:\n<len><message>".
      # Returns a 0x-prefixed 65-byte hex string (r ++ s ++ v).
      def personal_sign(key, message)
        prefixed = "\x19Ethereum Signed Message:\n#{message.bytesize}#{message}"
        digest   = Eth::Util.keccak256(prefixed)
        sig      = key.sign(digest)
        sig_bytes = [sig].pack("H*")
        "0x#{sig_bytes.unpack1('H*')}"
      end
    end
  end
end
