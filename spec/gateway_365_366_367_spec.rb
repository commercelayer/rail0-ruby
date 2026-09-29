# frozen_string_literal: true

# Alignment with commercelayer/rail0-gateway#365, #366 and #367.
RSpec.describe "gateway alignment (#365, #366, #367)" do
  let(:client) { Rail0::Client.new(base_url: BASE_URL) }
  let(:json)   { { "Content-Type" => "application/json" } }

  def stub_list(path, items)
    stub_request(:get, "#{BASE_URL}#{path}")
      .to_return(status: 200, body: items.to_json, headers: json.merge(
        "X-Total-Count" => items.size.to_s, "X-Page" => "1", "X-Per-Page" => "25"
      ))
  end

  describe "#365 — measured settlement time per chain" do
    it "returns each chain's settlement figures" do
      stub_request(:get, "#{BASE_URL}/blockchains")
        .to_return(status: 200, body: [BLOCKCHAIN].to_json, headers: json)

      chain = client.chains.list.first

      expect(chain[:settlement]).to eq(p50_seconds: 11, p90_seconds: 19, sample_size: 20, window_days: 7)
    end

    it "passes null percentiles through below the minimum sample" do
      thin = BLOCKCHAIN.merge(settlement: { p50_seconds: nil, p90_seconds: nil, sample_size: 3, window_days: 7 })
      stub_request(:get, "#{BASE_URL}/blockchains")
        .to_return(status: 200, body: [thin].to_json, headers: json)

      settlement = client.chains.list.first[:settlement]

      expect(settlement[:p90_seconds]).to be_nil
      expect(settlement[:sample_size]).to eq(3)
    end
  end

  describe "#366 — payments.authorization_expiring" do
    it "is a subscribable topic" do
      expect(Rail0::Resources::Webhooks::TOPICS).to include("payments.authorization_expiring")
    end

    it "is sent in the topics of a create" do
      stub = stub_request(:post, "#{BASE_URL}/webhooks")
             .with(body: { name: "expiry", callback_url: "https://merchant.example/hook",
                           topics: ["payments.authorization_expiring"] })
             .to_return(status: 201, body: WEBHOOK_WITH_SECRET.to_json, headers: json)

      client.webhooks.create(name: "expiry", callback_url: "https://merchant.example/hook",
                             topics: ["payments.authorization_expiring"])

      expect(stub).to have_been_requested
    end
  end

  describe "#367 — decimals and in_flight on payments" do
    it "carries both on a list row" do
      stub_list("/payments", [PAYMENT_DETAIL.merge(in_flight: true)])

      row = client.payments.list[:data].first

      expect(row).to include(decimals: 6, in_flight: true)
    end

    it "carries both on the detail, decimals possibly null" do
      stub_request(:get, "#{BASE_URL}/payments/#{PAYMENT_ID}")
        .to_return(status: 200, body: PAYMENT_DETAIL.merge(decimals: nil).to_json, headers: json)

      payment = client.payments.get(PAYMENT_ID)

      expect(payment).to include(decimals: nil, in_flight: false)
    end
  end

  describe "#367 — multi-value status filter" do
    it "sends an Array of payment statuses comma-separated" do
      stub = stub_list("/payments?status=authorized,expired&chain_id=84532", [])

      client.payments.list(status: %w[authorized expired], chain_id: 84532)

      expect(stub).to have_been_requested
    end

    it "keeps a single status unchanged" do
      stub = stub_list("/payments?status=authorized", [])

      client.payments.list(status: "authorized")

      expect(stub).to have_been_requested
    end

    it "sends an Array of transaction statuses comma-separated" do
      stub = stub_list("/payments/#{PAYMENT_ID}/transactions?status=submitting,submitted", [])

      client.payments.transactions(PAYMENT_ID, status: %w[submitting submitted])

      expect(stub).to have_been_requested
    end

    it "drops an empty Array, as it does nil, instead of sending a blank value" do
      stub = stub_list("/payments?chain_id=84532", [])

      client.payments.list(status: [], chain_id: 84532)

      expect(stub).to have_been_requested
    end

    it "escapes each element but keeps the separator literal" do
      stub = stub_list("/payments?status=a%26b,c", [])

      client.payments.list(status: ["a&b", nil, "c"])

      expect(stub).to have_been_requested
    end
  end
end
