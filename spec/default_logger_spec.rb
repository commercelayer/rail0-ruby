require "stringio"

RSpec.describe Rail0::DefaultLogger do
  def entry(**overrides)
    Rail0::LogEntry.new(
      method: "GET", url: "https://api.rail0.xyz/health", duration_ms: 12.3,
      status: 200, **overrides
    )
  end

  it "is a Logger subclass" do
    expect(described_class.ancestors).to include(Logger)
  end

  it "defaults to logging on $stdout" do
    expect { described_class.new.call(entry) }.to output(/\[rail0\]/).to_stdout
  end

  it "accepts any Logger.new argument, e.g. an explicit IO" do
    io = StringIO.new
    described_class.new(io).call(entry)
    expect(io.string).to include("[rail0]")
  end

  it "logs a successful attempt at :debug" do
    io = StringIO.new
    logger = described_class.new(io, level: Logger::DEBUG)
    logger.call(entry)
    expect(io.string).to include("DEBUG")
    expect(io.string).to include("GET")
    expect(io.string).to include("200")
  end

  it "logs a failed attempt at :error" do
    io = StringIO.new
    logger = described_class.new(io, level: Logger::ERROR)
    logger.call(entry(status: nil, error: RuntimeError.new("boom")))
    expect(io.string).to include("ERROR")
    expect(io.string).to include("boom")
  end

  it "suppresses successful attempts when the level is raised above :debug" do
    io = StringIO.new
    logger = described_class.new(io, level: Logger::ERROR)
    logger.call(entry)
    expect(io.string).to be_empty
  end

  it "includes the retry marker when will_retry is set" do
    io = StringIO.new
    described_class.new(io).call(entry(attempt: 1, will_retry: true, error: RuntimeError.new("timeout")))
    expect(io.string).to include("[attempt 1, retrying]")
  end

  it "omits the attempt bracket for a plain single, non-retried attempt" do
    io = StringIO.new
    described_class.new(io).call(entry(attempt: 1, will_retry: false))
    expect(io.string).not_to include("[attempt")
  end

  it "shows the attempt number (without a retrying suffix) once a later attempt succeeds" do
    io = StringIO.new
    described_class.new(io).call(entry(attempt: 2))
    expect(io.string).to include("[attempt 2]")
    expect(io.string).not_to include("retrying")
  end
end

RSpec.describe "Rail0::DEFAULT_LOGGER" do
  it "is a frozen DefaultLogger instance" do
    expect(Rail0::DEFAULT_LOGGER).to be_a(Rail0::DefaultLogger)
    expect(Rail0::DEFAULT_LOGGER).to be_frozen
  end

  it "can still log despite being frozen" do
    # DEFAULT_LOGGER is bound to the $stdout object at library-load time, not
    # per-call, so RSpec's output().to_stdout (which swaps the $stdout global
    # per-example) can't intercept it -- it would actually print to the real
    # terminal. Reopen that same IO object's file descriptor to /dev/null for
    # the duration of the call instead, then restore it.
    entry = Rail0::LogEntry.new(method: "GET", url: "https://api.rail0.xyz/health", duration_ms: 1.0, status: 200)
    original_stdout = $stdout.dup
    $stdout.reopen(File::NULL, "w")
    begin
      expect { Rail0::DEFAULT_LOGGER.call(entry) }.not_to raise_error
    ensure
      $stdout.reopen(original_stdout)
      original_stdout.close
    end
  end

  it "rejects reconfiguration since it is shared and frozen" do
    expect { Rail0::DEFAULT_LOGGER.level = Logger::WARN }.to raise_error(FrozenError)
  end
end

RSpec.describe Rail0::NullLogger do
  it "silently discards whatever it's called with" do
    expect(described_class.new.call(Rail0::LogEntry.new(method: "GET"))).to be_nil
  end
end

RSpec.describe "Rail0::NULL_LOGGER" do
  it "is a frozen, shared NullLogger instance" do
    expect(Rail0::NULL_LOGGER).to be_a(Rail0::NullLogger)
    expect(Rail0::NULL_LOGGER).to be_frozen
  end

  it "is reused by every HttpClient built without an explicit logger" do
    a = Rail0::HttpClient.new(base_url: "https://api.rail0.xyz")
    b = Rail0::HttpClient.new(base_url: "https://api.rail0.xyz")
    expect(a.logger).to equal(Rail0::NULL_LOGGER)
    expect(a.logger).to equal(b.logger)
  end
end
