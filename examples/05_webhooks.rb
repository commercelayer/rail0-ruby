# frozen_string_literal: true

# Manage webhook subscriptions (requires a JWT).
#
# A subscription carries a set of topics and delivers a signed POST to your
# callback URL when that event fires. The shared secret used to verify delivery
# signatures is shown only once, on create and rotate.

require "rail0"

PAYEE_KEY = ENV.fetch("PAYEE_PRIVATE_KEY")

client = Rail0::Client.new(base_url: "https://api.rail0.xyz")

# Authenticate — webhook management is JWT-gated.
auth = client.auth.login(private_key: PAYEE_KEY, domain: "api.rail0.xyz")
api  = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  headers:  { "Authorization" => "Bearer #{auth[:token]}" }
)

# ── Create a webhook ──────────────────────────────────────────────────────────
hook = api.webhooks.create(
  name:         "captured-orders",
  callback_url: "https://merchant.example/rail0/webhook",
  # One subscription for the whole order lifecycle: one secret to verify against, one
  # circuit breaker. See Rail0::Resources::Webhooks::TOPICS.
  topics:       %w[payments.authorized payments.captured payments.voided payments.refunded]
)
puts "Created webhook #{hook[:id]}"
puts "Shared secret (store it now — shown only once): #{hook[:shared_secret]}"

# ── List / inspect ────────────────────────────────────────────────────────────
api.webhooks.list(active: true)[:data].each do |w|
  puts "  #{w[:id]} #{Array(w[:topics]).join(',')} circuit=#{w[:circuit_state]}"
end

# ── Update the callback URL ───────────────────────────────────────────────────
api.webhooks.update(hook[:id], callback_url: "https://merchant.example/rail0/hook-v2")

# ── Rotate the secret (returns a fresh one) ───────────────────────────────────
rotated = api.webhooks.rotate_secret(hook[:id])
puts "New secret: #{rotated[:shared_secret]}"

# ── Review recent delivery attempts (paginated envelope) ──────────────────────
api.webhooks.event_callbacks(hook[:id], status: "failed")[:data].each do |cb|
  puts "  delivery #{cb[:status]} → #{cb[:response_code]}"
end

# ── Temporarily disable, then re-enable ───────────────────────────────────────
api.webhooks.disable(hook[:id])
api.webhooks.enable(hook[:id])

# ── If the delivery circuit tripped after repeated failures, reset it ─────────
api.webhooks.reset_circuit(hook[:id])
