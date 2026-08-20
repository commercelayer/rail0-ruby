# frozen_string_literal: true

RSpec.describe Rail0::Resources::Accounts do
  let(:client) { Rail0::Client.new(base_url: BASE_URL) }
  let(:account_id) { "019f8a3d-b781-7b00-8b75-8427f7e591d2" }

  # One shape, one caller: the holder. Email is in the response because the gateway's
  # ownership guard makes the holder this endpoint's only possible caller, so the SDK
  # passes it through rather than narrowing it away.
  it "returns the holder's own profile" do
    stub_request(:get, "#{BASE_URL}/accounts/#{account_id}")
      .to_return(status: 200,
                 body: { id: account_id, name: "Test Merchant", email: "merchant@rail0.test",
                         created_at: "2026-08-01T00:00:00Z" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    profile = client.accounts.get(account_id)

    expect(profile).to include(id: account_id, name: "Test Merchant", email: "merchant@rail0.test")
  end

  # Another account's id and an unknown one answer alike on purpose, so a caller cannot use
  # the pair to learn whether an account exists. Both surface as the same error here.
  it "raises the same error for someone else's account as for an unknown one" do
    %w[403 404].each do |status|
      stub_request(:get, "#{BASE_URL}/accounts/#{account_id}")
        .to_return(status: status.to_i,
                   body: { code: "not_found", title: "Not found" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      expect { client.accounts.get(account_id) }.to raise_error(Rail0::ApiError)
    end
  end
end
