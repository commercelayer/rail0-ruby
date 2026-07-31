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
      to:          "0x13a46eDDBE6105f5c055A2C8729b773C9C7BBa1F",
      value:       "100000000",
      validAfter:  "0",
      validBefore: "9999999999",
      nonce:       "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
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
  #  primaryType handling — the payload is signed VERBATIM
  # ================================================================
  #
  # The rule this section exists to pin: the gateway builds the signing payload and
  # the client signs it as given. Which typehash to use is stated by the payload's
  # primaryType, never inferred, never defaulted. (#7)

  describe ".sign_payload primaryType handling" do
    def payload_with(primary_type)
      SIGNING_PAYLOAD.merge(primaryType: primary_type)
    end

    it "signs both primary types the gateway can emit, and differently" do
      transfer = Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, payload_with("TransferWithAuthorization"))
      receive  = Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, payload_with("ReceiveWithAuthorization"))

      # The typehash is part of the digest, so identical signatures would mean the
      # primaryType was being ignored.
      expect(transfer.to_hex).not_to eq(receive.to_hex)
      [transfer, receive].each { |sig| expect(sig.to_hex).to match(/\A0x[0-9a-f]{130}\z/i) }
    end

    # A silent fallback to one of the two known typehashes is how a client older
    # than its gateway signs the wrong digest and reports success.
    it "refuses an unknown primaryType instead of falling back" do
      expect { Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, payload_with("SomeFutureAuthorization")) }
        .to raise_error(ArgumentError, /SomeFutureAuthorization/)
    end

    it "refuses a missing primaryType" do
      expect { Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, SIGNING_PAYLOAD.reject { |k, _| k == :primaryType }) }
        .to raise_error(ArgumentError, /primaryType/)
    end

    it "names the version skew in the error, so the reader upgrades rather than blaming the key" do
      expect { Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, payload_with("Nonsense")) }
        .to raise_error(ArgumentError, /older than the gateway/)
    end

    # Everything signed must come from the payload — not from a payment record.
    it "reads every message and domain field from the payload" do
      base = Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, SIGNING_PAYLOAD).to_hex

      mutations = {
        "message.value"       => { message: SIGNING_PAYLOAD[:message].merge(value: "100000001") },
        "message.from"        => { message: SIGNING_PAYLOAD[:message].merge(from: "0x0000000000000000000000000000000000000002") },
        "message.to"          => { message: SIGNING_PAYLOAD[:message].merge(to: "0x0000000000000000000000000000000000000001") },
        "message.validAfter"  => { message: SIGNING_PAYLOAD[:message].merge(validAfter: "1") },
        "message.validBefore" => { message: SIGNING_PAYLOAD[:message].merge(validBefore: "8888888888") },
        "message.nonce"       => { message: SIGNING_PAYLOAD[:message].merge(nonce: "0x#{'cd' * 32}") },
        "domain.chainId"      => { domain:  SIGNING_PAYLOAD[:domain].merge(chainId: 1) },
        "domain.name"         => { domain:  SIGNING_PAYLOAD[:domain].merge(name: "Other Coin") },
        "domain.version"      => { domain:  SIGNING_PAYLOAD[:domain].merge(version: "1") },
        "domain.verifyingContract" => { domain: SIGNING_PAYLOAD[:domain].merge(verifyingContract: "0x0000000000000000000000000000000000000003") }
      }

      mutations.each do |field, override|
        mutated = Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, SIGNING_PAYLOAD.merge(override)).to_hex
        expect(mutated).not_to eq(base), "changing #{field} did not change the signature"
      end
    end

    # Callers who parse the gateway's JSON themselves get string keys; every lookup
    # inside is by symbol, so this used to silently sign a digest full of blanks.
    it "accepts a string-keyed payload" do
      symbol_keyed = Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, SIGNING_PAYLOAD).to_hex
      string_keyed = Rail0::Signing.sign_payload(
        TEST_PRIVATE_KEY, JSON.parse(SIGNING_PAYLOAD.to_json)
      ).to_hex

      expect(string_keyed).to eq(symbol_keyed)
    end

    it "rejects a payload that isn't a Hash" do
      expect { Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, "not a payload") }
        .to raise_error(ArgumentError, /must be a Hash/)
    end
  end

  # ================================================================
  #  removed digest-rebuilding helpers
  # ================================================================

  describe ".sign_authorize and .sign_charge" do
    # They rebuilt the digest from a payment record and hardcoded the Transfer
    # typehash, so rail0#58 (authorize/charge → ReceiveWithAuthorization) would have
    # made them sign a digest the token refuses, while reporting success. They raise
    # with the migration path rather than being deleted outright.
    it "raise with a message pointing at sign_payload" do
      %i[sign_authorize sign_charge].each do |method|
        expect { Rail0::Signing.public_send(method, nil) }
          .to raise_error(NotImplementedError, /sign_payload/)
      end
    end

    it "explain WHY, so the removal doesn't read as an arbitrary API churn" do
      expect { Rail0::Signing.sign_authorize(nil) }
        .to raise_error(NotImplementedError, /WRONG digest/)
    end
  end

  # ================================================================
  #  the signer seam
  # ================================================================
  #
  # The SDK builds the EIP-712 digest and hands only THAT to the signer, so the raw
  # secret never has to be materialised as a String in the calling process — which is
  # what makes "the server must never hold the buyer's key" implementable. (#10)

  describe "signing with something other than a key String" do
    # Stands in for a KMS/HSM client: it can sign a digest, and holds the key
    # material somewhere this process cannot read.
    let(:remote_signer) do
      Class.new do
        def initialize(key) = @key = key
        def sign(digest) = @key.sign(digest)
      end.new(Eth::Key.new(priv: TEST_PRIVATE_KEY.delete_prefix("0x")))
    end

    it "accepts any object responding to #sign(digest), producing the same signature" do
      from_string = Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, SIGNING_PAYLOAD).to_hex
      from_signer = Rail0::Signing.sign_payload(remote_signer, SIGNING_PAYLOAD).to_hex

      expect(from_signer).to eq(from_string)
    end

    it "accepts an Eth::Key the caller already holds" do
      key = Eth::Key.new(priv: TEST_PRIVATE_KEY.delete_prefix("0x"))

      expect(Rail0::Signing.sign_payload(key, SIGNING_PAYLOAD).to_hex)
        .to eq(Rail0::Signing.sign_payload(TEST_PRIVATE_KEY, SIGNING_PAYLOAD).to_hex)
    end

    # Without this the bad return produces v: nil and only fails later inside
    # #to_hex, with nothing pointing at the signer.
    it "names the signer when it returns something that isn't a 65-byte signature" do
      broken = Class.new { def sign(_digest) = "0xdeadbeef" }.new

      expect { Rail0::Signing.sign_payload(broken, SIGNING_PAYLOAD) }
        .to raise_error(ArgumentError, /expected 65/)
    end

    it "rejects anything that is neither a String nor a signer" do
      expect { Rail0::Signing.sign_payload(42, SIGNING_PAYLOAD) }
        .to raise_error(ArgumentError, /responding to #sign/)
    end

    # sign_transaction is deliberately narrower: Eth::Tx#sign needs a full Eth::Key
    # (it derives an EIP-155 v from the chain id), so a bare digest-signer cannot
    # serve there — but an Eth::Key must not have to be exported back to a String.
    it "sign_transaction accepts an Eth::Key as well as a String" do
      key = Eth::Key.new(priv: TEST_PRIVATE_KEY.delete_prefix("0x"))

      expect(Rail0::Signing.sign_transaction(UNSIGNED_TX.to_json, key))
        .to eq(Rail0::Signing.sign_transaction(UNSIGNED_TX.to_json, TEST_PRIVATE_KEY))
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
        to:           "0x13a46eDDBE6105f5c055A2C8729b773C9C7BBa1F",
        value:        100_000_000,
        valid_before: 9_999_999_999,
        nonce:        "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
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
