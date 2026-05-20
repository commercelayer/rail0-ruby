begin
  require "eth"
rescue LoadError
  raise LoadError,
    "Rail0::Signing requires the 'eth' gem. Add `gem 'eth', '~> 0.5'` to your Gemfile."
end

module Rail0
  # EIP-712 and EIP-3009 signing utilities for RAIL0 payments.
  #
  # Requires the optional signing dependency:
  #   gem 'eth', '~> 0.5'
  #
  # No private key is ever sent to the API — signatures are built off-chain
  # and included in the request body.
  module Signing
    # EIP-712 domain of the ERC-20 token (NOT the RAIL0 contract).
    TokenDomain = Struct.new(:name, :version, :chain_id, :verifying_contract, keyword_init: true)

    # EIP-3009 transferWithAuthorization signature, ready to pass into authorize / charge.
    Eip3009Signature = Struct.new(:v, :r, :s, keyword_init: true)

    # Parameters for a raw transferWithAuthorization signature.
    SignTransferParams = Struct.new(
      :from, :to, :value, :valid_before, :nonce,
      :valid_after,
      keyword_init: true
    ) do
      def initialize(**)
        super
        self.valid_after ||= 0
      end
    end

    # Parameters for signing an authorize or charge call.
    # The contract hardcodes validAfter=0 and validBefore=payment[:authorizationExpiry];
    # these are not configurable by the caller.
    SignPaymentParams = Struct.new(
      :private_key, :payment, :amount, :nonce, :contract_address, :token_domain,
      keyword_init: true
    )

    # ================================================================
    #  EIP-712 type strings
    # ================================================================

    DOMAIN_TYPE   = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    TRANSFER_TYPE = "TransferWithAuthorization(address from,address to,uint256 value," \
                    "uint256 validAfter,uint256 validBefore,bytes32 nonce)"

    DOMAIN_TYPEHASH   = Eth::Util.keccak256(DOMAIN_TYPE)
    TRANSFER_TYPEHASH = Eth::Util.keccak256(TRANSFER_TYPE)

    private_constant :DOMAIN_TYPE, :TRANSFER_TYPE, :DOMAIN_TYPEHASH, :TRANSFER_TYPEHASH

    # ================================================================
    #  ABI encoding helpers
    # ================================================================

    def self.hex_to_bytes(hex)
      h = hex.start_with?("0x") ? hex[2..] : hex
      [h].pack("H*")
    end

    def self.abi_address(address)
      "\x00" * 12 + hex_to_bytes(address)
    end

    def self.abi_uint256(value)
      [value].pack("Q>").rjust(32, "\x00")[-32..]
        .then { |b| b.length == 32 ? b : value.to_s(16).rjust(64, "0").then { |h| [h].pack("H*") } }
    end

    # Pack arbitrary-precision integer into 32 big-endian bytes.
    def self.uint256_to_bytes32(value)
      hex = value.to_s(16)
      hex = hex.rjust(64, "0")
      [hex].pack("H*")
    end

    def self.bytes_to_hex(bytes)
      "0x" + bytes.unpack1("H*")
    end

    private_class_method :hex_to_bytes, :abi_address, :uint256_to_bytes32, :bytes_to_hex

    # ================================================================
    #  EIP-712 digest construction
    # ================================================================

    def self.hash_domain(domain)
      Eth::Util.keccak256(
        DOMAIN_TYPEHASH +
        Eth::Util.keccak256(domain.name) +
        Eth::Util.keccak256(domain.version) +
        uint256_to_bytes32(domain.chain_id) +
        abi_address(domain.verifying_contract)
      )
    end

    def self.hash_struct(from:, to:, value:, valid_after:, valid_before:, nonce:)
      Eth::Util.keccak256(
        TRANSFER_TYPEHASH +
        abi_address(from) +
        abi_address(to) +
        uint256_to_bytes32(value) +
        uint256_to_bytes32(valid_after) +
        uint256_to_bytes32(valid_before) +
        hex_to_bytes(nonce)
      )
    end

    def self.build_digest(domain, from:, to:, value:, valid_after:, valid_before:, nonce:)
      Eth::Util.keccak256(
        "\x19\x01" +
        hash_domain(domain) +
        hash_struct(from: from, to: to, value: value, valid_after: valid_after, valid_before: valid_before, nonce: nonce)
      )
    end

    private_class_method :hash_domain, :hash_struct, :build_digest

    # ================================================================
    #  Internal sign helper
    # ================================================================

    def self.do_sign(private_key, domain, from:, to:, value:, valid_after:, valid_before:, nonce:)
      key_hex = private_key.start_with?("0x") ? private_key[2..] : private_key
      key     = Eth::Key.new(priv: key_hex)
      digest  = build_digest(domain, from: from, to: to, value: value, valid_after: valid_after, valid_before: valid_before, nonce: nonce)

      # Eth::Key#sign(blob, prehash=true) — pass false to skip an extra keccak256.
      # Returns a 65-byte binary string: r(32) + s(32) + v(1) where v is 27 or 28.
      sig = key.sign(digest, false)

      # The eth gem returns the signature as a hex string (no 0x prefix).
      sig_bytes = [sig].pack("H*")

      Eip3009Signature.new(
        v: sig_bytes.getbyte(64),   # already 27 or 28 (eth gem adds 27 internally)
        r: bytes_to_hex(sig_bytes[0, 32]),
        s: bytes_to_hex(sig_bytes[32, 32])
      )
    end

    private_class_method :do_sign

    # ================================================================
    #  Public API
    # ================================================================

    # Sign a raw EIP-3009 transferWithAuthorization message.
    #
    # For RAIL0 payment flows prefer {sign_authorize} / {sign_charge} which
    # derive +from+, +to+, and +valid_before+ automatically from the Payment hash.
    #
    # @param private_key [String] Payer's private key (0x-prefixed hex or raw hex).
    # @param domain [TokenDomain]
    # @param params [SignTransferParams]
    # @return [Eip3009Signature]
    def self.sign_transfer_with_authorization(private_key, domain, params)
      do_sign(
        private_key, domain,
        from:         params.from,
        to:           params.to,
        value:        params.value,
        valid_after:  params.valid_after,
        valid_before: params.valid_before,
        nonce:        params.nonce
      )
    end

    # Sign the EIP-3009 payload required by an authorize call.
    #
    #   resp  = client.payments.create_payment(
    #     payment: payment, amount: "50000000", chain_id: chain_id, mode: "authorize"
    #   )
    #   nonce = resp[:signingPayload][:message][:nonce]
    #   sig   = Rail0::Signing.sign_authorize(Rail0::Signing::SignPaymentParams.new(
    #     private_key: "0x...", payment: payment, amount: 50_000_000,
    #     nonce: nonce, contract_address: resp[:rail0Contract],
    #     token_domain: Rail0::Signing::TokenDomain.new(**resp[:signingPayload][:domain])
    #   ))
    #   client.payments.sign(resp[:paymentId], v: sig.v, r: sig.r, s: sig.s)
    #   client.payments.authorize(resp[:paymentId])
    #
    # @param params [SignPaymentParams]
    # @return [Eip3009Signature]
    def self.sign_authorize(params)
      do_sign(
        params.private_key, params.token_domain,
        from:         params.payment[:payer],
        to:           params.contract_address,
        value:        params.amount,
        valid_after:  0,
        valid_before: params.payment[:authorizationExpiry],
        nonce:        params.nonce
      )
    end

    # Sign the EIP-3009 payload required by a charge call.
    #
    #   resp  = client.payments.create_payment(
    #     payment: payment, amount: "25000000", chain_id: chain_id, mode: "charge"
    #   )
    #   nonce = resp[:signingPayload][:message][:nonce]
    #   sig   = Rail0::Signing.sign_charge(Rail0::Signing::SignPaymentParams.new(
    #     private_key: "0x...", payment: payment, amount: 25_000_000,
    #     nonce: nonce, contract_address: resp[:rail0Contract],
    #     token_domain: Rail0::Signing::TokenDomain.new(**resp[:signingPayload][:domain])
    #   ))
    #   client.payments.sign(resp[:paymentId], v: sig.v, r: sig.r, s: sig.s)
    #   client.payments.charge(resp[:paymentId])
    #
    # @param params [SignPaymentParams]
    # @return [Eip3009Signature]
    def self.sign_charge(params)
      do_sign(
        params.private_key, params.token_domain,
        from:         params.payment[:payer],
        to:           params.contract_address,
        value:        params.amount,
        valid_after:  0,
        valid_before: params.payment[:authorizationExpiry],
        nonce:        params.nonce
      )
    end
  end
end
