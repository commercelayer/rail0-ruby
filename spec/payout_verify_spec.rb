# frozen_string_literal: true

require "spec_helper"
require "rail0/signing"

# A payout is a plain ERC-20 transfer, so its calldata IS the money: these pin every check
# Rail0::PayoutVerify runs before the merchant's key touches a prepared payout, and that
# Rail0::Signing.sign_payout refuses (signs nothing) whenever one fails.
RSpec.describe Rail0::PayoutVerify do
  # Anvil/Hardhat deterministic test key #0 — never use in production.
  PAYOUT_KEY    = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  PAYOUT_SIGNER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

  let(:token)       { "0x3600000000000000000000000000000000000000" }
  let(:recipient)   { "0x9999999999999999999999999999999999999999" }
  let(:chain_id)    { 5042002 }
  let(:units)       { "250000000" } # 250.00 at 6 decimals
  let(:destination) do
    { id: "dest-1", chain_id: chain_id, token: token, address: recipient, status: "verified" }
  end

  def transfer_data(to = recipient, amount = units, selector: "a9059cbb")
    "0x#{selector}#{to.delete_prefix('0x').downcase.rjust(64, '0')}#{Integer(amount, 10).to_s(16).rjust(64, '0')}"
  end

  def unsigned(**overrides)
    {
      chain_id: chain_id, from: PAYOUT_SIGNER, to: token, value: "0", data: transfer_data,
      nonce: 3, gas_limit: 60_000, max_priority_fee_per_gas: 1_000_000, max_fee_per_gas: 2_000_000_000
    }.merge(overrides).to_json
  end

  def payout(**overrides)
    { id: "payout-1", destination_id: "dest-1", chain_id: chain_id, token: token, address: recipient,
      amount: units, amount_formatted: "250", purpose: "payout", status: "pending",
      unsigned_transaction: unsigned }.merge(overrides)
  end

  def verify(pay = payout, **opts)
    described_class.verify(pay[:unsigned_transaction], payout: pay, signer: PAYOUT_SIGNER, **opts)
  end

  def expect_refusal(pattern, &block)
    expect(&block).to raise_error(Rail0::TxVerify::RefusedSignature, /\Arefusing to sign: .*#{pattern}/)
  end

  it "pins the transfer selector to keccak256(\"transfer(address,uint256)\")" do
    expect(Eth::Util.keccak256(described_class::TRANSFER_SIGNATURE)[0, 4].unpack1("H*"))
      .to eq(described_class::TRANSFER_SELECTOR)
  end

  describe ".verify" do
    it "accepts the exact transfer and returns the transaction" do
      expect(verify).to include("to" => token, "data" => transfer_data)
    end

    it "accepts mixed-case addresses, string keys and an integer chain id" do
      pay = payout(token: token.upcase.sub("0X", "0x"), address: recipient)
            .transform_keys(&:to_s)
            .merge("unsigned_transaction" => unsigned(chain_id: chain_id.to_s, to: token.upcase.sub("0X", "0x")))
      expect { described_class.verify(pay["unsigned_transaction"], payout: pay) }.not_to raise_error
    end

    it "accepts it held to the registered destination and the amount asked for" do
      expect { verify(destination: destination, amount: "250.00", decimals: 6) }.not_to raise_error
      expect { verify(destination: destination, amount: "all") }.not_to raise_error
    end

    it "refuses a transfer to another recipient" do
      pay = payout(unsigned_transaction: unsigned(data: transfer_data("0x000000000000000000000000000000000000dEaD")))
      expect_refusal("pays 0x000000000000000000000000000000000000dead") { verify(pay) }
    end

    it "refuses another amount" do
      pay = payout(unsigned_transaction: unsigned(data: transfer_data(recipient, "250000001")))
      expect_refusal("moves 250000001 base units but the payout is for 250000000") { verify(pay) }
    end

    it "refuses another token (the transaction's `to`)" do
      pay = payout(unsigned_transaction: unsigned(to: "0x1111111111111111111111111111111111111111"))
      expect_refusal("addressed to 0x1111111111111111111111111111111111111111 but this payout's token") { verify(pay) }
    end

    it "refuses a non-zero native value" do
      ["1", 1, "0x1", "abc"].each do |value|
        pay = payout(unsigned_transaction: unsigned(value: value))
        expect_refusal("native currency") { verify(pay) }
      end
    end

    it "refuses another chain" do
      pay = payout(unsigned_transaction: unsigned(chain_id: 1))
      expect_refusal("targets chain 1 but this payout is on chain #{chain_id}") { verify(pay) }
    end

    it "refuses trailing bytes after the two arguments" do
      pay = payout(unsigned_transaction: unsigned(data: "#{transfer_data}00000000"))
      expect_refusal("4 trailing bytes") { verify(pay) }
    end

    it "refuses another function (approve) on the token" do
      pay = payout(unsigned_transaction: unsigned(data: transfer_data(selector: "095ea7b3")))
      expect_refusal("selector 0x095ea7b3, not transfer") { verify(pay) }
    end

    it "refuses truncated or non-hex calldata" do
      expect_refusal("too short") { verify(payout(unsigned_transaction: unsigned(data: "0xa9059cbb"))) }
      expect_refusal("not hex") { verify(payout(unsigned_transaction: unsigned(data: "0xzz"))) }
    end

    it "refuses an address word with dirty high bytes" do
      dirty = "0xa9059cbb#{'f' * 24}#{recipient.delete_prefix('0x')}#{Integer(units).to_s(16).rjust(64, '0')}"
      expect_refusal("pays") { verify(payout(unsigned_transaction: unsigned(data: dirty))) }
    end

    it "refuses an empty or malformed `to` (a contract creation)" do
      expect_refusal("no `to` address") { verify(payout(unsigned_transaction: unsigned(to: ""))) }
      expect_refusal("is not an address") { verify(payout(unsigned_transaction: unsigned(to: "0x1234"))) }
    end

    it "refuses a transaction prepared from another address" do
      pay = payout(unsigned_transaction: unsigned(from: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"))
      expect_refusal("prepared from 0x70997970") { verify(pay) }
    end

    it "fails closed on a payout record missing what it is checked against" do
      %i[chain_id token address amount].each do |field|
        expect_refusal("the payout's #{field}") { verify(payout(field => nil)) }
      end
      expect_refusal("no unsigned transaction") { verify(payout(unsigned_transaction: nil)) }
      expect_refusal("not valid JSON") { verify(payout(unsigned_transaction: "{nope")) }
    end

    it "refuses a payout that is not for the registered destination" do
      expect_refusal("pays #{recipient} but the destination's address") do
        verify(destination: destination.merge(address: "0x8888888888888888888888888888888888888888"))
      end
      expect_refusal("moves token") do
        verify(destination: destination.merge(token: "0x1111111111111111111111111111111111111111"))
      end
      expect_refusal("but the destination is on chain") { verify(destination: destination.merge(chain_id: 1)) }
      expect_refusal("for destination dest-1 but you asked for dest-2") { verify(destination: destination.merge(id: "dest-2")) }
    end

    it "refuses a payout for another amount than the one asked for, and fails closed without decimals" do
      expect_refusal("moves 250000000 base units but you asked for 25000000") do
        verify(amount: "25", decimals: 6)
      end
      expect_refusal("decimals are unknown") { verify(amount: "250") }
      expect_refusal("has 7 decimal places") { verify(amount: "1.0000001", decimals: 6) }
    end
  end

  describe "Rail0::Signing.sign_payout" do
    it "signs the verified transfer as an EIP-1559 transaction from the key" do
      raw = Rail0::Signing.sign_payout(payout, PAYOUT_KEY, destination: destination, amount: "250", decimals: 6)
      tx = Eth::Tx.decode(raw)
      expect(tx.chain_id).to eq(chain_id)
      expect(tx.destination.downcase.delete_prefix("0x")).to eq(token.delete_prefix("0x"))
      expect(tx.amount).to eq(0)
      expect(Eth::Util.bin_to_prefixed_hex(tx.payload)).to eq(transfer_data)
      expect(tx.sender.downcase.delete_prefix("0x")).to eq(PAYOUT_SIGNER.downcase.delete_prefix("0x"))
    end

    it "signs nothing when the transfer is refused" do
      pay = payout(unsigned_transaction: unsigned(data: transfer_data("0x000000000000000000000000000000000000dEaD")))
      allow(Eth::Tx).to receive(:new)
      expect { Rail0::Signing.sign_payout(pay, PAYOUT_KEY) }.to raise_error(Rail0::TxVerify::RefusedSignature)
      expect(Eth::Tx).not_to have_received(:new)
    end
  end
end
