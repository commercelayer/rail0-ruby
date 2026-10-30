# frozen_string_literal: true

require "spec_helper"

PAYOUT_DESTINATION_ID = "019a0000-0000-7000-8000-00000000d001"
PAYOUT_ID             = "019a0000-0000-7000-8000-00000000a001"
PAYOUT_RECIPIENT      = "0x9999999999999999999999999999999999999999"
# Anvil/Hardhat deterministic test key #0 and its address — never use in production.
PAYOUT_SPEC_KEY       = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
PAYOUT_SPEC_SIGNER    = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

RSpec.describe Rail0::Resources::PayoutDestinations do
  let(:client) { Rail0::Client.new(base_url: BASE_URL, token: "jwt") }
  let(:json) { { "Content-Type" => "application/json" } }
  let(:destination) do
    { id: PAYOUT_DESTINATION_ID, wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN.downcase,
      address: "0x9999999999999999999999999999999999999999", status: "unverified", min_amount: nil, no_minimum: true }
  end

  it "quotes the gateway's details_v1 text" do
    expect(described_class::CONFIRM_DETAILS_TEXT).to eq(
      "I have checked the address, network, token and minimum deposit on the venue's deposit page and " \
      "confirm they are correct. Funds sent to a wrong address or network, or below the venue's minimum, " \
      "may be permanently lost and cannot be recovered by rail0."
    )
  end

  describe "#list" do
    it "pages like the payment list and passes the filters" do
      stub_request(:get, "#{BASE_URL}/payout_destinations?wallet_id=#{WALLET_ID}&status=verified&page=2&per_page=10")
        .to_return(status: 200, body: [destination].to_json,
                   headers: json.merge("X-Page" => "2", "X-Per-Page" => "10", "X-Total-Count" => "11",
                                       "X-Total-Pages" => "2"))

      result = client.payout_destinations.list(wallet_id: WALLET_ID, status: "verified", page: 2, per_page: 10)

      expect(result[:data].first[:id]).to eq(PAYOUT_DESTINATION_ID)
      expect(result[:meta]).to include(page: 2, per_page: 10, total: 11, total_pages: 2)
    end
  end

  describe "#create" do
    it "requires confirm_details and sends it with the destination" do
      expect do
        client.payout_destinations.create(wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN,
                                          address: destination[:address], min_amount: "0")
      end.to raise_error(ArgumentError, /confirm_details/)
    end

    it "requires exactly one of min_amount or no_minimum: true, and sends nothing otherwise" do
      base = { wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN, address: destination[:address],
               confirm_details: true }
      [{}, { min_amount: "" }, { min_amount: "  ", no_minimum: false }, { no_minimum: false },
       { min_amount: "5000000", no_minimum: true }].each do |minimum|
        expect { client.payout_destinations.create(**base, **minimum) }
          .to raise_error(ArgumentError, /min_amount.*no_minimum/), minimum.inspect
      end
      expect(a_request(:any, /payout_destinations/)).not_to have_been_made
    end

    it "sends no_minimum: true when the venue has none" do
      stub = stub_request(:post, "#{BASE_URL}/payout_destinations")
             .with(body: { wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN, address: destination[:address],
                           confirm_details: true, no_minimum: true }.to_json)
             .to_return(status: 201, body: destination.to_json, headers: json)

      result = client.payout_destinations.create(wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN,
                                                 address: destination[:address], confirm_details: true,
                                                 no_minimum: true)

      expect(stub).to have_been_requested
      expect(result[:no_minimum]).to be(true)
    end

    it "sends \"0\" as a figure like any other" do
      stub = stub_request(:post, "#{BASE_URL}/payout_destinations")
             .with(body: { wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN, address: destination[:address],
                           confirm_details: true, min_amount: "0" }.to_json)
             .to_return(status: 201, body: destination.to_json, headers: json)

      client.payout_destinations.create(wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN,
                                        address: destination[:address], confirm_details: true, min_amount: "0")

      expect(stub).to have_been_requested
    end

    it "surfaces minimum_conflict and minimum_required with their hints" do
      stub_request(:post, "#{BASE_URL}/payout_destinations")
        .to_return(status: 422, body: { code: "minimum_conflict", title: "Minimum deposit conflict",
                                        detail: "Send a minimum or no_minimum, not both." }.to_json, headers: json)

      expect do
        client.payout_destinations.create(wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN,
                                          address: destination[:address], confirm_details: true, min_amount: "1")
      end.to raise_error(Rail0::ApiError) { |e| expect(e.error).to eq("minimum_conflict") }
      expect(Rail0.describe_error("minimum_conflict")).to include("not both")
      expect(Rail0.describe_error("minimum_required")).to include("no_minimum: true")
    end

    it "POSTs only the fields given" do
      stub = stub_request(:post, "#{BASE_URL}/payout_destinations")
             .with(body: { wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN, address: destination[:address],
                           confirm_details: true, label: "Kraken", min_amount: "5000000" }.to_json)
             .to_return(status: 201, body: destination.to_json, headers: json)

      result = client.payout_destinations.create(wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN,
                                                 address: destination[:address], confirm_details: true,
                                                 label: "Kraken", min_amount: "5000000")

      expect(stub).to have_been_requested
      expect(result[:status]).to eq("unverified")
    end

    it "surfaces confirmation_required with its hint" do
      stub_request(:post, "#{BASE_URL}/payout_destinations")
        .to_return(status: 422, body: { code: "confirmation_required", title: "Confirmation required",
                                        detail: "Confirm that you checked…" }.to_json, headers: json)

      expect do
        client.payout_destinations.create(wallet_id: WALLET_ID, chain_id: 84532, token: TOKEN,
                                          address: destination[:address], confirm_details: false,
                                          min_amount: "0")
      end.to raise_error(Rail0::ApiError) { |e| expect(e.error).to eq("confirmation_required") }
      expect(Rail0.describe_error("confirmation_required")).to include("confirm_details: true")
    end
  end

  describe "#update" do
    let(:path) { "#{BASE_URL}/payout_destinations/#{PAYOUT_DESTINATION_ID}" }

    it "PATCHes only the keywords passed, confirm_details included" do
      stub = stub_request(:patch, path)
             .with(body: { min_amount: "10000000", confirm_details: true }.to_json)
             .to_return(status: 200, body: destination.to_json, headers: json)

      client.payout_destinations.update(PAYOUT_DESTINATION_ID, min_amount: "10000000", confirm_details: true)

      expect(stub).to have_been_requested
    end

    it "removes the minimum with no_minimum: true" do
      stub = stub_request(:patch, path)
             .with(body: { no_minimum: true, confirm_details: true }.to_json)
             .to_return(status: 200, body: destination.to_json, headers: json)

      client.payout_destinations.update(PAYOUT_DESTINATION_ID, no_minimum: true, confirm_details: true)

      expect(stub).to have_been_requested
    end

    it "refuses a blank min_amount, or one beside no_minimum: true, before sending" do
      expect do
        client.payout_destinations.update(PAYOUT_DESTINATION_ID, min_amount: "", confirm_details: true)
      end.to raise_error(ArgumentError, /blank/)
      expect do
        client.payout_destinations.update(PAYOUT_DESTINATION_ID, min_amount: "1", no_minimum: true,
                                                                 confirm_details: true)
      end.to raise_error(ArgumentError, /not both/)
      expect(a_request(:patch, path)).not_to have_been_made
    end

    it "sends an empty reserve_amount (restore the suggestion) and active: false" do
      stub = stub_request(:patch, path)
             .with(body: { reserve_amount: "", active: false }.to_json)
             .to_return(status: 200, body: destination.to_json, headers: json)

      client.payout_destinations.update(PAYOUT_DESTINATION_ID, reserve_amount: "", active: false)

      expect(stub).to have_been_requested
    end

    it "refuses an update with nothing to change" do
      expect { client.payout_destinations.update(PAYOUT_DESTINATION_ID) }.to raise_error(ArgumentError)
      expect do
        client.payout_destinations.update(PAYOUT_DESTINATION_ID, confirm_details: true)
      end.to raise_error(ArgumentError)
    end
  end

  it "#get, #confirm and #events hit their routes" do
    get = stub_request(:get, "#{BASE_URL}/payout_destinations/#{PAYOUT_DESTINATION_ID}")
          .to_return(status: 200, body: destination.to_json, headers: json)
    confirm = stub_request(:post, "#{BASE_URL}/payout_destinations/#{PAYOUT_DESTINATION_ID}/confirm")
              .to_return(status: 200, body: destination.merge(status: "verified").to_json, headers: json)
    events = stub_request(:get, "#{BASE_URL}/payout_destinations/#{PAYOUT_DESTINATION_ID}/events?per_page=5")
             .to_return(status: 200, body: [{ action: "destination.created" }].to_json,
                        headers: json.merge("X-Total-Count" => "1"))

    client.payout_destinations.get(PAYOUT_DESTINATION_ID)
    expect(client.payout_destinations.confirm(PAYOUT_DESTINATION_ID)[:status]).to eq("verified")
    expect(client.payout_destinations.events(PAYOUT_DESTINATION_ID, per_page: 5)[:data].first[:action])
      .to eq("destination.created")
    expect([get, confirm, events]).to all(have_been_requested)
  end

  it "escapes the id into one path segment" do
    stub = stub_request(:get, "#{BASE_URL}/payout_destinations/..%2Fpayouts")
           .to_return(status: 404, body: { code: "not_found" }.to_json, headers: json)

    expect { client.payout_destinations.get("../payouts") }.to raise_error(Rail0::ApiError)
    expect(stub).to have_been_requested
  end
