require "spec_helper"
require "rail0/signing"

RSpec.describe Rail0::Signing do
  # Anvil/Hardhat deterministic test key #0 — never use in production.
  TEST_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  TEST_ADDRESS     = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

  # Minimal EIP-712 signingPayload mirroring what POST /payments returns.
  SIGNING_PAYLOAD = {
    domain: {
      name:              "USD Coin",
      version:           "2",
      chainId:           84532,
      verifyingContract: "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
    },
    types: {
      TransferWithAuthorization: [
        { name: "from",        type: "address" },
        { name: "to",          type: "address" },
        { name: "value",       type: "uint256" },
        { name: "validAfter",  type: "uint256" },
        { name: "validBefore", type: "uint256" },
        { name: "nonce",       type: "bytes32" }
      ]
    },
    primaryType: "TransferWithAuthorization",
    message: {
      from:        TEST_ADDRESS,
      to:          "0xRail0Contract0000000000000000000000000000",
      value:       "100000000",
      validAfter:  "0",
      validBefore: "9999999999",
      nonce:       "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab"
    }
  }.freeze

  # ================================================================
  #  Eip3009Signature#to_hex
  # ================================================================

  describe "Eip3009Signature#to_hex" do
    let(:sig) do
      Rail0::Signing::Eip3009Signature.new(
        v: 27,
        r: "0x" + "aa" * 32,
        s: "0x" + "bb" * 32
      )
    end

    it "returns a 0x-prefixed string" do
      expect(sig.to_hex).to start_with("0x")
    end

    it "is 132 characters long (0x + 64 r + 64 s + 2 v)" do
      expect(sig.to_hex.length).to eq(132)
    end

    it "encodes in r ++ s ++ v order" do
      hex = sig.to_hex
      expect(hex[2, 64]).to eq("aa" * 32)   # r
      expect(hex[66, 64]).to eq("bb" * 32)  # s
      expect(hex[130, 2]).to eq("1b")       # v = 27
    end

    it "zero-pads v to two hex digits" do
      sig28 = Rail0::Signing::Eip3009Signature.new(v: 28, r: "0x" + "cc" * 32, s: "0x" + "dd" * 32)
      expect(sig28.to_hex[-2..]).to eq("1c")
    end
  end

  # ================================================================
  #  SignPaymentParams — no longer has :amount
  # ================================================================

  describe "SignPaymentParams" do
    it "does not have an :amount member" do
      expect(Rail0::Signing::SignPaymentParams.members).not_to include(:amount)
    end

    it "has the expected members" do
      expect(Rail0::Signing::SignPaymentParams.members).to match_array(
        %i[private_key payment nonce contract_address token_domain]
      )
    end
  end

  # ================================================================
  #  sign_payload
  # ================================================================

  describe ".sign_payload" do
    subject(:sig) { Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, SIGNING_PAYLOAD) }

    it "returns an Eip3009Signature" do
      expect(sig).to be_a(Rail0::Signing::Eip3009Signature)
    end

    it "has v equal to 27 or 28" do
      expect([27, 28]).to include(sig.v)
    end

    it "has r and s as 0x-prefixed 66-char hex strings" do
      expect(sig.r).to match(/\A0x[0-9a-f]{64}\z/i)
      expect(sig.s).to match(/\A0x[0-9a-f]{64}\z/i)
    end

    it "produces a deterministic signature for the same input" do
      sig2 = Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, SIGNING_PAYLOAD)
      expect(sig.to_hex).to eq(sig2.to_hex)
    end

    it "to_hex returns a valid 65-byte hex string" do
      expect(sig.to_hex).to match(/\A0x[0-9a-f]{130}\z/i)
    end
  end

  # ================================================================
  #  sign_authorize / sign_charge
  # ================================================================

  describe ".sign_authorize and .sign_charge" do
    let(:payment) do
      # Flat, snake_case Payment record as returned by the gateway.
      {
        payer:                TEST_ADDRESS,
        payee:                "0xMerchant00000000000000000000000000000000",
        token:                "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        amount:               "100000000",
        authorization_expiry: 9_999_999_999,
        refund_expiry:        9_999_999_999
      }
    end

    let(:params) do
      Rail0::Signing::SignPaymentParams.new(
        private_key:      TEST_PRIVATE_KEY,
        payment:          payment,
        nonce:            SIGNING_PAYLOAD[:message][:nonce],
        contract_address: "0xRail0Contract0000000000000000000000000000",
        token_domain:     Rail0::Signing::TokenDomain.new(
          name:               "USD Coin",
          version:            "2",
          chain_id:           84532,
          verifying_contract: payment[:token]
        )
      )
    end

    it "sign_authorize returns a valid Eip3009Signature" do
      sig = Rail0::Signing.sign_authorize(params)
      expect(sig).to be_a(Rail0::Signing::Eip3009Signature)
      expect(sig.to_hex).to match(/\A0x[0-9a-f]{130}\z/i)
    end

    it "sign_charge returns a valid Eip3009Signature" do
      sig = Rail0::Signing.sign_charge(params)
      expect(sig).to be_a(Rail0::Signing::Eip3009Signature)
      expect(sig.to_hex).to match(/\A0x[0-9a-f]{130}\z/i)
    end

    it "sign_authorize and sign_charge produce the same signature for the same params" do
      # Both use the same nonce here (server differentiates via prefix; we pass the same nonce)
      auth_sig   = Rail0::Signing.sign_authorize(params)
      charge_sig = Rail0::Signing.sign_charge(params)
      expect(auth_sig.to_hex).to eq(charge_sig.to_hex)
    end

    it "produces a different signature when the nonce differs" do
      other_params = Rail0::Signing::SignPaymentParams.new(
        private_key:      TEST_PRIVATE_KEY,
        payment:          payment,
        nonce:            "0x" + "ff" * 32,  # different nonce → different digest
        contract_address: "0xRail0Contract0000000000000000000000000000",
        token_domain:     params.token_domain
      )
      expect(Rail0::Signing.sign_authorize(params).to_hex)
        .not_to eq(Rail0::Signing.sign_authorize(other_params).to_hex)
    end
  end

  # ================================================================
  #  sign_transfer_with_authorization
  # ================================================================

  describe ".sign_transfer_with_authorization" do
    it "returns an Eip3009Signature with a valid to_hex" do
      domain = Rail0::Signing::TokenDomain.new(
        name:               "USD Coin",
        version:            "2",
        chain_id:           84532,
        verifying_contract: "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
      )
      transfer_params = Rail0::Signing::SignTransferParams.new(
        from:         TEST_ADDRESS,
        to:           "0xRail0Contract0000000000000000000000000000",
        value:        100_000_000,
        valid_before: 9_999_999_999,
        nonce:        "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab"
      )

      sig = Rail0::Signing.sign_transfer_with_authorization(TEST_PRIVATE_KEY, domain, transfer_params)

      expect(sig).to be_a(Rail0::Signing::Eip3009Signature)
      expect(sig.to_hex).to match(/\A0x[0-9a-f]{130}\z/i)
    end
  end

  # ================================================================
  #  sign_transaction (EIP-1559 / type-2)
  # ================================================================

  describe ".sign_transaction" do
    # Field-set the gateway returns as a prepare step's unsigned_transaction:
    # numbers as JSON numbers, wei-scale values/fees as decimal strings.
    UNSIGNED_TX = {
      chain_id: 84532, nonce: 7, to: "0x1111111111111111111111111111111111111111",
      value: "0", data: "0xa9059cbb0000000000000000000000000000000000000000000000000000000000000001",
      gas_limit: 210_000, max_priority_fee_per_gas: "1000000000", max_fee_per_gas: "2500000000"
    }.freeze

    it "signs a JSON string and returns a 0x-prefixed type-2 raw tx" do
      raw = Rail0::Signing.sign_transaction(UNSIGNED_TX.to_json, TEST_PRIVATE_KEY)
      expect(raw).to start_with("0x02")
    end

    it "also accepts a pre-parsed Hash" do
      raw = Rail0::Signing.sign_transaction(UNSIGNED_TX, TEST_PRIVATE_KEY)
      expect(raw).to start_with("0x02")
    end

    it "recovers to the signer address and preserves the tx fields" do
      raw = Rail0::Signing.sign_transaction(UNSIGNED_TX.to_json, TEST_PRIVATE_KEY)
      decoded = Eth::Tx.decode(raw)
      expect("0x#{decoded.sender}".downcase).to eq(TEST_ADDRESS.downcase)
      expect(decoded.signer_nonce).to eq(7)
      expect(decoded.max_priority_fee_per_gas).to eq(1_000_000_000)
      expect(decoded.max_fee_per_gas).to eq(2_500_000_000)
      expect(decoded.payload.unpack1("H*")).to start_with("a9059cbb")
    end

    it "is deterministic for the same input" do
      a = Rail0::Signing.sign_transaction(UNSIGNED_TX.to_json, TEST_PRIVATE_KEY)
      b = Rail0::Signing.sign_transaction(UNSIGNED_TX.to_json, TEST_PRIVATE_KEY)
      expect(a).to eq(b)
    end
  end
end
