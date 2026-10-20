# frozen_string_literal: true

require "spec_helper"
require "rail0/signing"

# Signing.sign_payload used to sign whatever signing_payload the gateway returned — an
# EIP-3009 authorization the TOKEN honours on its own, for up to message.value. These pin
# the checks that now run first, ported from the CLI's cmd/tx_verify_test.go
# (verifySigningPayload): its vectors appear verbatim below.
RSpec.describe Rail0::PayloadVerify do
  # Anvil/Hardhat deterministic test key #0 — never use in production.
  PV_KEY    = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  PV_SIGNER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

  # The CLI's test vectors (testSigner, testChainID, testPayloadToken, testAttacker,
  # testRail0Contract).
  CLI_SIGNER   = "0x1111111111111111111111111111111111111111"
  CLI_CHAIN    = 84532
  CLI_TOKEN    = "0x3333333333333333333333333333333333333333"
  CLI_ATTACKER = "0x4444444444444444444444444444444444444444"
  CLI_CONTRACT = "0x2222222222222222222222222222222222222222"

  # `types` as the gateway emits them (Rail0::Eip3009#typed_data).
  def gateway_types(primary_type = "ReceiveWithAuthorization")
    {
      EIP712Domain: [{ name: "name", type: "string" }, { name: "version", type: "string" },
                     { name: "chainId", type: "uint256" }, { name: "verifyingContract", type: "address" }],
      primary_type.to_sym => [{ name: "from", type: "address" }, { name: "to", type: "address" },
                              { name: "value", type: "uint256" }, { name: "validAfter", type: "uint256" },
                              { name: "validBefore", type: "uint256" }, { name: "nonce", type: "bytes32" }]
    }
  end

  # The CLI's testPayload(nil), with the gateway's types.
  def payload(from: CLI_SIGNER, **overrides)
    domain  = { name: "USD Coin", version: "2", chainId: CLI_CHAIN, verifyingContract: CLI_TOKEN }
    message = { from: from, to: CLI_CONTRACT, value: "1000000", validAfter: "0", validBefore: "2000000000",
                nonce: "0x#{'ab' * 32}" }
    {
      primaryType: overrides.fetch(:primaryType, "ReceiveWithAuthorization"),
      types: overrides.fetch(:types) { gateway_types(overrides.fetch(:primaryType, "ReceiveWithAuthorization")) },
      domain: domain.merge(overrides.fetch(:domain, {})),
      message: message.merge(overrides.fetch(:message, {}))
    }
  end

  let(:payment) do
    { chain_id: CLI_CHAIN, token: CLI_TOKEN, rail0_contract: CLI_CONTRACT, amount: "1000000", decimals: 6 }
  end

  def verify(signing_payload, pay: payment, signer: CLI_SIGNER, amount: nil)
    described_class.verify(signing_payload, payment: pay, signer: signer, amount: amount)
  end

  def refusal(pattern = //)
    raise_error(Rail0::TxVerify::RefusedSignature, /\Arefusing to sign: .*#{pattern.source}/m)
  end

  describe ".verify" do
    # The happy path must sail through, or every signing flow breaks.
    it "accepts a well-formed payload (CLI vector) and returns it symbol-keyed" do
      expect(verify(payload)).to eq(payload)
    end

    it "compares addresses case-insensitively, as the gateway may return them checksummed" do
      upper = payload(from: CLI_SIGNER.upcase, domain: { verifyingContract: CLI_TOKEN.upcase },
                      message: { to: CLI_CONTRACT.upcase })
      expect { verify(upper) }.not_to raise_error
    end

    it "accepts a string-keyed payload and payment, and a decimal-string chainId" do
      sp = JSON.parse(payload(domain: { chainId: CLI_CHAIN.to_s }).to_json)
      expect { verify(sp, pay: payment.transform_keys(&:to_s)) }.not_to raise_error
    end

    it "checks against the caller's amount, scaled by the payment's decimals, when given" do
      expect { verify(payload, amount: "1") }.not_to raise_error
      expect { verify(payload, amount: "1.000000") }.not_to raise_error
      expect { verify(payload(message: { value: "1500000" }), amount: "1.5") }.not_to raise_error
      # A partial refund must be held to the refund amount, not the payment's.
      expect { verify(payload, amount: "0.5") }.to refusal(/1000000 base units but you asked for 500000/)
    end

    # The CLI's TestVerifySigningPayloadRejectsHostilePayloads, plus `to`.
    {
      # THE case this exists for: a drain of the signer's whole balance.
      "value inflated far past the amount asked for" =>
        [{ message: { value: "999999999999" } }, /authorization is for 999999999999 base units but you asked for 1000000/],
      "from is not the signing key" =>
        [{ from: CLI_ATTACKER }, /authorization is from #{CLI_ATTACKER} but the signing key is #{CLI_SIGNER}/],
      "domain names another token" =>
        [{ domain: { verifyingContract: CLI_ATTACKER } },
         /authorization is against token #{CLI_ATTACKER} but this payment's token is #{CLI_TOKEN}/],
      "domain names another chain" =>
        [{ domain: { chainId: CLI_CHAIN + 1 } }, /scoped to chain 84533 but this payment is on chain 84532/],
      "authorization pays another address" =>
        [{ message: { to: CLI_TOKEN } },
         /authorization pays #{CLI_TOKEN} but this payment's RAIL0 contract is #{CLI_CONTRACT}/]
    }.each do |name, (overrides, message)|
      it "refuses a hostile payload: #{name}" do
        expect { verify(payload(**overrides)) }.to refusal(message)
      end
    end

    it "refuses an absent or malformed field rather than skipping it" do
      expect { verify(payload(from: nil)) }.to refusal(/authorization is from  but the signing key/)
      expect { verify(payload(message: { to: "" })) }.to refusal(/authorization pays/)
      expect { verify(payload(domain: { verifyingContract: nil })) }.to refusal(/against token/)
      expect { verify(payload(domain: { chainId: nil })) }.to refusal(/scoped to chain/)
      # Coercion would read these as 1000000; exact means exact.
      ["1000000abc", "0x0f4240", "1000000.0", " 1000000", nil, -1].each do |value|
        expect { verify(payload(message: { value: value })) }.to refusal(/base units but you asked for 1000000/)
      end
      expect { verify(payload(message: { value: 1_000_000 })) }.not_to raise_error
    end

    it "fails closed on what it cannot compare" do
      expect { verify(payload, pay: payment.except(:amount)) }.to refusal(/cannot check the authorization's amount/)
      expect { verify(payload, pay: payment.merge(amount: "1.0")) }.to refusal(/cannot check the authorization's amount/)
      expect { verify(payload, pay: payment.merge(decimals: nil), amount: "1") }.to refusal(/decimals are unknown/)
      expect { verify(payload, amount: "1.0000001") }.to refusal(/7 decimal places, but this token has 6/)
      expect { verify(payload, amount: "lots") }.to refusal(/not a decimal number/)
      %i[chain_id token rail0_contract].each do |field|
        expect { verify(payload, pay: payment.except(field)) }.to refusal(/without the payment's #{field}/)
      end
      expect { verify(payload, pay: nil) }.to refusal(/without the payment it is for/)
      expect { verify(payload, signer: nil) }.to refusal(/without the address of the signing key/)
      expect { verify(nil) }.to refusal(/no signing payload/)
      expect { verify(payload.except(:message)) }.to refusal(/no message object/)
      expect { verify(payload.merge(domain: "x")) }.to refusal(/no domain object/)
    end
  end

  # The typed-data envelope. Signing.sign_payload hashes with fixed typehashes, but a
  # browser wallet hashes whatever `types` says: each tampering is refused before either.
  describe ".verify: the typed-data envelope" do
    def with_fields(name, primary_type = "ReceiveWithAuthorization")
      types = gateway_types(primary_type)
      types[name.to_sym] = yield(types[name.to_sym].map(&:dup))
      payload(types: types)
    end

    it "accepts the gateway's own payload (produced by Rail0::Eip3009#typed_data)" do
      gateway = JSON.parse(File.read(File.expand_path("fixtures/gateway_signing_payload.json", __dir__)))
      expect { verify(gateway, signer: PV_SIGNER) }.not_to raise_error
      expect { Rail0::Signing.sign_signing_payload(gateway, PV_KEY, payment: payment) }.not_to raise_error
    end

    it "accepts TransferWithAuthorization (pre-1.4.0 deployments) and an absent EIP712Domain" do
      expect { verify(payload(primaryType: "TransferWithAuthorization")) }.not_to raise_error
      expect { verify(payload(types: gateway_types.except(:EIP712Domain))) }.not_to raise_error
    end

    {
      "an unknown primaryType" =>
        [-> { payload(primaryType: "Permit") }, /primaryType "Permit" is not an EIP-3009 authorization type/],
      "a primaryType with no definition in types" =>
        [-> { payload(primaryType: "TransferWithAuthorization", types: gateway_types) },
         /types define "ReceiveWithAuthorization", which an EIP-3009 authorization does not use/],
      "reordered fields" =>
        [-> { with_fields(:ReceiveWithAuthorization) { |f| [f[1], f[0], *f[2..]] } },
         /types\.ReceiveWithAuthorization is \(address to,address from,/],
      "a renamed field" =>
        [-> { with_fields(:ReceiveWithAuthorization) { |f| f.tap { f[1] = { name: "recipient", type: "address" } } } },
         /address recipient.* but must be exactly \(address from,address to,uint256 value,/],
      "a changed field type" =>
        [-> { with_fields(:ReceiveWithAuthorization) { |f| f.tap { f[2] = { name: "value", type: "uint128" } } } },
         /uint128 value/],
      "an extra field" =>
        [-> { with_fields(:ReceiveWithAuthorization) { |f| f + [{ name: "spender", type: "address" }] } },
         /address spender\) but must be exactly/],
      "a missing field" =>
        [-> { with_fields(:ReceiveWithAuthorization) { |f| f[0..4] } }, /types\.ReceiveWithAuthorization is \(/],
      "an extra key on a field" =>
        [-> { with_fields(:ReceiveWithAuthorization) { |f| f.tap { f[0] = f[0].merge(note: "x") } } },
         /types\.ReceiveWithAuthorization is \(/],
      "an extra type definition" =>
        [-> { payload(types: gateway_types.merge(Transfer: [{ name: "to", type: "address" }])) },
         /types define "Transfer"/],
      "a wrong EIP712Domain" =>
        [-> { with_fields(:EIP712Domain) { |f| f + [{ name: "salt", type: "bytes32" }] } },
         /types\.EIP712Domain is \(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt\) but must be exactly \(string name,string version,uint256 chainId,address verifyingContract\)/],
      "an EIP712Domain without version" =>
        [-> { with_fields(:EIP712Domain) { |f| [f[0], f[2], f[3]] } },
         /types\.EIP712Domain is \(string name,uint256 chainId,address verifyingContract\)/],
      "no types" => [-> { payload(types: nil) }, /the signing payload has no types/],
      "empty types" => [-> { payload(types: {}) }, /types\.ReceiveWithAuthorization is \(null\)/],
      "fields that are not a list" =>
        [-> { payload(types: { ReceiveWithAuthorization: "address from" }) },
         /types\.ReceiveWithAuthorization is \("address from"\)/]
    }.each do |name, (build, message)|
      it "refuses: #{name}" do
        expect { verify(instance_exec(&build)) }.to refusal(message)
        # String-keyed, as JSON.parse hands it over, is judged the same.
        expect { verify(JSON.parse(instance_exec(&build).to_json)) }.to refusal(message)
        signer = Class.new do
          def address = CLI_SIGNER
          def sign(_digest) = raise("the key was asked to sign")
        end.new
        expect { Rail0::Signing.sign_signing_payload(instance_exec(&build), signer, payment: payment) }
          .to refusal(message)
      end
    end
  end

  describe "Rail0::Signing.sign_signing_payload" do
    let(:own) { payload(from: PV_SIGNER) }

    it "signs a payload that passes the checks, byte-identical to the blind form" do
      sig = Rail0::Signing.sign_signing_payload(own, PV_KEY, payment: payment)
      was = Warning[:deprecated]
      Warning[:deprecated] = false
      expect(sig.to_hex).to eq(Rail0::Signing.sign_payload(PV_KEY, own).to_hex)
    ensure
      Warning[:deprecated] = was
    end

    it "uses the key's own address as the expected signer" do
      expect { Rail0::Signing.sign_signing_payload(payload, PV_KEY, payment: payment) }
        .to refusal(/the signing key is #{PV_SIGNER}/)
      key = Eth::Key.new(priv: PV_KEY.delete_prefix("0x"))
      expect { Rail0::Signing.sign_signing_payload(own, key, payment: payment) }.not_to raise_error
    end

    it "refuses before signing: the key is never asked for a signature" do
      signer = Class.new do
        def address = PV_SIGNER
        def sign(_digest) = raise("the key was asked to sign")
      end.new
      hostile = payload(from: PV_SIGNER, message: { value: "9" })
      # A RuntimeError here would mean the digest reached the key.
      expect { Rail0::Signing.sign_signing_payload(hostile, signer, payment: payment) }.to refusal(/base units/)
    end

    it "takes a remote signer exposing #address, and refuses one that cannot name it" do
      inner  = Eth::Key.new(priv: PV_KEY.delete_prefix("0x"))
      remote = Class.new do
        def initialize(key) = @key = key
        def sign(digest) = @key.sign(digest)
        def address = @key.address.to_s
      end.new(inner)
      expect(Rail0::Signing.sign_signing_payload(own, remote, payment: payment).to_hex)
        .to eq(Rail0::Signing.sign_signing_payload(own, PV_KEY, payment: payment).to_hex)

      anonymous = Class.new { def sign(_digest) = "0x" }.new
      expect { Rail0::Signing.sign_signing_payload(own, anonymous, payment: payment) }
        .to raise_error(ArgumentError, /#address/)
    end

    it "is what sign_payload does when given payment: (or amount:)" do
      a = Rail0::Signing.sign_payload(PV_KEY, own, payment: payment).to_hex
      expect(a).to eq(Rail0::Signing.sign_signing_payload(own, PV_KEY, payment: payment).to_hex)
      expect { Rail0::Signing.sign_payload(PV_KEY, own, payment: payment, amount: "2") }.to refusal(/asked for 2000000/)
      expect { Rail0::Signing.sign_payload(PV_KEY, own, amount: "1") }.to refusal(/without the payment it is for/)
    end

    it "warns, as a :deprecated category warning, when sign_payload is called blind" do
      was = Warning[:deprecated]
      Warning[:deprecated] = true
      expect { Rail0::Signing.sign_payload(PV_KEY, own) }
        .to output(/signs the gateway's authorization blindly and is deprecated/).to_stderr
      Warning[:deprecated] = false
      expect { Rail0::Signing.sign_payload(PV_KEY, own) }.not_to output.to_stderr
    ensure
      Warning[:deprecated] = was
    end
  end
end
