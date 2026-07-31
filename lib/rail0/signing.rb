# frozen_string_literal: true

require "json"

begin
  original_verbose = $VERBOSE
  $VERBOSE = nil
  require "eth"
rescue LoadError => e
  raise e,
    "Rail0::Signing requires the 'eth' gem. Add `gem 'eth', '~> 0.5'` to your Gemfile."
ensure
  $VERBOSE = original_verbose
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
  #   resp = client.payments.create(chain_id: 84532, mode: "authorize", amount: "100.00", token: "0x...", payer: "0x...", payee: "0x...")
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
        unless r.start_with?("0x") && s.start_with?("0x")
          raise ArgumentError, "r and s must be 0x-prefixed hex strings"
        end

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

    # DEPRECATED — the parameter object of the removed {sign_authorize} /
    # {sign_charge}. Kept only so existing code reaches those methods' migration
    # message instead of a NameError while building their arguments; nothing in this
    # SDK consumes it. Use {sign_payload} with the gateway's `signing_payload`.
    SignPaymentParams = Struct.new(
      :private_key, :payment, :nonce, :contract_address, :token_domain,
      keyword_init: true
    )

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

    # Primary types the gateway can ask us to sign. Which one a payment needs is
    # the gateway's business: it builds its client per-payment with the deployment's
    # contract_version, and the version selects the typehash, the domain and the
    # field layout.
    PRIMARY_TYPES = {
      "TransferWithAuthorization" => TRANSFER_TYPEHASH,
      "ReceiveWithAuthorization"  => RECEIVE_TYPEHASH
    }.freeze
    private_constant :PRIMARY_TYPES

    # Resolve a payload's primaryType to its typehash, or refuse.
    #
    # NEVER guess. This used to be a ternary that fell back to the Transfer
    # typehash for anything that wasn't the exact string "ReceiveWithAuthorization"
    # — including a nil, a typo, or a primary type introduced by a newer gateway.
    # The result is a perfectly well-formed signature over the WRONG digest: the
    # call reports success, and the failure surfaces only on-chain, after gas,
    # where it looks like a bad key. An unknown type means this SDK is older than
    # the gateway it is talking to, which is a diagnosable condition. (#7)
    def self.typehash_for(primary_type)
      PRIMARY_TYPES.fetch(primary_type.to_s) do
        raise ArgumentError,
              "unsupported signing payload primaryType #{primary_type.inspect} " \
              "(expected one of #{PRIMARY_TYPES.keys.join(', ')}) — this SDK is older " \
              "than the gateway it is talking to; upgrade rail0-ruby"
      end
    end

    # Accept a payload whose keys are Strings as well as Symbols: callers who parse
    # the gateway's JSON themselves get string keys, and every lookup here is by
    # symbol. Silently returning nils for a string-keyed payload is how a caller
    # ends up signing a digest full of blanks.
    def self.symbolize(hash)
      raise ArgumentError, "signing payload must be a Hash, got #{hash.class}" unless hash.is_a?(Hash)

      hash.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
    end

    private_class_method :typehash_for, :symbolize

    def self.hex_to_bytes(hex)
      h = hex.start_with?("0x") ? hex[2..] : hex
      [h].pack("H*")
    end

    def self.abi_address(address)
      "\x00" * 12 + hex_to_bytes(address)
    end

    def self.uint256_to_bytes32(value)
      hex = Integer(value).to_s(16).rjust(64, "0")
      [hex].pack("H*")
    end

    def self.bytes_to_hex(bytes)
      "0x" + bytes.unpack1("H*")
    end

    private_class_method :hex_to_bytes, :abi_address, :uint256_to_bytes32, :bytes_to_hex

    def self.hash_domain(domain)
      Eth::Util.keccak256(
        DOMAIN_TYPEHASH +
        Eth::Util.keccak256(domain.name) +
        Eth::Util.keccak256(domain.version) +
        uint256_to_bytes32(domain.chain_id) +
        abi_address(domain.verifying_contract)
      )
    end

    def self.hash_struct(from:, to:, value:, valid_after:, valid_before:, nonce:, typehash:)
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

    def self.build_digest(domain, from:, to:, value:, valid_after:, valid_before:, nonce:, typehash:)
      Eth::Util.keccak256(
        "\x19\x01" +
        hash_domain(domain) +
        hash_struct(from: from, to: to, value: value, valid_after: valid_after,
                    valid_before: valid_before, nonce: nonce, typehash: typehash)
      )
    end

    private_class_method :hash_domain, :hash_struct, :build_digest

    # Resolve whatever the caller passed into something that can sign a digest.
    #
    # The seam exists so the raw secret does not have to be materialised as a Ruby
    # String in the calling process: pass a private-key String (unchanged), an
    # Eth::Key, or ANY object responding to #sign(digest) -> 65-byte hex — a KMS or
    # HSM client, a remote signer, a hardware wallet bridge. This SDK builds the
    # EIP-712 digest and hands only that over; it never needs the key material
    # itself, which is what makes "the server must never hold the buyer's key"
    # implementable rather than aspirational. (#10)
    def self.signer_for(private_key)
      return private_key if private_key.respond_to?(:sign)

      unless private_key.is_a?(String)
        raise ArgumentError,
              "expected a private key String or an object responding to #sign(digest), " \
              "got #{private_key.class}"
      end

      Eth::Key.new(priv: private_key.delete_prefix("0x"))
    end

    private_class_method :signer_for

    def self.do_sign(private_key, domain, from:, to:, value:, valid_after:, valid_before:, nonce:, typehash:)
      digest = build_digest(domain, from: from, to: to, value: value, valid_after: valid_after, valid_before: valid_before, nonce: nonce, typehash: typehash)

      sig       = signer_for(private_key).sign(digest)
      sig_bytes = [sig.to_s.delete_prefix("0x")].pack("H*")

      # A custom signer that returns something else would otherwise produce a
      # signature with v: nil, which only fails later in #to_hex with nothing
      # pointing at the signer.
      unless sig_bytes.bytesize == 65
        raise ArgumentError,
              "the signer returned #{sig_bytes.bytesize} bytes, expected 65 " \
              "(r || s || v as hex)"
      end

      Eip3009Signature.new(
        v: sig_bytes.getbyte(64),
        r: bytes_to_hex(sig_bytes[0, 32]),
        s: bytes_to_hex(sig_bytes[32, 32])
      )
    end

    private_class_method :do_sign

    # Build and sign the EIP-1559 (type-2) transaction described by a prepare
    # step's +unsigned_transaction+ and return the signed raw transaction as a
    # 0x-prefixed hex string, ready for the matching submit call.
    #
    # The gateway never holds private keys: it returns the transaction *fields*
    # (chain id, nonce, to, value, data, gas, fees) and the client assembles and
    # signs the transaction locally.
    #
    #   tx  = client.payments.authorize_prepare(rail0_id)
    #   raw = Rail0::Signing.sign_transaction(tx[:unsigned_transaction], PAYER_PRIVATE_KEY)
    #   client.payments.authorize(rail0_id, { signed_transaction: raw })
    #
    # @param unsigned_transaction [String, Hash] The +unsigned_transaction+ JSON
    #   string from a prepare response (a pre-parsed Hash is also accepted).
    # @param private_key [String] Signer's private key (0x-prefixed or raw hex).
    # @return [String] 0x-prefixed RLP-encoded signed transaction.
    def self.sign_transaction(unsigned_transaction, private_key)
      f = unsigned_transaction.is_a?(String) ? JSON.parse(unsigned_transaction) : unsigned_transaction
      f = f.transform_keys(&:to_s)

      tx = Eth::Tx.new(
        chain_id:     Integer(f.fetch("chain_id")),
        nonce:        Integer(f.fetch("nonce")),
        priority_fee: Integer(f.fetch("max_priority_fee_per_gas")),
        max_gas_fee:  Integer(f.fetch("max_fee_per_gas")),
        gas_limit:    Integer(f.fetch("gas_limit")),
        to:           f.fetch("to"),
        value:        Integer(f["value"] || 0),
        data:         f["data"].to_s
      )

      # Deliberately narrower than the digest signers above: Eth::Tx#sign needs a
      # full Eth::Key (it asks for an EIP-155 v derived from the chain id, not a bare
      # digest signature), so an arbitrary #sign(digest) object cannot serve here.
      # An Eth::Key is accepted so a caller holding one doesn't have to export it
      # back to a String.
      tx.sign(private_key.is_a?(Eth::Key) ? private_key : Eth::Key.new(priv: private_key.delete_prefix("0x")))
      "0x#{tx.hex}"
    end

    # Sign the EIP-3009 payload using the signing_payload returned by POST /payments.
    #
    # This is the simplest entry point: pass the full signing_payload from the create response
    # and a private key — all fields are read directly from the payload without any manual
    # reconstruction. (The payload's inner domain/message keep EIP-712 camelCase — chainId,
    # verifyingContract, validAfter, validBefore — which this reads directly.)
    #
    #   resp = client.payments.create(
    #     chain_id: 84532, mode: "authorize",
    #     amount: "100.00", token: "0x...", payer: "0x...", payee: "0x..."
    #   )
    #   sig = Rail0::Signing.sign_payload(BUYER_PRIVATE_KEY, resp[:signing_payload])
    #   client.payments.sign(resp[:rail0_id], { signature: sig.to_hex })
    #
    # @param private_key [String] Payer's private key (0x-prefixed hex).
    # @param signing_payload [Hash] The signingPayload hash from the create response.
    # @return [Eip3009Signature]
    def self.sign_payload(private_key, signing_payload)
      payload = symbolize(signing_payload)
      d = symbolize(payload[:domain])
      m = symbolize(payload[:message])

      domain = TokenDomain.new(
        name:               d[:name],
        version:            d[:version],
        chain_id:           d[:chainId],
        verifying_contract: d[:verifyingContract]
      )

      th = typehash_for(payload[:primaryType])

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
        nonce:        params.nonce,
        # Explicit, not defaulted: this method is BY NAME the transferWithAuthorization
        # one. Removing the default from do_sign means no path can inherit a typehash
        # it never asked for.
        typehash:     TRANSFER_TYPEHASH
      )
    end

    # REMOVED — see {sign_payload}.
    #
    # These two rebuilt the EIP-3009 digest from a payment record: they read
    # from/value/validBefore off the payment, hardcoded `validAfter = 0` and `to =
    # the RAIL0 contract`, and took do_sign's default (Transfer) typehash. That
    # re-imports into the client the contract versioning the gateway exists to
    # absorb — only the gateway knows which contract version a given payment lives
    # on, and the version selects the typehash, the domain AND the field layout.
    #
    # The cost is invisible until it is expensive: rail0#58 moves authorize/charge
    # to ReceiveWithAuthorization, at which point {sign_payload} follows the gateway
    # by construction while these two would keep signing the old typehash — a valid
    # signature over a digest the token refuses, reported as success, failing
    # on-chain after gas.
    #
    # They raise rather than being deleted outright so the migration path arrives
    # with the failure instead of a bare NoMethodError. (#7)
    REMOVED_MESSAGE =
      "Rail0::Signing.%s was removed: it rebuilt the EIP-3009 digest from a payment " \
      "record, which signs the WRONG digest as soon as the contract's payload changes " \
      "(rail0#58 moves authorize/charge to ReceiveWithAuthorization). Use " \
      "Rail0::Signing.sign_payload(private_key, create_response[:signing_payload]) — " \
      "the gateway builds the payload, clients sign it verbatim."
    private_constant :REMOVED_MESSAGE

    def self.sign_authorize(_params = nil)
      raise NotImplementedError, format(REMOVED_MESSAGE, "sign_authorize")
    end

    def self.sign_charge(_params = nil)
      raise NotImplementedError, format(REMOVED_MESSAGE, "sign_charge")
    end
  end
end
