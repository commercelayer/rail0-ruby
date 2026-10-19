# frozen_string_literal: true

require "spec_helper"
require "rail0/signing"

# sign_transaction used to sign whatever the gateway returned. These pin the checks that
# now run before the key touches the transaction — ported from the CLI's
# cmd/tx_verify_test.go, which is the reference for what must pass and what must refuse.
RSpec.describe Rail0::TxVerify do
  # Anvil/Hardhat deterministic test key #0 — never use in production.
  VERIFY_KEY    = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  VERIFY_SIGNER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  let(:rail0_id)    { "0xa1b2c3d40000000000000000000000000000000000000000000000000000beef" }
  let(:contract)    { "0x2222222222222222222222222222222222222222" }
  let(:chain_id)    { 84532 }
  let(:payment)     { { chain_id: chain_id, rail0_id: rail0_id, rail0_contract: contract, decimals: 6 } }

  # RAIL0 calldata the way the ABI lays it out: selector, paymentId, the six inline
  # Payment words (zeros — their content is not checked), then any trailing arguments.
  def calldata_for(operation, payment_id = rail0_id, amount_units = nil)
    key  = described_class.canonical_operation(operation)
    data = "0x#{described_class::SELECTORS.fetch(key)}#{payment_id.delete_prefix('0x').downcase}#{'0' * (64 * 6)}"
    data += Integer(amount_units, 10).to_s(16).rjust(64, "0") if amount_units
    data += "0" * (64 * 3) if key == "refund" # v, r, s
    data
  end

  def unsigned(operation: "void", **overrides)
    {
      chain_id: chain_id, from: VERIFY_SIGNER, to: contract, value: 0, data: calldata_for(operation),
      nonce: 7, gas_limit: 200_000, max_priority_fee_per_gas: 1_000_000, max_fee_per_gas: 2_000_000_000
    }.merge(overrides).to_json
  end

  def verify(unsigned_tx, operation: "void", amount: nil, pay: payment, signer_address: VERIFY_SIGNER)
    described_class.verify(unsigned_tx, payment: pay, operation: operation, amount: amount, signer: signer_address)
  end

  # The selectors are pinned against RAIL0.sol's compiled methodIdentifiers
  # (rail0/contracts/out/RAIL0.sol/RAIL0.json), not against the table they are computed
  # from — a typo in a signature string would otherwise agree with itself.
  describe "SELECTORS" do
    it "match the contract ABI" do
      expect(described_class::SELECTORS).to eq(
        "authorize"     => "c36c951c",
        "charge"        => "1eddc5e5",
        "capture"       => "11bf1806",
        "void"          => "69438554",
        "release"       => "955b0ee2",
        "refund"        => "e8ed339d",
        "dispute"       => "eebaa720",
        "close_dispute" => "6e6923ab"
      )
    end
  end

  describe ".canonical_operation" do
    it "folds the method, label and wire vocabularies onto the wire name" do
      ["close_dispute", "closeDispute", "close dispute", " Close-Dispute ", :close_dispute].each do |v|
        expect(described_class.canonical_operation(v)).to eq("close_dispute")
      end
      expect(described_class.canonical_operation(:capture)).to eq("capture")
    end
  end

  describe ".verify" do
    it "accepts the right call for each operation" do
      %w[authorize charge void release dispute close_dispute].each do |op|
        expect { verify(unsigned(operation: op), operation: op) }.not_to raise_error
      end
      %w[capture refund].each do |op|
        tx = unsigned(operation: op, data: calldata_for(op, rail0_id, "1500000"))
        expect { verify(tx, operation: op, amount: "1.5") }.not_to raise_error
      end
    end

    it "compares addresses case-insensitively and accepts the method spelling of the operation" do
      tx = unsigned(operation: "close_dispute", from: VERIFY_SIGNER.upcase, to: contract.upcase)
      expect { verify(tx, operation: :closeDispute) }.not_to raise_error
    end

    it "accepts a pre-parsed Hash, string- or symbol-keyed payment alike" do
      expect { verify(JSON.parse(unsigned), pay: payment.transform_keys(&:to_s)) }.not_to raise_error
    end

    {
      "attaches native currency" => [{ value: 1_000_000_000_000_000_000 }, /attaches native currency/],
      "native value as a hex quantity" => [{ value: "0xde0b6b3a7640000" }, /attaches native currency/],
      "native value as a decimal string" => [{ value: "1" }, /attaches native currency/],
      "wrong chain" => [{ chain_id: 1 }, /targets chain 1 but this payment is on chain 84532/],
      "prepared for a different account" => [{ from: "0x9999999999999999999999999999999999999999" },
                                             /prepared from 0x9999.* but the signing key is/],
      "addressed to another contract" => [{ to: "0x3333333333333333333333333333333333333333" },
                                          /RAIL0 contract is 0x2222/],
      "calldata too short for a selector" => [{ data: "0xdead" }, /too short/],
      "no calldata at all" => [{ data: "" }, /too short/]
    }.each do |name, (overrides, message)|
      it "refuses a hostile transaction: #{name}" do
        expect { verify(unsigned(**overrides)) }
          .to raise_error(Rail0::TxVerify::RefusedSignature, /\Arefusing to sign: .*#{message.source}/m)
      end
    end

    it "refuses calldata that acts on a different payment" do
      tx = unsigned(data: calldata_for("void", "0x#{'ab' * 32}"))
      expect { verify(tx) }.to raise_error(Rail0::TxVerify::RefusedSignature,
                                           /acts on payment 0xabab.* but you asked for 0xa1b2/)
    end

    # The profitable swap: approve(spender, MAX) on the token contract. Its selector is
    # not a RAIL0 one, and its first argument is a left-padded address.
    it "refuses approve(spender, MAX) on the token, by name" do
      tx = unsigned(data: "0x095ea7b3#{'0' * 24}#{'9' * 40}#{'f' * 64}")
      expect { verify(tx) }.to raise_error(Rail0::TxVerify::RefusedSignature, /selector 0x095ea7b3/)
    end

    it "refuses unparseable JSON and non-objects" do
      expect { verify("{not json") }.to raise_error(Rail0::TxVerify::RefusedSignature, /not valid JSON/)
      expect { verify("[]") }.to raise_error(Rail0::TxVerify::RefusedSignature, /not an object/)
    end

    it "accepts every encoding of zero and nothing else" do
      [nil, 0, "0", "0x0", "0X0", " 0 ", ""].each do |value|
        expect { verify(unsigned(value: value)) }.not_to raise_error
      end
      [1, "0x1", "00", "0.0", "-0", "99999999999999999999999999", true].each do |value|
        expect { verify(unsigned(value: value)) }
          .to raise_error(Rail0::TxVerify::RefusedSignature, /attaches native currency/)
      end
    end

    # The swaps the payment-id check alone cannot see: the right payment, the wrong
    # function. Each would have been signed before.
    [
      %w[capture void], %w[void capture 1000000], %w[capture release], %w[release capture 1000000],
      %w[dispute close_dispute], %w[close_dispute dispute], %w[refund capture 1000000]
    ].each do |asked, served, amount|
      it "refuses a swapped operation: asked #{asked}, served #{served}" do
        tx   = unsigned(data: calldata_for(served, rail0_id, amount))
        name = described_class::FUNCTION_SIGNATURES[served].split("(").first
        expect { verify(tx, operation: asked, amount: "1") }
          .to raise_error(Rail0::TxVerify::RefusedSignature, /the call is #{name}\(\) but you asked to #{asked}/)
      end
    end

    it "refuses a capture or refund for an amount other than asked for, naming both" do
      %w[capture refund].each do |op|
        inflated = unsigned(data: calldata_for(op, rail0_id, "999000000"))
        expect { verify(inflated, operation: op, amount: "1") }
          .to raise_error(Rail0::TxVerify::RefusedSignature, /999000000 base units but you asked for 1000000/)

        short = calldata_for(op)
        short = short[0...-(64 * 3)] if op == "refund"
        expect { verify(unsigned(data: short), operation: op, amount: "1") }
          .to raise_error(Rail0::TxVerify::RefusedSignature, /too short to carry the #{op} amount/)
      end
    end

    it "fails closed on what it cannot compare" do
      capture = unsigned(data: calldata_for("capture", rail0_id, "1000000"))
      expect { verify(capture, operation: "capture") }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /cannot check the capture amount without the amount/)
      expect { verify(capture, operation: "capture", amount: "1", pay: payment.merge(decimals: nil)) }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /decimals are unknown/)
      expect { verify(capture, operation: "capture", amount: "1.0000001") }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /7 decimal places, but this token has 6/)
      expect { verify(capture, operation: "capture", amount: "lots") }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /not a decimal number/)
      expect { verify(unsigned, operation: "approve") }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /no known RAIL0 function for operation "approve"/)
      expect { verify(unsigned, pay: nil) }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /without the payment/)
    end

    it "skips what the payment record cannot support, but never the value or `to` check" do
      bare = { rail0_contract: contract }
      expect { verify(unsigned, pay: bare, signer_address: nil) }.not_to raise_error
      expect { verify(unsigned(value: 1), pay: bare, signer_address: nil) }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /attaches native currency/)
      ["", "0x", "not-an-id", "0xabc", nil].each do |id|
        expect { verify(unsigned, pay: bare.merge(rail0_id: id)) }.not_to raise_error
      end
    end

    # S1: an empty `to` used to SKIP the contract comparison, and Eth::Tx signs a
    # transaction with no recipient as a contract creation — the calldata would run as
    # init code deployed from the merchant's key.
    [nil, "", "  "].each do |to|
      it "refuses a transaction with no recipient (to: #{to.inspect}), which would deploy a contract" do
        expect { verify(unsigned(to: to)) }
          .to raise_error(Rail0::TxVerify::RefusedSignature, /\Arefusing to sign: .*no `to` address.*deploy a contract/)
      end
    end

    it "refuses a transaction with the `to` key absent altogether" do
      tx = JSON.parse(unsigned).except("to")
      expect { verify(tx) }.to raise_error(Rail0::TxVerify::RefusedSignature, /no `to` address/)
    end

    ["0x1234", "2222222222222222222222222222222222222222", "0x#{'g' * 40}", 42].each do |to|
      it "refuses a `to` that is not an address: #{to.inspect}" do
        expect { verify(unsigned(to: to)) }.to raise_error(Rail0::TxVerify::RefusedSignature, /is not an address/)
      end
    end

    it "requires the payment's rail0_contract instead of skipping the `to` comparison" do
      [payment.except(:rail0_contract), payment.merge(rail0_contract: ""), payment.merge(rail0_contract: nil)].each do |pay|
        expect { verify(unsigned, pay: pay) }
          .to raise_error(Rail0::TxVerify::RefusedSignature, /without the payment's rail0_contract/)
      end
    end

    it "names the operation before the payment id when both are wrong" do
      tx = unsigned(data: calldata_for("capture", "0x#{'ab' * 32}", "1"))
      expect { verify(tx) }.to raise_error(Rail0::TxVerify::RefusedSignature, /the call is capture\(\)/)
    end
  end

  describe "Rail0::Signing.sign_transaction with payment:/operation:" do
    it "signs a transaction that passes the checks, byte-identical to the blind form" do
      verified = Rail0::Signing.sign_transaction(unsigned, VERIFY_KEY, payment: payment, operation: "void")
      expect(verified).to start_with("0x02")
      expect(verified).to eq(Rail0::Signing.sign_transaction(unsigned, VERIFY_KEY))
    end

    it "refuses before signing, with the key as the expected sender" do
      expect { Rail0::Signing.sign_transaction(unsigned(value: 1), VERIFY_KEY, payment: payment, operation: "void") }
        .to raise_error(Rail0::TxVerify::RefusedSignature)
      other = unsigned(from: "0x9999999999999999999999999999999999999999")
      expect { Rail0::Signing.sign_transaction(other, VERIFY_KEY, payment: payment, operation: "void") }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /the signing key is #{VERIFY_SIGNER}/)
      key = Eth::Key.new(priv: VERIFY_KEY.delete_prefix("0x"))
      expect { Rail0::Signing.sign_transaction(other, key, payment: payment, operation: "void") }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /the signing key is/)
    end

    # A :deprecated-category warning: silent by default (Ruby 2.7.2+), shown under
    # -W:deprecated or Warning[:deprecated] = true — so the blind form keeps working
    # quietly for existing callers while saying what it is to anyone who asks.
    # The blind form skips TxVerify, so the signer refuses a contract creation itself.
    [nil, "", "0x"].each do |to|
      it "refuses to sign a contract creation (to: #{to.inspect}) even in the blind form" do
        was = Warning[:deprecated]
        Warning[:deprecated] = false
        expect { Rail0::Signing.sign_transaction(unsigned(to: to), VERIFY_KEY) }
          .to raise_error(Rail0::TxVerify::RefusedSignature, /\Arefusing to sign: .*not an address/)
        expect { Rail0::Signing.sign_transaction(JSON.parse(unsigned).except("to"), VERIFY_KEY) }
          .to raise_error(Rail0::TxVerify::RefusedSignature, /not an address/)
      ensure
        Warning[:deprecated] = was
      end
    end

    it "signs an upper-case 0X recipient as the same transaction as the lower-case one" do
      upper = Rail0::Signing.sign_transaction(unsigned(to: contract.upcase), VERIFY_KEY,
                                              payment: payment, operation: "void")
      expect(upper).to eq(Rail0::Signing.sign_transaction(unsigned, VERIFY_KEY, payment: payment, operation: "void"))
    end

    it "warns, as a :deprecated category warning, when called blind" do
      was = Warning[:deprecated]
      Warning[:deprecated] = true
      expect { Rail0::Signing.sign_transaction(unsigned, VERIFY_KEY) }
        .to output(/signs the gateway's transaction blindly and is deprecated/).to_stderr
      Warning[:deprecated] = false
      expect { Rail0::Signing.sign_transaction(unsigned, VERIFY_KEY) }.not_to output.to_stderr
    ensure
      Warning[:deprecated] = was
    end
  end
end
