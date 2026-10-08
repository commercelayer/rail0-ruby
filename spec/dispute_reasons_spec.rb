# frozen_string_literal: true

require "eth"

# lib/rail0/dispute_reasons.rb is generated from the gateway's DisputeOpenReason /
# DisputeCloseReason / DisputeSystemCloseReason schemas. The generator copies each bytes32
# rather than computing it, so this re-derives every one — keccak256("rail0.dispute.<code>")
# — to catch a schema (or a generator) whose arrays fell out of index alignment.
RSpec.describe Rail0::DisputeReasons do
  let(:reasons) { Rail0::DisputeReasons }

  it "carries the gateway's three lists in dictionary order" do
    expect(reasons.codes(:open)).to eq(%w[not_received not_as_described damaged_or_defective duplicate
                                          incorrect_amount cancelled refund_not_received unauthorized other])
    expect(reasons.codes(:close)).to eq(%w[resolved_with_merchant withdrawn item_received other])
    expect(reasons.codes(:system)).to eq(%w[full_refund])
  end

  it "derives every bytes32 as keccak256(\"rail0.dispute.<code>\")" do
    Rail0::DisputeReasons::KINDS.each_value do |list|
      list.each do |r|
        expected = "0x#{Eth::Util.bin_to_hex(Eth::Util.keccak256("rail0.dispute.#{r.code}"))}"
        expect(r.bytes32).to eq(expected), "#{r.code}: #{r.bytes32} != #{expected}"
        expect(r.description).not_to be_empty
      end
    end
  end

  it "is frozen all the way down" do
    expect(Rail0::DisputeReasons::OPEN).to be_frozen
    expect(Rail0::DisputeReasons::OPEN).to all(be_frozen)
    expect(Rail0::DisputeReasons::KINDS).to be_frozen
  end

  describe ".find" do
    it "looks up by code, symbol code or bytes32 in either case" do
      entry = reasons.find(:open, "not_received")
      expect(entry.description).to eq("Goods or service not received")
      expect(reasons.find(:open, :not_received)).to eq(entry)
      expect(reasons.find("open", entry.bytes32.upcase.sub("0X", "0x"))).to eq(entry)
    end

    it "keeps the kinds apart, since 'other' is in both lists" do
      expect(reasons.find(:open, "withdrawn")).to be_nil
      expect(reasons.find(:close, "not_received")).to be_nil
      expect(reasons.find(:open, "other").bytes32).to eq(reasons.find(:close, "other").bytes32)
      expect(reasons.find(:open, "other").description).not_to eq(reasons.find(:close, "other").description)
    end

    it "answers nil for nil, the zero word and unknown codes" do
      expect(reasons.find(:open, nil)).to be_nil
      expect(reasons.find(:open, "0x#{'0' * 64}")).to be_nil
      expect(reasons.find(:close, "nope")).to be_nil
    end

    it "raises on an unknown kind" do
      expect { reasons.find(:reopen, "other") }.to raise_error(ArgumentError, /reopen/)
    end
  end

  describe ".valid?" do
    it "mirrors what the dispute prepares accept" do
      expect(reasons.valid?(:open, "not_received")).to be(true)
      expect(reasons.valid?(:close, "withdrawn")).to be(true)
      expect(reasons.valid?(:close, "full_refund")).to be(false)
      expect(reasons.valid?(:system, "full_refund")).to be(false)
      expect(reasons.valid?(:open, "0x#{'0' * 64}")).to be(false)
    end
  end

  describe ".description_for" do
    it "decodes a bytes32 and falls back to the gateway's unrecognised text" do
      full_refund = Rail0::DisputeReasons::SYSTEM.first.bytes32
      expect(reasons.description_for(:system, full_refund)).to eq("Closed automatically by a full refund")
      expect(reasons.description_for(:open, "0x#{'0' * 64}")).to eq("Unrecognised reason")
      expect(Rail0::DisputeReasons::UNRECOGNISED_DESCRIPTION).to eq("Unrecognised reason")
    end
  end
end
