# frozen_string_literal: true

module Rail0
  # How long to wait before retrying a request the gateway rate-limited.
  #
  # Pure, and its own module, because the two interesting decisions here are easy to get
  # backwards and impossible to notice once they are wrong — a client that waits too
  # little walks straight back into the limiter, and one that waits too long looks hung.
  #
  # 1. JITTER IS ADDITIVE ON A SERVER-INSTRUCTED WAIT, MULTIPLICATIVE ON A GUESS.
  #    The textbook "full jitter" multiplies the delay by rand(), which is right for a
  #    backoff we invented — it spreads a thundering herd — and wrong for a Retry-After:
  #    scaling the server's own number DOWN means retrying before the window it named has
  #    passed, which is a second 429 by construction. So an instructed wait is honoured in
  #    full and a small random tail is ADDED; a guessed one is jittered the usual way.
  #
  #    Why any jitter at all when the server told us the time: because callers align on
  #    it. rail0-admin proxies every merchant over ONE session, so they share the
  #    per-session bucket and would all be told the same Retry-After, wake together, and
  #    recreate the burst the limiter just rejected.
  #
  # 2. THE CAP IS NOT PARANOIA. The gateway sends the WHOLE period as Retry-After
  #    (rack_attack.rb: `headers["retry-after"] = match_data[:period].to_s`), not the time
  #    remaining in the window — so hitting the limit one second in is told to wait the
  #    full 60. Capping bounds both that over-wait and a hostile or misconfigured value
  #    from anything between the client and the gateway.
  module Backoff
    module_function

    # @param retry_after [Integer, Float, nil] the server's Retry-After, in seconds.
    #   Absent, unparseable, zero or negative all mean "no instruction" — and zero is the
    #   trap: it is a valid duration, so treating it as one produces a burst of
    #   back-to-back requests against the very limiter that asked for a pause.
    # @param attempt [Integer] 1 for the first retry, 2 for the second, …
    # @param base [Float] the exponential backoff's first delay, in seconds.
    # @param cap [Float] the longest wait to allow, in seconds.
    # @param jitter [Float, nil] randomness in [0,1); injected only by tests. Nil draws it.
    # @return [Float] seconds to sleep.
    def throttle_delay(retry_after:, attempt:, base:, cap:, jitter: nil)
      random = jitter || Kernel.rand
      instructed = positive_number(retry_after)

      if instructed
        # Honour it in full (clamped), plus a fraction of one base delay so aligned
        # callers do not wake in lockstep.
        [instructed, cap].min + (random * base)
      else
        # No instruction: exponential from `base`, full jitter, clamped.
        [base * (2**(attempt - 1)) * random, cap].min
      end
    end

    # @return [Float, nil] the value when it is a positive number, else nil.
    def positive_number(value)
      number = Float(value, exception: false)
      number&.positive? ? number : nil
    end
  end
end
