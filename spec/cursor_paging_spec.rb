# frozen_string_literal: true

require "spec_helper"

# Cursor paging on GET /payments and GET /payouts: `after:` in, `meta[:next_cursor]` out
# (x-next-cursor, else the Link next's `after`). Page-number paging is unchanged.
RSpec.describe "cursor paging" do
  let(:client) { Rail0::Client.new(base_url: BASE_URL, token: "jwt") }
  let(:json)   { { "Content-Type" => "application/json" } }

  it "sends after: and exposes x-next-cursor on payments.list" do
    stub_request(:get, "#{BASE_URL}/payments?per_page=2&after=c1")
      .to_return(status: 200, body: [{ id: "p3" }, { id: "p4" }].to_json,
                 headers: json.merge("X-Per-Page" => "2", "X-Next-Cursor" => "c2",
                                     "Link" => '</payments?per_page=2&after=c2>; rel="next"'))

    page = client.payments.list(per_page: 2, after: "c1")

    expect(page[:data].map { |r| r[:id] }).to eq(%w[p3 p4])
    expect(page[:meta][:next_cursor]).to eq("c2")
    expect(page[:meta][:total]).to eq(0)
  end

  it "falls back to the Link next's after when the header is missing" do
    stub_request(:get, "#{BASE_URL}/payouts?per_page=2&after=c1")
      .to_return(status: 200, body: [].to_json,
                 headers: json.merge("Link" => '</payouts?per_page=2&after=c%2B2>; rel="next"'))

    expect(client.payouts.list(per_page: 2, after: "c1")[:meta][:next_cursor]).to eq("c+2")
  end

  it "is nil on the last cursor page and on offset pages" do
    stub_request(:get, "#{BASE_URL}/payouts?after=c9")
      .to_return(status: 200, body: [].to_json, headers: json)
    stub_request(:get, "#{BASE_URL}/payments?page=1&per_page=2")
      .to_return(status: 200, body: [{ id: "p1" }].to_json,
                 headers: json.merge("X-Page" => "1", "X-Total-Count" => "3", "X-Total-Pages" => "2",
                                     "Link" => '</payments?page=2&per_page=2>; rel="next"'))

    expect(client.payouts.list(after: "c9")[:meta][:next_cursor]).to be_nil
    offset = client.payments.list(page: 1, per_page: 2)
    expect(offset[:meta]).to include(page: 1, total: 3, total_pages: 2, next_cursor: nil)
  end

  it "walks a whole collection by following next_cursor" do
    stub_request(:get, "#{BASE_URL}/payouts?per_page=1")
      .to_return(status: 200, body: [{ id: "a" }].to_json, headers: json.merge("X-Next-Cursor" => "k1"))
    stub_request(:get, "#{BASE_URL}/payouts?per_page=1&after=k1")
      .to_return(status: 200, body: [{ id: "b" }].to_json, headers: json)

    ids = []
    cursor = nil
    loop do
      page = client.payouts.list(per_page: 1, after: cursor)
      ids.concat(page[:data].map { |r| r[:id] })
      cursor = page[:meta][:next_cursor]
      break if cursor.nil?
    end

    expect(ids).to eq(%w[a b])
  end
end