end

RSpec.describe Rail0::Resources::Payouts do
  let(:client)    { Rail0::Client.new(base_url: BASE_URL, token: "jwt") }
  let(:json)      { { "Content-Type" => "application/json" } }
  let(:destination) do
    { id: PAYOUT_DESTINATION_ID, chain_id: 84532, token: TOKEN.downcase, address: PAYOUT_RECIPIENT, status: "verified" }
  end
  let(:payout) do
    data = "0xa9059cbb#{PAYOUT_RECIPIENT.delete_prefix('0x').rjust(64, '0')}#{250_000_000.to_s(16).rjust(64, '0')}"
    unsigned = { chain_id: 84532, from: PAYOUT_SPEC_SIGNER, to: TOKEN, value: "0", data: data, nonce: 1, gas_limit: 60_000,
                 max_priority_fee_per_gas: 1_000_000, max_fee_per_gas: 2_000_000_000 }.to_json
    { id: PAYOUT_ID, destination_id: PAYOUT_DESTINATION_ID, chain_id: 84532, token: TOKEN.downcase,
      address: PAYOUT_RECIPIENT, amount: "250000000", amount_formatted: "250", purpose: "payout",
      status: "pending", signed: false, unsigned_transaction: unsigned }
  end

  describe "#list" do
    it "joins a status Array and pages like payments" do
      stub_request(:get, "#{BASE_URL}/payouts?destination_id=#{PAYOUT_DESTINATION_ID}&status=pending,failed&purpose=proof&page=1")
        .to_return(status: 200, body: [payout].to_json,
                   headers: json.merge("X-Page" => "1", "X-Per-Page" => "25", "X-Total-Count" => "1",
                                       "X-Total-Pages" => "1"))

      result = client.payouts.list(destination_id: PAYOUT_DESTINATION_ID, status: %w[pending failed],
                                   purpose: "proof", page: 1)

      expect(result[:data].first[:id]).to eq(PAYOUT_ID)
      expect(result[:meta]).to include(total: 1, total_pages: 1)
    end
  end

  describe "#prepare" do
    it "sends the destination, purpose and human amount" do
      stub = stub_request(:post, "#{BASE_URL}/payouts/prepare")
             .with(body: { destination_id: PAYOUT_DESTINATION_ID, purpose: "payout", amount: "all" }.to_json)
             .to_return(status: 201, body: payout.to_json, headers: json)

      client.payouts.prepare(destination_id: PAYOUT_DESTINATION_ID, purpose: "payout", amount: "all")

      expect(stub).to have_been_requested
    end

    it "sends a proof without an amount" do
      stub = stub_request(:post, "#{BASE_URL}/payouts/prepare")
             .with(body: { destination_id: PAYOUT_DESTINATION_ID, purpose: "proof" }.to_json)
             .to_return(status: 201, body: payout.merge(purpose: "proof").to_json, headers: json)

      client.payouts.prepare(destination_id: PAYOUT_DESTINATION_ID, purpose: "proof")

      expect(stub).to have_been_requested
    end
  end

  it "#get, #events, #submit, #resend, #cancel and #submit_by_hash hit their routes" do
    hash = "0x#{'ab' * 32}"
    stubs = [
      stub_request(:get, "#{BASE_URL}/payouts/#{PAYOUT_ID}").to_return(status: 200, body: payout.to_json, headers: json),
      stub_request(:get, "#{BASE_URL}/payouts/#{PAYOUT_ID}/events")
        .to_return(status: 200, body: [].to_json, headers: json),
      stub_request(:post, "#{BASE_URL}/payouts/#{PAYOUT_ID}/submit").with(body: { signed_transaction: "0x02" }.to_json)
                                                                    .to_return(status: 202, body: payout.to_json, headers: json),
      stub_request(:post, "#{BASE_URL}/payouts/#{PAYOUT_ID}/resend").to_return(status: 202, body: payout.to_json, headers: json),
      stub_request(:post, "#{BASE_URL}/payouts/#{PAYOUT_ID}/cancel").to_return(status: 200, body: payout.to_json, headers: json),
      stub_request(:post, "#{BASE_URL}/payouts/#{PAYOUT_ID}/submitted").with(body: { transaction_hash: hash }.to_json)
                                                                       .to_return(status: 202, body: payout.to_json, headers: json)
    ]

    client.payouts.get(PAYOUT_ID)
    client.payouts.events(PAYOUT_ID)
    client.payouts.submit(PAYOUT_ID, { signed_transaction: "0x02" })
    client.payouts.resend(PAYOUT_ID)
    client.payouts.cancel(PAYOUT_ID)
    client.payouts.submit_by_hash(PAYOUT_ID, { transaction_hash: hash })

    expect(stubs).to all(have_been_requested)
  end

  describe "#sign_and_submit" do
    it "verifies, signs with the key and submits the raw transaction" do
      stub = stub_request(:post, "#{BASE_URL}/payouts/#{PAYOUT_ID}/submit")
             .with { |req| JSON.parse(req.body)["signed_transaction"].match?(/\A0x02\h+\z/) }
             .to_return(status: 202, body: payout.merge(status: "submitted").to_json, headers: json)

      result = client.payouts.sign_and_submit(payout, PAYOUT_SPEC_KEY, destination: destination, amount: "250", decimals: 6)

      expect(stub).to have_been_requested
      expect(result[:status]).to eq("submitted")
    end

    it "sends nothing when the transfer is refused" do
      stub = stub_request(:post, "#{BASE_URL}/payouts/#{PAYOUT_ID}/submit")
      tampered = payout.merge(address: "0x000000000000000000000000000000000000dEaD")

      expect { client.payouts.sign_and_submit(tampered, PAYOUT_SPEC_KEY, destination: destination) }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /destination's address/)
      expect { client.payouts.sign_and_submit(payout, PAYOUT_SPEC_KEY, amount: "25", decimals: 6) }
        .to raise_error(Rail0::TxVerify::RefusedSignature, /you asked for 25000000/)
      expect(stub).not_to have_been_requested
    end
  end
end

RSpec.describe "payout webhook topics and error hints" do
  it "lists the payout topics" do
    expect(Rail0::Resources::Webhooks::TOPICS)
      .to include("payouts.confirmed", "payouts.failed", "payout_destinations.verified")
  end

  it "hints every payout error code the gateway documents" do
    %w[confirmation_required minimum_required minimum_conflict payout_below_minimum payout_destination_unverified payout_destination_disabled
       payout_destination_proof_missing payout_destination_exists payout_destination_zero_address
       payout_destination_own_wallet payout_destination_is_contract payout_already_signed payout_not_pending
       payout_not_signed payout_hash_in_use payout_limit_reached insufficient_balance account_deactivated
       foreign_transfer_hash transaction_mismatch invalid_amount invalid_transaction unknown_chain].each do |code|
      expect(Rail0.describe_error(code)).to be_a(String), code
    end
  end
end
