# frozen_string_literal: true

module Rail0
  # How long to wait before retrying a request the gateway rate-limited.
  #
  # Pure, and its own module, because the two interesting decisions here are easy to get
  # backwards and impossible to notice once they are wrong — a client that waits too
  # little walks straight back into the limiter, and one that waits too long looks hung.
  #
  # 1. JITTER NEVER SHORTENS THE WAIT BELOW WHAT IT IS FOR.
  #    On a server-instructed wait it is ADDITIVE: scaling a Retry-After DOWN means retrying
  #    before the window the server named has passed, which is a second 429 by construction.
  #    So the instruction is honoured in full and a small random tail is added.
  #
  #    On a guessed wait it is EQUAL jitter — half the delay fixed, half random — not the
  #    textbook "full jitter" that multiplies the whole delay by rand(). Full jitter can
  #    land arbitrarily close to zero, which makes a real pause indistinguishable from the
  #    bug where a Retry-After of "0" is honoured as a duration and the retry fires
  #    immediately. A floor spreads the herd just as well and leaves "did we actually wait"
  #    observable.
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
        # No instruction: exponential from `base`, EQUAL jitter (half fixed, half random),
        # clamped.
        full = base * (2**(attempt - 1))
        [(full / 2.0) + ((full / 2.0) * random), cap].min
      end
    end

    # @return [Float, nil] the value when it is a positive number, else nil.
    def positive_number(value)
      number = Float(value, exception: false)
      number&.positive? ? number : nil
    end
  end
end
