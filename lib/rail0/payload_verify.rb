# frozen_string_literal: true

require_relative "tx_verify"

module Rail0
  # Pre-sign verification of a gateway-built EIP-712 / EIP-3009 +signing_payload+ —
  # {Rail0::TxVerify}'s counterpart for the authorization rather than the transaction.
  #
  # It is the MORE dangerous artifact of the two. A malicious transaction costs gas and
  # goes through RAIL0; an EIP-3009 authorization is a bearer instrument the TOKEN
  # honours directly, with no RAIL0 involvement, for up to +message.value+. An endpoint
  # that answered a refund prepare with +{from: <payee>, to: <attacker>, value: <the
  # payee's whole balance>}+ used to get exactly that signed by {Signing.sign_payload},
  # and could replay it against the token.
  #
  # Ported from the rail0 CLI's cmd/tx_verify.go (+verifySigningPayload+), which is the
  # reference for the checks, their order and the wording. In order:
  #
  # 1. +message.from+ is the signing key's address — the one comparison whose right-hand
  #    side is derived locally from the key, so it holds whatever the endpoint claims;
  # 2. +domain.chainId+ is the payment's +chain_id+;
  # 3. +domain.verifyingContract+ is the payment's +token+ (for EIP-3009 the domain IS
  #    the token: this stops an authorization minted against another token the signer
  #    happens to hold);
  # 4. +message.to+ is the payment's +rail0_contract+ — a consistency check, the address
  #    comes from the same gateway;
  # 5. +message.value+ is EXACTLY the amount asked for, in base units — not a ceiling:
  #    the gateway asks for the full amount of the operation.
  #
  # Before those, the typed-data envelope: +primaryType+ is one of the two EIP-3009
  # authorization types, +types[primaryType]+ is EXACTLY the EIP-3009 field list (names,
  # types, order), +types.EIP712Domain+ (when present) is exactly the token domain's
  # field list, and +types+ defines nothing else. {Signing.sign_payload} hashes with
  # fixed typehashes and would not notice, but a browser wallet hashes whatever +types+
  # says — so a caller that verifies here and then hands the payload to
  # +eth_signTypedData_v4+ needs it.
  #
  # The payload is still signed VERBATIM: the typehash comes from its own +primaryType+
  # and the digest from its own message. This only refuses a message whose fields
  # contradict what the caller asked for. Like the CLI, it does not check the
  # validity window, or +message.nonce+ — recomputing the nonce needs the deployment's
  # VERSION(), which no payment response carries. The bounded residual is an
  # authorization for the RIGHT token, on the RIGHT chain, from the RIGHT signer, for
  # EXACTLY the amount asked for.
  #
  # FAIL-CLOSED where the CLI is: the amount check never skips (no amount and no stored
  # base-unit amount, or unknown decimals, refuses). The CLI skips a check whose
  # expectation it could not resolve; here every expectation comes from the payment
  # record the caller passes, which always carries chain_id, token and rail0_contract,
  # so a record missing one of them refuses rather than skipping.
  #
  # Loaded by +rail0/signing+ (TxVerify needs the +eth+ gem), never by +require "rail0"+.
  module PayloadVerify
    # Verifies +signing_payload+ against +payment+, BEFORE any key touches it. Raises
    # {Rail0::TxVerify::RefusedSignature} ("refusing to sign: …", naming the field) on
    # the first mismatch; returns the payload, symbol-keyed, otherwise.
    #
    # @param signing_payload [Hash] the +signing_payload+ of a create, get or refund
    #   prepare response (string or symbol keys)
    # @param payment [Hash] the payment record: +chain_id+, +token+, +rail0_contract+,
    #   and +amount+ (base units) or +decimals+ (to scale +amount:+)
    # @param signer [String] the address of the key about to sign
    # @param amount [String, nil] the human decimal you asked for (a refund's amount).
    #   Scaled by the payment's +decimals+. When nil, the payment's own stored +amount+
    #   (base units) is the expectation — what the payer of a created payment agrees to.
    # @return [Hash] the payload, symbol-keyed
    def self.verify(signing_payload, payment:, signer:, amount: nil)
      sp, domain, message = parse(signing_payload)
      pay = payment_fields(payment)
      refuse("cannot check the authorization without the address of the signing key") if blank?(signer)

      check_typed_data(sp[:primaryType], sp[:types])
      check_from(message[:from], signer.to_s)
      check_chain(domain[:chainId], pay[:chain_id])
      check_address(domain[:verifyingContract], pay[:token], "token") do |got, want|
        "the authorization is against token #{got} but this payment's token is #{want}"
      end
      check_address(message[:to], pay[:rail0_contract], "rail0_contract") do |got, want|
        "the authorization pays #{got} but this payment's RAIL0 contract is #{want}"
      end
      check_value(message[:value], expected_base_units(pay, amount))
      sp
    end

    def self.parse(signing_payload)
      refuse("there is no signing payload to check") unless signing_payload.is_a?(Hash)
      sp = symbolize(signing_payload)
      domain  = sp[:domain]
      message = sp[:message]
      refuse("the signing payload has no domain object") unless domain.is_a?(Hash)
      refuse("the signing payload has no message object") unless message.is_a?(Hash)
      [sp, symbolize(domain), symbolize(message)]
    end

    def self.payment_fields(payment)
      refuse("cannot check the authorization without the payment it is for") unless payment.is_a?(Hash)
      symbolize(payment)
    end

    private_class_method :parse, :payment_fields

    # The EIP-3009 authorization types the gateway emits. Which one a payment needs is the
    # deployment's contract version, which no payment response carries: 1.4.0 and later
    # use ReceiveWithAuthorization for authorize/charge, 1.1.0–1.3.x used
    # TransferWithAuthorization, and refunds are ReceiveWithAuthorization on every
    # version. So both are accepted and nothing else is.
    PRIMARY_TYPES = %w[TransferWithAuthorization ReceiveWithAuthorization].freeze

    # The EIP-3009 struct shared by both types: names, types AND order are the typehash.
    AUTHORIZATION_FIELDS = [
      %w[from address], %w[to address], %w[value uint256],
      %w[validAfter uint256], %w[validBefore uint256], %w[nonce bytes32]
    ].freeze

    # The token's EIP-712 domain, as the gateway declares it and the token hashes it.
    DOMAIN_FIELDS = [
      %w[name string], %w[version string], %w[chainId uint256], %w[verifyingContract address]
    ].freeze

    private_constant :PRIMARY_TYPES, :AUTHORIZATION_FIELDS, :DOMAIN_FIELDS

    # The typed-data envelope: refuses an unknown +primaryType+, a +types[primaryType]+
    # that differs from the EIP-3009 struct in any name, type or position, an
    # +EIP712Domain+ that differs from the token domain, or any further type.
    def self.check_typed_data(primary_type, types)
      unless PRIMARY_TYPES.include?(primary_type)
        refuse("the authorization's primaryType #{primary_type.inspect} is not an EIP-3009 authorization type " \
               "(TransferWithAuthorization or ReceiveWithAuthorization)")
      end
      refuse("the signing payload has no types") unless types.is_a?(Hash)

      types = types.transform_keys(&:to_s)
      extra = types.keys.find { |name| name != primary_type && name != "EIP712Domain" }
      if extra
        refuse("the signing payload's types define #{extra.inspect}, which an EIP-3009 authorization does not use")
      end
      check_type_fields("types.#{primary_type}", types[primary_type], AUTHORIZATION_FIELDS)
      check_type_fields("types.EIP712Domain", types["EIP712Domain"], DOMAIN_FIELDS) if types.key?("EIP712Domain")
    end

    def self.check_type_fields(label, fields, want)
      return if exact_fields?(fields, want)

      expected = want.map { |name, type| "#{type} #{name}" }.join(",")
      refuse("#{label} is (#{describe_fields(fields)}) but must be exactly (#{expected})")
    end

    def self.describe_fields(fields)
      return (fields.nil? ? "null" : fields.inspect) unless fields.is_a?(Array)

      fields.map { |f| f.is_a?(Hash) ? "#{field_of(f, 'type')} #{field_of(f, 'name')}" : f.inspect }.join(",")
    end

    def self.exact_fields?(fields, want)
      fields.is_a?(Array) && fields.size == want.size &&
        fields.each_with_index.all? do |f, i|
          f.is_a?(Hash) && f.size == 2 && field_of(f, "name") == want[i][0] && field_of(f, "type") == want[i][1]
        end
    end

    # A field entry's +name+ / +type+, whether the payload arrived string- or
    # symbol-keyed.
    def self.field_of(field, key)
      field.key?(key) ? field[key] : field[key.to_sym]
    end

    private_class_method :check_typed_data, :check_type_fields, :describe_fields, :exact_fields?, :field_of

    # Check 1: from = the key's own address. An absent +from+ is a mismatch, not a skip.
    def self.check_from(from, signer)
      return if same_address?(from, signer)

      refuse("the authorization is from #{from} but the signing key is #{signer}")
    end

    # Check 2. Both sides may arrive as an Integer or a decimal String.
    def self.check_chain(got, want)
      refuse("cannot check the authorization's chain without the payment's chain_id") if blank?(want)
      return if decimal?(got) && decimal?(want) && Integer(got.to_s, 10) == Integer(want.to_s, 10)

      refuse("the authorization is scoped to chain #{got} but this payment is on chain #{want}")
    end

    # Checks 3 and 4: an address against the payment record's, case-insensitively (the
    # gateway may return checksummed addresses). The block words the mismatch.
    def self.check_address(got, want, field)
      refuse("cannot check the authorization without the payment's #{field}") if blank?(want)
      return if same_address?(got, want)

      refuse(yield(got, want))
    end

    # Check 5: exact equality in base units. A value that is not a plain decimal integer
    # cannot equal one, so it refuses with the same message rather than being coerced
    # (the signer's +to_i+ would read "1000000abc" as 1000000).
    def self.check_value(got, want)
      return if decimal?(got) && Integer(got.to_s, 10) == Integer(want, 10)

      refuse("the authorization is for #{got} base units but you asked for #{want}")
    end

    private_class_method :check_from, :check_chain, :check_address, :check_value

    # The base-unit amount the authorization must carry. The caller's own +amount:+ is
    # the trustworthy side, so it wins and is scaled locally by the payment's decimals;
    # without one, the payment's stored base-unit amount is what is being agreed to.
    # Either way it never returns nil: the whole guard exists for this comparison.
    def self.expected_base_units(pay, amount)
      if blank?(amount)
        stored = pay[:amount]
        return stored.to_s if decimal?(stored)

        refuse("cannot check the authorization's amount without an amount: pass amount: " \
               "or a payment record carrying its base-unit amount")
      end
      if pay[:decimals].nil?
        refuse("the payment's token decimals are unknown, so the authorization's amount cannot be checked " \
               "(fetch the payment with payments.get first)")
      end
      TxVerify.to_base_units(amount.to_s, Integer(pay[:decimals]))
    end

    private_class_method :expected_base_units

    def self.refuse(message)
      raise TxVerify::RefusedSignature, "refusing to sign: #{message}"
    end

    def self.symbolize(hash)
      hash.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
    end

    def self.blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def self.decimal?(value)
      value.is_a?(Integer) ? value >= 0 : value.is_a?(String) && value.match?(/\A\d+\z/)
    end

    # Both sides must be addresses: two blanks (or two identical non-addresses) are not
    # a match.
    def self.same_address?(left, right)
      TxVerify.address?(left) && TxVerify.address?(right) && left.casecmp(right).zero?
    end

    private_class_method :refuse, :symbolize, :blank?, :decimal?, :same_address?
  end
end
