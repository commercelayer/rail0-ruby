# frozen_string_literal: true

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
  #
  # ## Typical usage (simplest path)
  #
  #   resp = client.payments.create(chain_id: 84532, mode: "authorize", amount: "100000000", token: "0x...", payer: "0x...", payee: "0x...")
  #   sig  = Rail0::Signing.sign_payload(BUYER_PRIVATE_KEY, resp[:signing_payload])
  #   client.payments.sign(resp[:rail0_id], { signature: sig.to_hex })
  #
  module Signing
    # EIP-712 domain of the ERC-20 token (NOT the RAIL0 contract).
    TokenDomain = Struct.new(:name, :version, :chain_id, :verifying_contract, keyword_init: true)

    # EIP-3009 transferWithAuthorization signature.
    # Call {to_hex} to assemble the 65-byte hex string expected by `PUT /payments/{id}/sign`.
    Eip3009Signature = Struct.new(:v, :r, :s, keyword_init: true) do
      # Encodes the signature as a 0x-prefixed 65-byte hex string (r ++ s ++ v).
      # This is the format expected by the `signature` field of PayerSignatureRequest.
      #
      # @return [String] "0x" + r (32 bytes) + s (32 bytes) + v (1 byte), 132 chars total.
      def to_hex
        "0x#{r[2..]}#{s[2..]}#{v.to_s(16).rjust(2, '0')}"
      end
    end

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
    #
    # The contract hardcodes `validAfter = 0` and `validBefore = payment[:authorizationExpiry]`;
    # these are not configurable by the caller.
    #
    # `payment` must respond to `[:payer]`, `[:authorizationExpiry]`, and `[:amount]`
    # (all present in both PaymentInput and PaymentConfig hashes).
    SignPaymentParams = Struct.new(
      :private_key, :payment, :nonce, :contract_address, :token_domain,
      keyword_init: true
    )

    # ================================================================
    #  EIP-712 type strings
    # ================================================================

    DOMAIN_TYPE   = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    TRANSFER_TYPE = "TransferWithAuthorization(address from,address to,uint256 value," \
                    "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    RECEIVE_TYPE  = "ReceiveWithAuthorization(address from,address to,uint256 value," \
                    "uint256 validAfter,uint256 validBefore,bytes32 nonce)"

    DOMAIN_TYPEHASH   = Eth::Util.keccak256(DOMAIN_TYPE)
    TRANSFER_TYPEHASH = Eth::Util.keccak256(TRANSFER_TYPE)
    RECEIVE_TYPEHASH  = Eth::Util.keccak256(RECEIVE_TYPE)

    private_constant :DOMAIN_TYPE, :TRANSFER_TYPE, :RECEIVE_TYPE,
                     :DOMAIN_TYPEHASH, :TRANSFER_TYPEHASH, :RECEIVE_TYPEHASH

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

    # Pack an arbitrary-precision non-negative integer into 32 big-endian bytes.
    def self.uint256_to_bytes32(value)
      hex = Integer(value).to_s(16).rjust(64, "0")
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

    def self.hash_struct(from:, to:, value:, valid_after:, valid_before:, nonce:, typehash: TRANSFER_TYPEHASH)
      Eth::Util.keccak256(
        typehash +
        abi_address(from) +
        abi_address(to) +
        uint256_to_bytes32(value) +
        uint256_to_bytes32(valid_after) +
        uint256_to_bytes32(valid_before) +
        hex_to_bytes(nonce)
      )
    end

    def self.build_digest(domain, from:, to:, value:, valid_after:, valid_before:, nonce:, typehash: TRANSFER_TYPEHASH)
      Eth::Util.keccak256(
        "\x19\x01" +
        hash_domain(domain) +
        hash_struct(from: from, to: to, value: value, valid_after: valid_after,
                    valid_before: valid_before, nonce: nonce, typehash: typehash)
      )
    end

    private_class_method :hash_domain, :hash_struct, :build_digest

    # ================================================================
    #  Internal sign helper
    # ================================================================

    def self.do_sign(private_key, domain, from:, to:, value:, valid_after:, valid_before:, nonce:, typehash: TRANSFER_TYPEHASH)
      key_hex = private_key.start_with?("0x") ? private_key[2..] : private_key
      key     = Eth::Key.new(priv: key_hex)
      digest  = build_digest(domain, from: from, to: to, value: value, valid_after: valid_after, valid_before: valid_before, nonce: nonce, typehash: typehash)

      # eth 0.5.17+: Eth::Key#sign(blob) — pass the digest directly; the gem does not re-hash it.
      sig       = key.sign(digest)
      sig_bytes = [sig].pack("H*")

      # Ethereum compact signature layout: r (32 bytes) | s (32 bytes) | v (1 byte, 27 or 28).
      Eip3009Signature.new(
        v: sig_bytes.getbyte(64),
        r: bytes_to_hex(sig_bytes[0, 32]),
        s: bytes_to_hex(sig_bytes[32, 32])
      )
    end

    private_class_method :do_sign

    # ================================================================
    #  Public API
    # ================================================================

    # Sign the EIP-3009 payload using the signingPayload returned by POST /payments.
    #
    # This is the simplest entry point: pass the full signingPayload from the create response
    # and a private key — all fields are read directly from the payload without any manual
    # reconstruction.
    #
    #   resp = client.payments.create(
    #     chain_id: 84532, mode: "authorize",
    #     amount: "100000000", token: "0x...", payer: "0x...", payee: "0x..."
    #   )
    #   sig = Rail0::Signing.sign_payload(BUYER_PRIVATE_KEY, resp[:signing_payload])
    #   client.payments.sign(resp[:rail0_id], { signature: sig.to_hex })
    #
    # @param private_key [String] Payer's private key (0x-prefixed hex).
    # @param signing_payload [Hash] The signingPayload hash from the create response.
    # @return [Eip3009Signature]
    def self.sign_payload(private_key, signing_payload)
      d = signing_payload[:domain]
      m = signing_payload[:message]

      domain = TokenDomain.new(
        name:               d[:name],
        version:            d[:version],
        chain_id:           d[:chainId],
        verifying_contract: d[:verifyingContract]
      )

      # Use ReceiveWithAuthorization typehash when primaryType indicates a
      # receiveWithAuthorization call (e.g. refund). Default: TransferWithAuthorization.
      th = signing_payload[:primaryType] == "ReceiveWithAuthorization" ? RECEIVE_TYPEHASH : TRANSFER_TYPEHASH

      do_sign(
        private_key, domain,
        from:         m[:from],
        to:           m[:to],
        value:        m[:value].to_i,
        valid_after:  m[:validAfter].to_i,
        valid_before: m[:validBefore].to_i,
        nonce:        m[:nonce],
        typehash:     th
      )
    end

    # Sign a raw EIP-3009 transferWithAuthorization message.
    #
    # For RAIL0 payment flows prefer {sign_payload} which reads all fields from the
    # API-returned signingPayload. Use this method only when you need full control over
    # the message fields (e.g. integrating with a contract directly).
    #
    # @param private_key [String] Payer's private key (0x-prefixed or raw hex).
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
    # The nonce encodes the RAIL0.AUTHORIZE prefix server-side; pass it from
    # `resp[:signingPayload][:message][:nonce]`. Prefer {sign_payload} when the full
    # signingPayload is available.
    #
    #   resp  = client.payments.create(chain_id: 84532, mode: "authorize", amount: "100000000", token: "0x...", payer: "0x...", payee: "0x...")
    #   nonce = resp[:signingPayload][:message][:nonce]
    #   sig   = Rail0::Signing.sign_authorize(Rail0::Signing::SignPaymentParams.new(
    #     private_key:      "0x...",
    #     payment:          resp[:payment],
    #     nonce:            nonce,
    #     contract_address: resp[:rail0Contract],
    #     token_domain:     Rail0::Signing::TokenDomain.new(**resp[:signingPayload][:domain].transform_keys { |k| k.to_s.gsub(/([A-Z])/) { "_#{$1.downcase}" }.to_sym })
    #   ))
    #   client.payments.sign(resp[:paymentId], { signature: sig.to_hex })
    #
    # @param params [SignPaymentParams]
    # @return [Eip3009Signature]
    def self.sign_authorize(params)
      do_sign(
        params.private_key, params.token_domain,
        from:         params.payment[:payer],
        to:           params.contract_address,
        value:        params.payment[:amount].to_i,
        valid_after:  0,
        valid_before: params.payment[:authorizationExpiry],
        nonce:        params.nonce
      )
    end

    # Sign the EIP-3009 payload required by a charge call.
    #
    # Identical signing logic to {sign_authorize}; the operation distinction is encoded in
    # the nonce prefix by the server (RAIL0.CHARGE vs RAIL0.AUTHORIZE). A charge signature
    # cannot be reused for authorize and vice versa. Prefer {sign_payload} when the full
    # signingPayload is available.
    #
    # @param params [SignPaymentParams]
    # @return [Eip3009Signature]
    def self.sign_charge(params)
      do_sign(
        params.private_key, params.token_domain,
        from:         params.payment[:payer],
        to:           params.contract_address,
        value:        params.payment[:amount].to_i,
        valid_after:  0,
        valid_before: params.payment[:authorizationExpiry],
        nonce:        params.nonce
      )
    end
  end
end
