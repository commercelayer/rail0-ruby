# frozen_string_literal: true

# Alignment with commercelayer/rail0-gateway#330, #331 and #332.
RSpec.describe "gateway alignment" do
  let(:client)     { Rail0::Client.new(base_url: BASE_URL) }
  let(:payment_id) { "0x#{'ab' * 32}" }
  let(:json)       { { "Content-Type" => "application/json" } }

  describe "#330 — one transaction by id" do
    it "GETs the transaction path rather than the list" do
      stub_request(:get, "#{BASE_URL}/payments/#{payment_id}/transactions/tx-1")
        .to_return(status: 200, body: { id: "tx-1", operation: "capture" }.to_json, headers: json)

      tx = client.payments.get_transaction(payment_id, "tx-1")

      expect(tx).to include(id: "tx-1", operation: "capture")
    end
  end

  describe "#331 — Idempotency-Key on prepare" do
    it "sends the header when a key is given" do
      stub = stub_request(:post, "#{BASE_URL}/payments/#{payment_id}/capture/prepare")
             .with(headers: { "Idempotency-Key" => "k-1" })
             .to_return(status: 201, body: { id: "tx-1" }.to_json, headers: json)

      client.payments.capture_prepare(payment_id, "50.00", idempotency_key: "k-1")

      expect(stub).to have_been_requested
    end

    # The un-keyed call must send exactly what it sent before — an empty hash of
    # extra headers, not an empty-valued one.
    it "omits the header entirely when no key is given" do
      stub_request(:post, "#{BASE_URL}/payments/#{payment_id}/capture/prepare")
        .to_return(status: 201, body: { id: "tx-1" }.to_json, headers: json)

      client.payments.capture_prepare(payment_id, "50.00")

      expect(a_request(:post, "#{BASE_URL}/payments/#{payment_id}/capture/prepare")
               .with { |req| !req.headers.key?("Idempotency-Key") }).to have_been_made
    end

    it "threads the key through the dispute prepares too" do
      stub = stub_request(:post, "#{BASE_URL}/payments/#{payment_id}/dispute/prepare")
             .with(headers: { "Idempotency-Key" => "k-2" })
             .to_return(status: 201, body: { id: "tx-2" }.to_json, headers: json)

      client.payments.dispute_prepare(payment_id, idempotency_key: "k-2")

      expect(stub).to have_been_requested
    end
  end

  describe "#332 — total_pages and links" do
    it "folds the headers into meta and parses every rel" do
      link = [
        '</payments?page=1&per_page=2>; rel="first"',
        '</payments?page=1&per_page=2>; rel="prev"',
        '</payments?page=3&per_page=2>; rel="next"',
        '</payments?page=4&per_page=2>; rel="last"'
      ].join(", ")
      stub_request(:get, "#{BASE_URL}/payments")
        .to_return(status: 200, body: [{ id: "p1" }].to_json,
                   headers: json.merge("X-Total-Count" => "7", "X-Total-Pages" => "4",
                                       "X-Page" => "2", "X-Per-Page" => "2", "Link" => link))

      page = client.payments.list

      expect(page[:meta]).to include(total_pages: 4, page: 2)
      expect(page[:meta][:links]).to include(next: "/payments?page=3&per_page=2",
                                             last: "/payments?page=4&per_page=2")
    end

    # An empty collection sends no Link header at all, so an empty hash here means
    # "no pages" rather than "the header failed to parse".
    it "leaves links empty when the header is absent" do
      stub_request(:get, "#{BASE_URL}/payments")
        .to_return(status: 200, body: [].to_json,
                   headers: json.merge("X-Total-Count" => "0", "X-Total-Pages" => "0"))

      page = client.payments.list

      expect(page[:meta][:total_pages]).to eq(0)
      expect(page[:meta][:links]).to eq({})
    end
  end
end
