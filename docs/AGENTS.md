# AGENTS.md: coinbase-feed/docs

`coinbase-ws-spec.md` records the channel behaviour the code depends on: subscribe
messages, the sequence rules, heartbeats and the snapshot shape.

Rules:
- Update it in the same commit as any change in `lib/wire.ml` or `lib/normalizer.ml` that
  depends on a channel fact.
- Record facts observed from live captures with the capture date.
