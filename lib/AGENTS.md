# AGENTS.md: coinbase-feed/lib

The `coinbase-feed` library (module `Coinbase_feed`).

| Module | Holds |
| --- | --- |
| `Config` | Mainnet endpoint or a custom URL |
| `Wire` | Decoders for `market_trades`, `ticker`, `l2_data`, subscriptions, heartbeats, errors; subscribe requests |
| `Normalizer` | Pure frame to event conversion with per-connection state: sequence, synced books, last trade id per product |
| `Live_feed` | One websocket per stream, reconnect and resubscribe, `stats`, `feed_with_gaps`, `?time_source` |
| `Raw_normalizer` | `Normalizer` as a `Market_data.Normalizer.S` for `Rebuild_norm` over recorded raw minutes |

Build: `opam exec --switch 5.2.0+ox -- dune build --root .. @coinbase-feed/all`.

Rules:
- `Normalizer` does no I/O and no clock reads; time arrives as `recv_ts`.
- A reconnect writes its gap before the first frame of the new connection is handled.
- Wire decoding stays in `Wire`; never decode JSON inside `Normalizer`.
- Public values carry odoc comments.
