# frozen_string_literal: true

# Every caller-supplied value interpolated into a request path goes through
# Query#segment, so an id carrying `/`, `?`, `#` or `..` stays inside its own
# segment instead of re-targeting the request at another route with the caller's
# token.
RSpec.describe Rail0::Resources::Query do
  describe "#segment" do
    subject(:builder) { Class.new { include Rail0::Resources::Query }.new }

    def segment(value)
      builder.send(:segment, value)
    end

    it "leaves the ids the gateway hands out unchanged" do
      expect(segment(PAYMENT_ID)).to eq(PAYMENT_ID)
      expect(segment(PAYMENT_UUID)).to eq(PAYMENT_UUID)
      expect(segment("capture")).to eq("capture")
      expect(segment(42)).to eq("42")
    end

    {
      "a/b" => "a%2Fb",
      "a?b=c" => "a%3Fb%3Dc",
      "a#b" => "a%23b",
      "../webhooks/x" => "..%2Fwebhooks%2Fx",
      "a b" => "a%20b",
      "a+b" => "a%2Bb",
      "a%2Fb" => "a%252Fb",
      "pé€" => "p%C3%A9%E2%82%AC",
      "a.b-c_d~e" => "a.b-c_d~e"
    }.each do |raw, escaped|
      it "escapes #{raw.inspect} as #{escaped.inspect}" do
        expect(segment(raw)).to eq(escaped)
      end
    end

    [nil, "", ".", ".."].each do |value|
      it "rejects #{value.inspect} with ArgumentError" do
        expect { segment(value) }.to raise_error(ArgumentError, /invalid path segment/)
      end
    end

    it "accepts dots that are not the whole segment" do
      expect(segment("...")).to eq("...")
      expect(segment(".a")).to eq(".a")
    end
  end

  # End to end: the request_uri Net::HTTP is handed — what goes on the wire, before
  # WebMock or anything else normalises it.
  describe "request paths built by resource methods" do
    let(:client) { Rail0::Client.new(base_url: BASE_URL, token: "jwt") }

    before do
      stub_request(:any, /api\.rail0\.xyz/)
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    end

    def wire_path(verb)
      captured = nil
      allow(verb).to receive(:new).and_wrap_original do |original, uri, *rest|
        captured = uri
        original.call(uri, *rest)
      end
      yield
      captured
    end

    hostile = {
      "/" => ["a/b", "a%2Fb"],
      "?" => ["a?admin=1", "a%3Fadmin%3D1"],
      "#" => ["a#frag", "a%23frag"],
      ".." => ["../webhooks/x", "..%2Fwebhooks%2Fx"],
      "space" => ["a b", "a%20b"],
      "unicode" => ["pé€", "p%C3%A9%E2%82%AC"]
    }

    hostile.each do |label, (raw, escaped)|
      context "with an id containing #{label}" do
        it "payments.get keeps it in one segment" do
          path = wire_path(Net::HTTP::Get) { client.payments.get(raw) }
          expect(path).to eq("/payments/#{escaped}")
        end

        it "payments.get_transaction escapes both ids" do
          path = wire_path(Net::HTTP::Get) { client.payments.get_transaction(raw, raw) }
          expect(path).to eq("/payments/#{escaped}/transactions/#{escaped}")
        end

        it "webhooks.redeliver escapes both ids" do
          path = wire_path(Net::HTTP::Post) { client.webhooks.redeliver(raw, raw) }
          expect(path).to eq("/webhooks/#{escaped}/event_callbacks/#{escaped}/redeliver")
        end

        it "accounts.update keeps it in one segment" do
          path = wire_path(Net::HTTP::Patch) { client.accounts.update(raw, name: "x") }
          expect(path).to eq("/accounts/#{escaped}")
        end

        it "wallets.remove_token escapes all three ids" do
          path = wire_path(Net::HTTP::Delete) { client.wallets.remove_token(raw, raw, raw) }
          expect(path).to eq("/accounts/#{escaped}/wallets/#{escaped}/tokens/#{escaped}")
        end

        it "payments.submit escapes the operation too" do
          path = wire_path(Net::HTTP::Post) { client.payments.submit(PAYMENT_ID, raw, {}) }
          expect(path).to eq("/payments/#{PAYMENT_ID}/#{escaped}")
        end
      end
    end

    it "keeps the query string separate from an escaped id" do
      path = wire_path(Net::HTTP::Get) { client.wallets.balances(ACCOUNT_ID, "a?b", chain_id: 1) }
      expect(path).to eq("/accounts/#{ACCOUNT_ID}/wallets/a%3Fb/balances?chain_id=1")
    end

    it "leaves the literal multi-segment dispute paths intact" do
      path = wire_path(Net::HTTP::Post) { client.payments.close_dispute_prepare(PAYMENT_ID, reason: "withdrawn") }
      expect(path).to eq("/payments/#{PAYMENT_ID}/dispute/close/prepare")
    end

    [".", "..", ""].each do |value|
      it "raises before any request for an id of #{value.inspect}" do
        expect { client.payments.get(value) }.to raise_error(ArgumentError)
        expect { client.webhooks.delete(value) }.to raise_error(ArgumentError)
        expect(a_request(:any, /api\.rail0\.xyz/)).not_to have_been_made
      end
    end
  end
end
