# frozen_string_literal: true

# The analytics resource is a URL builder over a pass-through: it returns the parsed JSON
# unchanged, so what is worth pinning is (a) the query it builds from the filters and
# (b) that the response's keys survive the trip — because with no typed wrapper, those keys
# ARE this SDK's contract, and the README documents them as such.
RSpec.describe Rail0::Resources::Analytics do
  let(:client) { Rail0::Client.new(base_url: BASE_URL) }

  def stub_get(path, body)
    stub_request(:get, "#{BASE_URL}#{path}")
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  # One row per chain, and the two cuts of it, as the gateway sends them.
  let(:summary_body) do
    {
      orders: 3, disputed: 1, refund_rate: 0.3333, dispute_rate: 0.3333, failed_rate: 0.25,
      by_status: { captured: 2, refunded: 1 },
      failures: [{ code: "insufficient_gas_funds", transactions: 2 },
                 { code: "nonce_too_low", transactions: 1 }],
      volume: [{ chain_id: 84_532, token: "0xtok", symbol: "USDC", decimals: 6, orders: 3,
                 gross: "3000000", settled: "2000000", escrowed: "0",
                 captured: "3000000", refunded: "1000000" }],
      gas: [{ chain_id: 84_532, chain_name: "Base Sepolia", symbol: "ETH", decimals: 18,
              orders: 3, spent: "72000", wasted: "10000", confirmed: 3, failed: 1,
              confirmation_secs: 45 }],
      gas_by_status: [
        { chain_id: 84_532, key: "captured", orders: 2, spent: "62000", wasted: "0",
          confirmed: 2, failed: 0 },
        { chain_id: 84_532, key: "refunded", orders: 1, spent: "10000", wasted: "10000",
          confirmed: 1, failed: 1 }
      ],
      gas_by_operation: [
        { chain_id: 84_532, key: "charge", orders: nil, spent: "52000", wasted: "0",
          confirmed: 2, failed: 0 },
        { chain_id: 84_532, key: "refund", orders: nil, spent: "20000", wasted: "10000",
          confirmed: 1, failed: 1 }
      ]
    }
  end

  describe "#summary" do
    it "returns the KPIs, the volume rows and the gas rows unchanged" do
      stub_get("/analytics/summary", summary_body)

      kpis = client.analytics.summary

      expect(kpis[:orders]).to eq(3)
      expect(kpis[:failed_rate]).to eq(0.25)
      # Where the money IS, alongside what HAPPENED — both pairs, not one.
      expect(kpis[:volume].first).to include(settled: "2000000", captured: "3000000")
      # Gas is the CHAIN's native token, never the payment token.
      expect(kpis[:gas].first).to include(symbol: "ETH", decimals: 18, orders: 3,
                                          confirmation_secs: 45)
      # failed_rate says how much fails; failures says what to act on, commonest first.
      expect(kpis[:failures].first).to eq({ code: "insufficient_gas_funds", transactions: 2 })
    end

    it "slices the gas two ways, and each cut sums back to its chain's row" do
      stub_get("/analytics/summary", summary_body)

      kpis = client.analytics.summary
      chain_total = kpis[:gas].first[:spent].to_i

      %i[gas_by_status gas_by_operation].each do |cut|
        expect(kpis[cut].sum { |row| row[:spent].to_i }).to eq(chain_total),
                                                            "#{cut} must add up to the chain's gas"
      end
      expect(kpis[:gas_by_status].map { |r| r[:key] }).to eq(%w[captured refunded])
      # No order denominator per operation: one order spans several operations, so a count
      # there would be the same order counted once per operation it carries.
      expect(kpis[:gas_by_operation].map { |r| r[:orders] }).to all(be_nil)
    end

    it "forwards every filter and drops chain_id 0, which means 'all chains'" do
      stub = stub_request(:get, "#{BASE_URL}/analytics/summary")
             .with(query: { mode: "charge", status: "captured", token: "0xtok",
                            from: "2026-01-01T00:00:00Z", to: "2026-02-01T00:00:00Z" })
             .to_return(status: 200, body: summary_body.to_json,
                        headers: { "Content-Type" => "application/json" })

      client.analytics.summary(mode: "charge", status: "captured", token: "0xtok",
                               chain_id: 0, from: "2026-01-01T00:00:00Z",
                               to: "2026-02-01T00:00:00Z")

      expect(stub).to have_been_requested
    end
  end

  describe "#timeseries" do
    it "passes the interval through and keeps a null volume null" do
      stub_request(:get, "#{BASE_URL}/analytics/timeseries")
        .with(query: { interval: "week" })
        .to_return(status: 200,
                   body: [{ bucket: "2026-07-01T00:00:00Z", orders: 3, volume: nil }].to_json,
                   headers: { "Content-Type" => "application/json" })

      buckets = client.analytics.timeseries(interval: "week")

      # `orders`, not `count` — the README said `count` for two gateway versions.
      expect(buckets.first).to include(bucket: "2026-07-01T00:00:00Z", orders: 3, volume: nil)
    end
  end

  describe "#breakdown" do
    it "groups the merchant's own confirmed transactions when asked by operation" do
      stub_request(:get, "#{BASE_URL}/analytics/breakdown")
        .with(query: { by: "operation" })
        .to_return(status: 200,
                   body: [{ key: "capture", orders: 1, transactions: 2 }].to_json,
                   headers: { "Content-Type" => "application/json" })

      # transactions is not orders: a partial capture runs several times on one order.
      expect(client.analytics.breakdown(by: "operation").first)
        .to include(key: "capture", orders: 1, transactions: 2)
    end

    it "requires a dimension, and asks for it" do
      expect { client.analytics.breakdown(by: nil) }.to raise_error(ArgumentError, /by is required/)

      stub_request(:get, "#{BASE_URL}/analytics/breakdown")
        .with(query: { by: "chain" })
        .to_return(status: 200,
                   body: [{ key: "Base Sepolia", chain_id: 84_532, orders: 9 }].to_json,
                   headers: { "Content-Type" => "application/json" })

      expect(client.analytics.breakdown(by: "chain").first).to include(key: "Base Sepolia", orders: 9)
    end
  end
end
