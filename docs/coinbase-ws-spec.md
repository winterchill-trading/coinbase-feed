# Coinbase public websocket: what this feed relies on

Sources: the Coinbase Advanced Trade websocket docs (overview, channels, rate limits) and
frames captured from the live endpoint on 2026-10-12. Coinbase lists spot products only on
this endpoint; there is no funding or mark price stream, so `Funding` is unsupported.

## Endpoint choice

| Endpoint | Public market data | Order book |
| --- | --- | --- |
| `wss://advanced-trade-ws.coinbase.com` (Advanced Trade) | yes, no JWT for market channels | `level2`: snapshot + updates, `sequence_num` |
| `wss://ws-feed.exchange.coinbase.com` (Exchange) | yes | `level2` and `full` need auth; `level2_batch` is public but carries no sequence numbers |

This feed uses Advanced Trade: its public `level2` is the only unauthenticated book stream
with sequence numbers to detect a lost message.

## Subscribing

One channel per message. Market data channels need no `jwt`:

```json
{"type":"subscribe","product_ids":["BTC-USD"],"channel":"market_trades"}
{"type":"unsubscribe","product_ids":["BTC-USD"],"channel":"level2"}
{"type":"subscribe","channel":"heartbeats"}
```

- A connection that has not sent a `subscribe` within 5 seconds is closed.
- Most channels close the subscription after 60-90 s without updates. Subscribe to
  `heartbeats` on every connection to keep it open (one frame per second).
- Unknown or private channels answer with an error frame and no envelope:
  `{"type":"error","message":"authentication failure"}`.
- The ack is a `subscriptions` frame listing everything subscribed on the connection:

```json
{"channel":"subscriptions","timestamp":"2026-10-12T12:41:51.796611103Z","sequence_num":2,
 "events":[{"subscriptions":{"heartbeats":["heartbeats"],"ticker_batch":["BTC-USD"]}}]}
```

## Envelope and sequencing

Every data frame is

```json
{"channel":"<name>","timestamp":"<RFC 3339, ns>","sequence_num":<int>,"events":[...]}
```

- `sequence_num` counts frames **per connection, across all channels** (data, `subscriptions`
  acks and heartbeats share one counter). It starts at `0` on a new connection.
- A jump of more than one means a frame was lost; a lower number is out of order or a new
  connection. The docs give no recovery procedure. For `level2` the only way to resync is a
  fresh snapshot: unsubscribe and subscribe the product again (the snapshot arrives
  first, with `"type":"snapshot"`). Verified live: after `unsubscribe` + `subscribe` on
  the same connection the server sends `subscriptions {}`, a new `snapshot`, then the
  `subscriptions` ack, and `sequence_num` keeps counting.
- There is no checksum.
- Channel names in frames differ from the subscription names: subscribing to `level2`
  delivers `"channel":"l2_data"`.

## Channels

### `market_trades` (trades)

Batches the trades of the last 250 ms. The first frame is a `snapshot` of recent trades,
newest first; later frames are `update`s, also newest first within a batch.

```json
{"channel":"market_trades","timestamp":"2026-10-12T12:41:57.536738524Z","sequence_num":2,
 "events":[{"type":"update","trades":[
  {"product_id":"BTC-USD","trade_id":"1105003397","price":"82666","size":"0.00011975",
   "time":"2026-10-12T12:41:57.443974Z","side":"SELL"},
  {"product_id":"BTC-USD","trade_id":"1105003396","price":"82665.99","size":"0.00000017",
   "time":"2026-10-12T12:41:57.426613Z","side":"BUY"}]}]}
```

`side` is the **maker** side (docs; confirmed live: prints at the ask carry `SELL`). The
taker (aggressor) side is the opposite. `trade_id` is a decimal integer string, increasing.

### `ticker` (best bid and offer)

Sent on every match, batched during cascades; the first frame is a `snapshot`. Carries the
top of book with sizes. There is no per-ticker timestamp; the envelope `timestamp` is the
only time.

```json
{"channel":"ticker","timestamp":"2026-10-12T12:41:49.204126545Z","sequence_num":3,
 "events":[{"type":"update","tickers":[{"type":"ticker","product_id":"BTC-USD",
  "price":"82659.51","volume_24_h":"3542.91343571","low_24_h":"82567.47",
  "high_24_h":"84261.99","low_52_w":"57717.55","high_52_w":"116410.06",
  "price_percent_chg_24_h":"-0.47065402101062","best_bid":"82662.26",
  "best_ask":"82662.27","best_bid_quantity":"0.0272185","best_ask_quantity":"0.0076"}]}]}
```

`ticker_batch` sends the last price every 5 s without bid/ask; it is not used.

### `level2` (order book, frames on `l2_data`)

```json
{"channel":"l2_data","timestamp":"2026-10-12T12:41:50.41147103Z","sequence_num":3,
 "events":[{"type":"update","product_id":"BTC-USD","updates":[
  {"side":"bid","event_time":"2026-10-12T12:41:49.866547Z","price_level":"82642.8","new_quantity":"0.0012084"},
  {"side":"bid","event_time":"2026-10-12T12:41:49.866547Z","price_level":"82622.77","new_quantity":"0"},
  {"side":"offer","event_time":"2026-10-12T12:41:49.866547Z","price_level":"82675.97","new_quantity":"0.00539207"}]}]}
```

- `type` is `snapshot` (the full book, every level) or `update`.
- `side` is `bid` or `offer`; `new_quantity` is the new absolute size at `price_level`,
  `"0"` removes the level.
- The BTC-USD snapshot is one text frame of about **4.5 MB** (the whole book, ~30k levels).
  Clients must accept large frames; it can arrive several seconds after its `event_time`.
- Observed ordering: the snapshot (seq 0) may be followed by an update (seq 1) before the
  `subscriptions` ack (seq 2).

### `heartbeats`

```json
{"channel":"heartbeats","timestamp":"2026-10-12T12:41:52.752094158Z","sequence_num":3,
 "events":[{"current_time":"2026-10-12 12:41:52.750927205 +0000 UTC m=+501283.250956184",
  "heartbeat_counter":501263}]}
```

One per second per connection. `current_time` is a Go debug string, not RFC 3339.

### `status`

Product metadata (`base_increment`, `quote_increment`, `status`) on a preset interval.
Not used.

## Ping / pong

No application-level ping. The server answers websocket ping control frames; the
`heartbeats` channel supplies one frame per second, which is enough for a silence watchdog.

## Rate limits

- Connections: 8 per second per IP.
- Unauthenticated messages (subscribe/unsubscribe): 8 per second per IP.

The feed opens one connection per stream (at most three) and sends one `subscribe` per
channel plus one for `heartbeats`, well inside both limits.

## Symbols

Product ids are `BASE-QUOTE`, e.g. `BTC-USD`, `ETH-USDC`, `SOL-EUR`. Prices and sizes are
decimal strings; at most 8 fractional digits are kept (sizes use 8, prices up to 8 on
small-cap products).
