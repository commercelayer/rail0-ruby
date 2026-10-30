# frozen_string_literal: true

require_relative "tx_verify"

module Rail0
  # Pre-sign verification of a payout's +unsigned_transaction+ — {Rail0::TxVerify}'s
  # counterpart for the merchant payout (POST /payouts/prepare).
  #
  # A payout is not a RAIL0 call: it is a plain ERC-20 +transfer(address,uint256)+ from the
  # merchant's wallet, addressed to the TOKEN contract. For a plain transfer the calldata IS
  # the money, so nothing in it may be skipped: a gateway endpoint that answered with
  # +approve(attacker, MAX)+, a transfer to another address, a larger amount, another token
  # or another chain would otherwise have the merchant's key sign it. Every check below runs
  # on data the caller already holds, before the key touches the transaction. In order:
  #
  # 1. the JSON parses;
  # 2. +value+ is zero — an ERC-20 transfer attaches no native currency;
  # 3. +chain_id+ is the payout's +chain_id+;
  # 4. +from+, when present, is the signing key's address;
  # 5. +to+ is an address and is the payout's +token+ (case-insensitive) — an empty +to+
  #    would be a contract creation and always refuses;
  # 6. +data+ is EXACTLY +0xa9059cbb+ ++ abi(address = the payout's +address+, uint256 = the
  #    payout's base-unit +amount+), nothing trailing.
  #
  # With +destination:+ (the record the merchant registered, from
  # {Resources::PayoutDestinations#get}) the payout itself is first held to it: same
  # destination id, chain, token and recipient address — so a payout "for" this destination
  # that pays elsewhere refuses. With +amount:+ (the human decimal the caller asked
  # {Resources::Payouts#prepare} for, not "all") the payout's base-unit amount must be exactly
  # that amount scaled by +decimals:+.
  #
  # FAIL-CLOSED: a payout record missing its chain_id, token, address or a base-unit amount,
  # or an explicit +amount:+ without +decimals:+, refuses rather than skips. A refusal raises
  # {Rail0::TxVerify::RefusedSignature} ("refusing to sign: …", naming the field).
  #
  # Mirrors rail0-admin's lib/onchain-guard.ts (+assertTxTarget+ with a transfer, and
  # +assertTransferCall+). Loaded by +rail0/signing+, never by +require "rail0"+ alone.
  module PayoutVerify
    # The 4-byte selector of ERC-20 +transfer(address,uint256)+ — keccak256 of that
    # signature, pinned in the spec.
    TRANSFER_SELECTOR = "a9059cbb"

    # The one function a payout may call.
    TRANSFER_SIGNATURE = "transfer(address,uint256)"

    WORD_HEX = 64
    private_constant :WORD_HEX

    # Verifies +unsigned_transaction+ against +payout+ (and +destination+ / +amount+ when
    # given), BEFORE any key touches it. Raises {Rail0::TxVerify::RefusedSignature} on the
    # first mismatch; returns the parsed, string-keyed transaction otherwise.
    #
    # @param unsigned_transaction [String, Hash] the payout's +unsigned_transaction+
    # @param payout [Hash] the prepared payout (+chain_id+, +token+, +address+, +amount+)
    # @param destination [Hash, nil] the registered destination the payout must be for
    # @param amount [String, nil] the human decimal passed to prepare; nil or "all" skips
    #   only this comparison (the gateway chose the amount: a proof, or the balance)
    # @param decimals [Integer, nil] the token's decimals, required with an explicit +amount+
    # @param signer [String, nil] the address of the key about to sign, or nil to skip
    # @return [Hash] the transaction, string-keyed
    def self.verify(unsigned_transaction, payout:, destination: nil, amount: nil, decimals: nil, signer: nil)
      tx  = parse(unsigned_transaction)
      pay = payout_fields(payout)
      check_destination(pay, destination) unless destination.nil?
      check_amount(pay[:amount], amount, decimals)
      check_header(tx, pay, signer)
      check_call(tx["data"], pay[:address], pay[:amount])
      tx
    end

    def self.parse(unsigned_transaction)
      refuse("the payout carries no unsigned transaction") if blank?(unsigned_transaction)
      tx = unsigned_transaction.is_a?(String) ? JSON.parse(unsigned_transaction) : unsigned_transaction
      refuse("the unsigned transaction is not an object") unless tx.is_a?(Hash)
      tx.transform_keys(&:to_s)
    rescue JSON::ParserError => e
      refuse("the gateway's unsigned transaction is not valid JSON: #{e.message}")
    end

    # The payout fields the transaction is held to. Every one is required: for a plain
    # transfer there is nothing else to compare against.
    def self.payout_fields(payout)
      refuse("cannot check the transaction without the payout it is for") unless payout.is_a?(Hash)
      p = symbolize(payout)
      refuse("the payout's chain_id is unknown, so the chain cannot be checked") unless decimal?(p[:chain_id])
      refuse("the payout's token is not an address, so the transfer cannot be checked") unless address?(p[:token])
      refuse("the payout's address is not an address, so the transfer cannot be checked") unless address?(p[:address])
      refuse("the payout's amount is not base units, so the transfer cannot be checked") unless decimal?(p[:amount])

      { id: p[:id], destination_id: p[:destination_id], chain_id: Integer(p[:chain_id].to_s, 10),
        token: p[:token], address: p[:address], amount: Integer(p[:amount].to_s, 10) }
    end

    private_class_method :parse, :payout_fields

    # The payout must be FOR the destination the merchant registered: the gateway answers
    # both, but the destination is the record the merchant typed and confirmed, so a payout
    # that disagrees with it is one stitched from somewhere else.
    def self.check_destination(pay, destination)
      refuse("the destination is not a record") unless destination.is_a?(Hash)
      d = symbolize(destination)
      check_destination_id(pay[:destination_id], d[:id])
      unless decimal?(d[:chain_id]) && Integer(d[:chain_id].to_s, 10) == pay[:chain_id]
        refuse("the payout is on chain #{pay[:chain_id]} but the destination is on chain #{d[:chain_id].inspect}")
      end
      unless same_address?(d[:token], pay[:token])
        refuse("the payout moves token #{pay[:token]} but the destination is for #{d[:token].inspect}")
      end
      return if same_address?(d[:address], pay[:address])

      refuse("the payout pays #{pay[:address]} but the destination's address is #{d[:address].inspect}")
    end

    def self.check_destination_id(got, want)
      return if blank?(got) || blank?(want) || got.to_s == want.to_s

      refuse("the payout is for destination #{got} but you asked for #{want}")
    end

    # The caller's own amount, scaled locally, against the payout's base-unit amount. "all"
    # and nil leave the amount to the gateway (the balance after the reserve, or the proof).
    def self.check_amount(payout_units, amount, decimals)
      return if blank?(amount) || amount.to_s.strip.casecmp("all").zero?

      if decimals.nil?
        refuse("the token's decimals are unknown, so the payout amount #{amount.to_s.inspect} cannot be checked")
      end
      want = Integer(TxVerify.to_base_units(amount.to_s, Integer(decimals)), 10)
      return if want == payout_units

      refuse("the payout moves #{payout_units} base units but you asked for #{want}")
    end

    private_class_method :check_destination, :check_destination_id, :check_amount

    # Checks 2-5: the fields outside the calldata.
    def self.check_header(fields, pay, signer)
      unless TxVerify.zero_native_value?(fields["value"])
        refuse("transaction attaches native currency (value=#{fields['value'].inspect}); an ERC-20 transfer is value-0")
      end
      unless decimal?(fields["chain_id"]) && Integer(fields["chain_id"].to_s, 10) == pay[:chain_id]
        refuse("transaction targets chain #{fields['chain_id'].inspect} but this payout is on chain #{pay[:chain_id]}")
      end
      from = fields["from"].to_s
      if signer && !from.empty? && !same_address?(from, signer)
        refuse("transaction is prepared from #{from} but the signing key is #{signer}")
      end

      to = fields["to"].to_s.strip
      refuse("the transaction has no `to` address; signing it would deploy a contract") if to.empty?
      refuse("the transaction's `to` #{to.inspect} is not an address") unless address?(to)
      return if same_address?(to, pay[:token])

      refuse("transaction is addressed to #{to} but this payout's token is #{pay[:token]}")
    end

    # Check 6: the calldata, decoded word by word so the refusal names what differs, then
    # its length — a transfer is exactly selector + two words, and anything appended is
    # refused rather than ignored (the token would ignore it; the signature would not).
    def self.check_call(data, address, units)
      raw = data.to_s.strip.downcase.delete_prefix("0x")
      refuse("calldata is not hex") unless raw.match?(/\A\h*\z/)
      refuse("calldata is #{raw.length} hex chars, too short to carry a function selector") if raw.length < 8
      selector = raw[0, 8]
      unless selector == TRANSFER_SELECTOR
        refuse("the call is selector 0x#{selector}, not #{TRANSFER_SIGNATURE} (0x#{TRANSFER_SELECTOR})")
      end
      want_len = 8 + (2 * WORD_HEX)
      refuse("calldata is #{raw.length} hex chars, too short for #{TRANSFER_SIGNATURE}") if raw.length < want_len

      recipient = raw[8, WORD_HEX]
      want_recipient = address.downcase.delete_prefix("0x").rjust(WORD_HEX, "0")
      unless recipient == want_recipient
        refuse("the transfer pays 0x#{recipient[-40..]} but the payout destination is #{address}")
      end
      got_units = raw[8 + WORD_HEX, WORD_HEX].to_i(16)
      refuse("the transfer moves #{got_units} base units but the payout is for #{units}") unless got_units == units
      return if raw.length == want_len

      refuse("calldata carries #{(raw.length - want_len) / 2} trailing bytes after #{TRANSFER_SIGNATURE}")
    end

    private_class_method :check_header, :check_call

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

    def self.address?(value)
      TxVerify.address?(value)
    end

    def self.same_address?(left, right)
      address?(left) && address?(right) && left.casecmp(right).zero?
    end

    private_class_method :refuse, :symbolize, :blank?, :decimal?, :address?, :same_address?
  end
end
