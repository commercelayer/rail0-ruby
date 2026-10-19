# frozen_string_literal: true

require "json"

module Rail0
  # Pre-sign verification of a gateway-built unsigned transaction.
  #
  # +Rail0::Signing.sign_transaction+ used to sign whatever +unsigned_transaction+ a
  # prepare step returned. A hostile or merely misconfigured gateway endpoint could
  # therefore have the merchant's own key sign an arbitrary transaction — an
  # +approve(spender, MAX)+ on the token, a capture answered to a void prepare, a
  # capture for a larger amount than asked. The checks here run on data the caller
  # already holds (the payment record, the operation it asked for, the amount it typed)
  # BEFORE the key touches the transaction, so they add no gateway round-trip. A
  # mismatch raises {RefusedSignature}, whose message starts with "refusing to sign:"
  # and names the field; no signature is produced.
  #
  # Ported from the rail0 CLI's cmd/tx_verify.go (#63), which is the reference for the
  # check order and the fail-closed rules. Loaded by +rail0/signing+ (it needs the
  # +eth+ gem for keccak256), never by +require "rail0"+ alone.
  module TxVerify
    # Raised instead of signing. Deliberately not an ArgumentError: the caller's
    # arguments are fine, it is the GATEWAY's transaction that is not.
    class RefusedSignature < StandardError; end

    # RAIL0.sol's +Payment+ struct as the ABI encodes it: payer, payee, token, amount
    # (uint120), authorizationExpiry and refundExpiry (uint48). All static types, so the
    # tuple is encoded INLINE — six 32-byte words right after the paymentId — which is
    # what fixes the position of the amount argument below.
    PAYMENT_TUPLE = "(address,address,address,uint120,uint48,uint48)"
    private_constant :PAYMENT_TUPLE

    # The eight RAIL0 entry points, keyed by the gateway's wire name for the operation.
    # Copied from RAIL0.sol; the spec pins the derived selectors against the contract's
    # compiled +methodIdentifiers+, so a typo here cannot agree with itself.
    FUNCTION_SIGNATURES = {
      "authorize"     => "authorize(bytes32,#{PAYMENT_TUPLE},uint8,bytes32,bytes32)",
      "charge"        => "charge(bytes32,#{PAYMENT_TUPLE},uint8,bytes32,bytes32)",
      "capture"       => "capture(bytes32,#{PAYMENT_TUPLE},uint256)",
      "void"          => "void(bytes32,#{PAYMENT_TUPLE})",
      "release"       => "release(bytes32,#{PAYMENT_TUPLE})",
      "refund"        => "refund(bytes32,#{PAYMENT_TUPLE},uint256,uint8,bytes32,bytes32)",
      "dispute"       => "dispute(bytes32,#{PAYMENT_TUPLE},bytes32)",
      "close_dispute" => "closeDispute(bytes32,#{PAYMENT_TUPLE},bytes32)"
    }.freeze

    # Operation → the function's 4-byte selector as 8 lowercase hex chars: the first
    # four bytes of keccak256(signature), computed from the table above rather than
    # hand-copied.
    SELECTORS = FUNCTION_SIGNATURES.transform_values do |sig|
      Eth::Util.keccak256(sig)[0, 4].unpack1("H*")
    end.freeze

    # Calldata position (in 32-byte words after the selector) of the +uint256 amount+
    # argument of capture and refund: word 0 is the paymentId, words 1-6 the inline
    # Payment tuple, so the amount is word 7. Only these two operations take an amount.
    AMOUNT_WORD = { "capture" => 7, "refund" => 7 }.freeze
    private_constant :AMOUNT_WORD

    SELECTOR_HEX = 8  # 4-byte selector
    WORD_HEX     = 64 # 32-byte ABI word
    private_constant :SELECTOR_HEX, :WORD_HEX

    # Folds the vocabularies an operation arrives in onto the gateway's wire name:
    # "closeDispute", "close dispute", :close_dispute are one operation.
    def self.canonical_operation(operation)
      operation.to_s.strip
               .gsub(/([a-z0-9])([A-Z])/, '\1_\2')
               .gsub(/[\s-]+/, "_")
               .downcase
    end

    # Verifies a gateway-built +unsigned_transaction+ against what the caller asked for,
    # BEFORE any key touches it. Raises {RefusedSignature} naming the first field that
    # disagrees; returns the parsed, string-keyed transaction otherwise.
    #
    # In order:
    # 1. the JSON parses;
    # 2. +value+ is zero — every RAIL0 operation is value-0, funds move as token
    #    transfers the contract performs, so a non-zero value is the gateway asking for ETH;
    # 3. +chain_id+ is the payment's chain;
    # 4. +from+, when present, is +signer+ (the signing key's address);
    # 5. +to+ is the payment's +rail0_contract+ — a consistency check (the address comes
    #    from the same gateway), but it catches a response stitched from two payments;
    # 6. the 4-byte selector is the RAIL0 function for +operation+, and for capture and
    #    refund the amount word equals +amount+ scaled by the payment's +decimals+;
    # 7. the paymentId word is the payment's +rail0_id+.
    #
    # Every right-hand side is something the caller supplied or derived locally — never
    # the prepare response itself. FAIL-CLOSED on what cannot be compared: an unknown
    # operation, a capture/refund without an +amount+, or a payment with unknown
    # +decimals+ refuses rather than skips. Only the paymentId comparison is skipped,
    # when the payment carries no usable +rail0_id+.
    #
    # @param unsigned_transaction [String, Hash] the prepare response's field-set
    # @param payment [Hash] the payment record (from +payments.create+ / +payments.get+)
    # @param operation [String, Symbol] the operation the prepare was called for
    # @param amount [String, nil] the human decimal passed to the prepare (capture/refund)
    # @param signer [String, nil] the address of the key about to sign, or nil to skip
    # @return [Hash] the transaction, string-keyed
    def self.verify(unsigned_transaction, payment:, operation:, amount: nil, signer: nil)
      tx = parse(unsigned_transaction)
      pay = payment_fields(payment)
      check_header(tx, pay, signer)

      data = tx["data"].to_s
      # The operation before the payment id, so a swapped operation is named as such.
      check_call(data, operation, expected_base_units(pay, operation, amount))
      check_payment_id(data, pay[:rail0_id])
      tx
    end

    # Checks 2-5: the fields outside the calldata.
    def self.check_header(fields, pay, signer)
      unless zero_native_value?(fields["value"])
        refuse("transaction attaches native currency (value=#{fields['value'].inspect}); " \
               "every RAIL0 operation is value-0")
      end

      if pay[:chain_id] && !pay[:chain_id].to_i.zero? && fields["chain_id"].to_s != pay[:chain_id].to_s
        refuse("transaction targets chain #{fields['chain_id']} but this payment is on chain #{pay[:chain_id]}")
      end

      from = fields["from"].to_s
      if signer && !from.empty? && !same_address?(from, signer)
        refuse("transaction is prepared from #{from} but the signing key is #{signer}")
      end

      to = fields["to"].to_s
      return unless pay[:rail0_contract] && !to.empty? && !same_address?(to, pay[:rail0_contract])

      refuse("transaction is addressed to #{to} but this payment's RAIL0 contract is #{pay[:rail0_contract]}")
    end

    def self.parse(unsigned_transaction)
      tx = unsigned_transaction.is_a?(String) ? JSON.parse(unsigned_transaction) : unsigned_transaction
      refuse("the unsigned transaction is not an object") unless tx.is_a?(Hash)
      tx.transform_keys(&:to_s)
    rescue JSON::ParserError => e
      refuse("the gateway's unsigned transaction is not valid JSON: #{e.message}")
    end

    def self.payment_fields(payment)
      refuse("cannot check the transaction without the payment it is for") unless payment.is_a?(Hash)
      p = payment.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
      { chain_id: p[:chain_id], rail0_id: p[:rail0_id], rail0_contract: presence(p[:rail0_contract]),
        decimals: p[:decimals] }
    end

    def self.presence(value)
      s = value.to_s
      s.empty? ? nil : s
    end

    private_class_method :check_header, :parse, :payment_fields, :presence

    def self.refuse(message)
      raise RefusedSignature, "refusing to sign: #{message}"
    end

    # The encodings a zero native value legitimately arrives in — absent, nil, the
    # number 0, or the string "0" / "0x0". A whitelist, deliberately: anything
    # unrecognised must refuse the signature rather than be guessed at.
    def self.zero_native_value?(value)
      case value
      when nil then true
      when Integer then value.zero?
      when String
        s = value.strip
        s.empty? || s == "0" || s.casecmp("0x0").zero?
      else false
      end
    end

    def self.same_address?(left, right)
      left.to_s.casecmp(right.to_s).zero?
    end

    private_class_method :refuse, :zero_native_value?, :same_address?

    # Scales the human amount the CALLER typed by the payment's token decimals, for
    # comparison against the calldata. nil when the operation takes no amount. For one
    # that does, a missing amount or unknown decimals is a refusal — the whole guard
    # exists for that comparison, so it must not be skipped.
    def self.expected_base_units(pay, operation, amount)
      key = canonical_operation(operation)
      return nil unless AMOUNT_WORD.key?(key)

      refuse("cannot check the #{key} amount without the amount you asked for") if amount.to_s.strip.empty?
      if pay[:decimals].nil?
        refuse("the payment's token decimals are unknown, so the #{key} amount cannot be checked " \
               "(fetch the payment with payments.get first)")
      end
      to_base_units(amount.to_s, Integer(pay[:decimals]))
    end

    # String math, no Float: "1.5" at 6 decimals is "1500000". More fractional digits
    # than the token has is a refusal, not a truncation — the gateway 422s such an
    # amount, so dropping digits would compare against a figure never asked for.
    def self.to_base_units(human, decimals)
      s = human.strip
      refuse("amount #{human.inspect} is not a decimal number") unless s.match?(/\A\d+(\.\d+)?\z/)
      whole, frac = s.split(".", 2)
      frac ||= ""
      if frac.length > decimals
        refuse("amount #{human.inspect} has #{frac.length} decimal places, but this token has #{decimals}")
      end
      (whole + frac.ljust(decimals, "0")).sub(/\A0+(?=\d)/, "")
    end

    private_class_method :expected_base_units, :to_base_units

    # Asserts the call is the RAIL0 function for +operation+ and, for capture and refund,
    # that it moves exactly +want_units+ base units.
    #
    # Checking the paymentId alone binds the transaction to the right PAYMENT but not to
    # the right OPERATION: every RAIL0 function takes the paymentId first, so a hostile
    # endpoint could answer a void prepare with capture calldata (settling the escrow
    # to the merchant instead of returning it). The selector closes that; the amount
    # word closes the remaining capture/refund swap — the right function for a
    # different quantity than the caller typed. Fail-closed: no known selector, or an
    # amount-taking operation with nothing local to compare, refuses rather than skips.
    def self.check_call(data, operation, want_units)
      key  = canonical_operation(operation)
      want = SELECTORS[key] || refuse("no known RAIL0 function for operation #{operation.to_s.inspect}")
      raw  = strip_hex(data)
      refuse("calldata is #{raw.length} hex chars, too short to carry a function selector") if raw.length < SELECTOR_HEX
      got = raw[0, SELECTOR_HEX]
      if got != want
        refuse("the call is #{describe_selector(got)} but you asked to #{key} (#{FUNCTION_SIGNATURES[key]})")
      end

      word = AMOUNT_WORD[key]
      return if word.nil?

      refuse("cannot check the #{key} amount without the amount you asked for") if want_units.nil?
      start = SELECTOR_HEX + (word * WORD_HEX)
      if raw.length < start + WORD_HEX
        refuse("calldata is #{raw.length} hex chars, too short to carry the #{key} amount")
      end
      got_int  = raw[start, WORD_HEX].to_i(16)
      want_int = Integer(want_units, 10)
      return if got_int == want_int

      refuse("the call would #{key} #{got_int} base units but you asked for #{want_int}")
    end

    # Names a selector for an error message: the RAIL0 function it belongs to when it
    # is one of ours (the likely shape of a swapped operation), and the bare hex otherwise.
    def self.describe_selector(selector)
      op = SELECTORS.key(selector)
      op ? "#{FUNCTION_SIGNATURES[op].split('(', 2).first}()" : "selector 0x#{selector}"
    end

    # Asserts the call's first argument is THIS payment's id.
    #
    # All eight RAIL0 operations take +bytes32 paymentId+ first, so under ABI encoding
    # the id always occupies bytes 4..36 of the calldata. A hostile gateway's most
    # profitable swap is +approve(spender, MAX)+ on the token contract, which this
    # rejects: approve's first argument is a left-padded address, so it cannot be a
    # rail0_id. Skipped only when there is no usable rail0_id to compare against.
    def self.check_payment_id(data, rail0_id)
      want = strip_hex(rail0_id.to_s)
      return if want.length != WORD_HEX

      raw = strip_hex(data)
      if raw.length < SELECTOR_HEX + WORD_HEX
        refuse("calldata is #{raw.length} hex chars, too short to carry a paymentId")
      end
      got = raw[SELECTOR_HEX, WORD_HEX]
      refuse("the call acts on payment 0x#{got} but you asked for 0x#{want}") if got != want
    end

    def self.strip_hex(hex)
      hex.to_s.strip.downcase.delete_prefix("0x")
    end

    private_class_method :check_call, :describe_selector, :check_payment_id, :strip_hex
  end
end
