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

  describe "#update" do
    let(:path) { "#{BASE_URL}/accounts/#{account_id}" }
    let(:profile) do
      { id: account_id, name: "Merchant Ltd", email: "ops@merchant.example",
        created_at: "2026-08-01T00:00:00Z", updated_at: "2026-09-29T00:00:00Z" }
    end

    it "PATCHes only the fields passed and returns the updated profile" do
      stub = stub_request(:patch, path)
             .with(body: { email: "ops@merchant.example" }.to_json)
             .to_return(status: 200, body: profile.to_json,
                        headers: { "Content-Type" => "application/json" })

      result = client.accounts.update(account_id, email: "ops@merchant.example")

      expect(stub).to have_been_requested
      expect(result).to include(email: "ops@merchant.example")
    end

    it "sends name and email together" do
      stub = stub_request(:patch, path)
             .with(body: { name: "Merchant Ltd", email: "ops@merchant.example" }.to_json)
             .to_return(status: 200, body: profile.to_json,
                        headers: { "Content-Type" => "application/json" })

      client.accounts.update(account_id, name: "Merchant Ltd", email: "ops@merchant.example")

      expect(stub).to have_been_requested
    end

    # The gateway answers an empty PATCH with 400; refusing it here saves the round trip.
    it "raises ArgumentError without sending anything when no field is given" do
      expect { client.accounts.update(account_id) }.to raise_error(ArgumentError, /name or email/)
      expect(a_request(:patch, path)).not_to have_been_made
    end

    # `active` is the operator's field on this route; an owner sending it gets 403.
    it "does not expose the operator-only active field" do
      expect { client.accounts.update(account_id, active: false) }.to raise_error(ArgumentError)
    end

    it "surfaces a taken name or email as a 409" do
      stub_request(:patch, path)
        .to_return(status: 409, body: { code: "conflict", title: "Already exists" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      expect { client.accounts.update(account_id, name: "Taken") }
        .to raise_error(Rail0::ApiError) { |e| expect(e.status).to eq(409) }
    end

    it "surfaces a deactivated account's 403 with its own code" do
      stub_request(:patch, path)
        .to_return(status: 403, body: { code: "account_deactivated" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      expect { client.accounts.update(account_id, name: "X") }
        .to raise_error(Rail0::ApiError) { |e| expect(e.error).to eq("account_deactivated") }
    end
  end
end
