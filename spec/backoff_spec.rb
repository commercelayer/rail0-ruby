RSpec.describe Rail0::Backoff do
  # The two decisions that are easy to get backwards, and invisible once they are:
  # a client that waits too little walks back into the limiter, one that waits too long
  # looks hung.

  describe ".throttle_delay" do
    it "honours a server-instructed wait in full, and only ADDS jitter" do
      # Scaling the gateway's own number down (textbook full jitter) means retrying
      # before the window it named has passed — a second 429 by construction.
      delay = described_class.throttle_delay(retry_after: 30, attempt: 1, base: 0.2, cap: 60,
                                             jitter: 0.5)
      expect(delay).to be_within(0.001).of(30.1)
      expect(delay).to be > 30
    end

    it "caps an instructed wait, because the gateway sends the whole period" do
      # rack_attack.rb sends `period`, not the time remaining, so a limit hit one second
      # into the window still asks for the full 60.
      delay = described_class.throttle_delay(retry_after: 3600, attempt: 1, base: 0.2, cap: 60,
                                             jitter: 0)
      expect(delay).to eq(60)
    end

    it "falls back to a jittered exponential backoff when there is no instruction" do
      %w[nil empty garbage].zip([nil, "", "soon"]).each do |_label, value|
        delay = described_class.throttle_delay(retry_after: value, attempt: 3, base: 0.2,
                                               cap: 60, jitter: 1.0)
        # base * 2^(attempt-1) = 0.2 * 4
        expect(delay).to be_within(0.001).of(0.8)
      end
    end

    it "treats a zero or negative Retry-After as no instruction, never as a duration" do
      # Zero IS a valid duration, which is the trap: honouring it produces a burst of
      # back-to-back requests against the limiter that just asked for a pause.
      [0, "0", -5].each do |value|
        delay = described_class.throttle_delay(retry_after: value, attempt: 1, base: 0.5,
                                               cap: 60, jitter: 1.0)
        expect(delay).to eq(0.5)
      end
    end

    it "keeps the exponential path under the cap too" do
      delay = described_class.throttle_delay(retry_after: nil, attempt: 12, base: 1, cap: 60,
                                             jitter: 1.0)
      expect(delay).to eq(60)
    end

    it "draws its own jitter when none is injected" do
      delays = Array.new(20) do
        described_class.throttle_delay(retry_after: 10, attempt: 1, base: 1, cap: 60)
      end
      expect(delays.uniq.size).to be > 1        # actually random
      expect(delays).to all(be_between(10, 11)) # and always at least the instruction
    end
  end

  describe ".positive_number" do
    it "accepts numbers and numeric strings, rejects everything else" do
      expect(described_class.positive_number("30")).to eq(30.0)
      expect(described_class.positive_number(1.5)).to eq(1.5)
      [nil, "", "abc", 0, "0", -1].each do |value|
        expect(described_class.positive_number(value)).to be_nil
      end
    end
  end
end
