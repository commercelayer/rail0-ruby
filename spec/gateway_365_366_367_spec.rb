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

end
