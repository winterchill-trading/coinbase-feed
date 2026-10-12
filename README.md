# coinbase-feed

Read-only public market data feed for Coinbase spot, over the Advanced Trade websocket
(`wss://advanced-trade-ws.coinbase.com`), normalized to `market-data` records and exposed
as a `Market_data.Feed.t`. No API keys, no order entry.

The wire protocol, sample frames and sequencing rules are in
[docs/coinbase-ws-spec.md](docs/coinbase-ws-spec.md).

## Library

```ocaml
let%bind (module F) =
  Coinbase_feed.Live_feed.create
    Coinbase_feed.Config.mainnet
    ~symbols:[ "BTC-USD"; "ETH-USD" ]
    ~streams:[ Trades; Bbo; L2 ]
in
Pipe.iter_without_pushback F.trades ~f:(fun trade -> ...)
```

- `Config`: the mainnet endpoint, or a custom URL.
- `Wire`: decoders for the frames used (`market_trades`, `ticker`, `l2_data`,
  `subscriptions`, `heartbeats`, error frames) and the subscribe/unsubscribe requests.
- `Normalizer`: pure frame to event conversion with the per-connection state (sequence
  number, which books have their snapshot, last trade id per product).
- `Live_feed`: one websocket per stream (so `?on_raw` knows the stream of each raw frame),
  each subscribed to its channel and to `heartbeats`; reconnects with backoff and
  resubscribes; parse errors are logged, not fatal. `Live_feed.start` keeps a handle whose
  `stats` counts frames, parse errors and reconnects; `?time_source` (default the wall
  clock) stamps `recv_ts` and drives keepalives and reconnection backoff, so tests step
  them on a synthetic clock.
- `Raw_normalizer`: `Normalizer` as a `Market_data.Normalizer.S`, for rebuilding event
  logs from market-recorder raw files:
  `Market_data.Rebuild_norm.command [ (module Coinbase_feed.Raw_normalizer) ]`.

## Coverage

| Stream | Coinbase channel | Normalized as | Verified live |
| --- | --- | --- | --- |
| trades | `market_trades` | `Trade.t`, taker side = opposite of the wire's maker `side` | yes |
| bbo | `ticker` (`best_bid`, `best_bid_quantity`, `best_ask`, `best_ask_quantity`) | `Bbo.t` | yes |
| l2 | `level2` (frames on `l2_data`) | `L2_update.t` `Snapshot` then `Delta`s | yes |
| funding | none (spot only) | pipe closed immediately | n/a |

Live checks (2026-10-12): each stream on BTC-USD for 10 s, and all three on BTC-USD and
ETH-USD together for 110 s (past Coinbase's 60-90 s idle cutoff) with no sequence gap,
no reconnect and no parse error. Resubscribing `level2` on an open connection was checked
to produce a fresh snapshot.

## Command line

```sh
dune exec coinbase-feed -- feed -symbol BTC-USD -streams trades,bbo,l2,funding \
  [-count N] [-seconds S] [-print-depth N] [-raw] [-url URL]
```

`-symbol` takes one or more comma-separated product ids. `-print-depth` (default 5) only
shortens printed L2 messages. The command stops after `-count` events, after `-seconds`,
or when every requested stream has ended (`funding` ends at once).

Live output (run with `TZ=UTC`):

```
$ coinbase-feed feed -symbol BTC-USD -streams trades -count 2
(Trade
 ((instrument ((venue Coinbase) (symbol BTC-USD)))
  (exch_ts (2026-10-12 12:52:20.517738000Z))
  (recv_ts (2026-10-12 12:52:44.996842000Z)) (price 82825.09)
  (size 0.01931458) (side Buy) (trade_id 1105006569)))
(Trade
 ((instrument ((venue Coinbase) (symbol BTC-USD)))
  (exch_ts (2026-10-12 12:52:23.554153000Z))
  (recv_ts (2026-10-12 12:52:44.996842000Z)) (price 82825.09)
  (size 0.00035201) (side Buy) (trade_id 1105006570)))

$ coinbase-feed feed -symbol BTC-USD -streams bbo -count 2
(Bbo
 ((instrument ((venue Coinbase) (symbol BTC-USD)))
  (exch_ts (2026-10-12 12:52:45.757417906Z))
  (recv_ts (2026-10-12 12:52:45.739139000Z)) (bid_price 82810.18)
  (bid_size 0.08747091) (ask_price 82810.19) (ask_size 0.00302751)))
(Bbo
 ((instrument ((venue Coinbase) (symbol BTC-USD)))
  (exch_ts (2026-10-12 12:52:45.861748608Z))
  (recv_ts (2026-10-12 12:52:45.840501000Z)) (bid_price 82810.18)
  (bid_size 0.04947091) (ask_price 82810.19) (ask_size 0.00021701)))

$ coinbase-feed feed -symbol BTC-USD -streams l2 -count 2 -print-depth 2
(L2
 ((instrument ((venue Coinbase) (symbol BTC-USD)))
  (exch_ts (2026-10-12 12:52:46.686809000Z))
  (recv_ts (2026-10-12 12:52:53.215588000Z)) (kind Snapshot)
  (bids
   (((price 82809.62) (size 0.00010751))
    ((price 82807.23) (size 0.00390586))))
  (asks
   (((price 82809.63) (size 0.71452767)) ((price 82810.17) (size 0.024))))))
(L2
 ((instrument ((venue Coinbase) (symbol BTC-USD)))
  (exch_ts (2026-10-12 12:52:46.721608000Z))
  (recv_ts (2026-10-12 12:52:53.334011000Z)) (kind Delta)
  (bids (((price 82804.45) (size 0.09661315)) ((price 82802.9) (size 0))))
  (asks
   (((price 82809.63) (size 0.74170067))
    ((price 82810.18) (size 0.10898413))))))

$ coinbase-feed feed -symbol BTC-USD -streams funding
2026-10-12 12:52:53.354910Z Info coinbase feed: no funding on Coinbase spot, funding pipe closed
```

The first trades are the backlog Coinbase sends on subscribe (note `exch_ts` well before
`recv_ts`).

## Tests and benchmark

`test/fixtures/raw/coinbase/<stream>/BTC-USD/2026/10/12/16-54.ndjson` is a recorded
mainnet minute in the market-recorder raw layout (`<recv_ts> <frame>` per line), one
connection per stream, cut to the first frames of the minute to stay under 300 KB, with
the `level2` snapshot trimmed to 50 levels a side. Tests decode and normalize every frame
(trades: 108 frames, 298 trades; bbo: 135 frames, 111 quotes; l2: 122 frames, one
snapshot and 113 deltas, no gap), run `Rebuild_norm` over it into a temporary directory
and read the event logs back, and pin minor words per message with a small tolerance
(averages: trades 914, bbo 608, l2 1982 words per frame; the trimmed snapshot 33750).
`Live_feed` is tested against a scripted local websocket server: a malformed frame is
counted in `stats`, and a dropped connection reconnects on a synthetic clock.

```sh
dune exec --profile release ./bench/main.exe -- -quota 2
```

On an M-series Mac: `trades` 6.2 us and 865 words per frame, `bbo` 4.0 us and 611 words,
`l2 replay` (fresh normalizer, snapshot and 121 frames) 1.73 ms.

## Symbol conventions

Coinbase product ids, `BASE-QUOTE` in upper case: `BTC-USD`, `ETH-USDC`, `SOL-EUR`. The
instrument is `coinbase:<product id>`, e.g. `coinbase:BTC-USD`.

## Limitations

- Spot only: no funding, mark or index price. The Feed.S `funding` pipe is closed at
  creation; consumers that wait for it to produce should check `Pipe.is_closed`.
- `ticker` has no venue timestamp per ticker; `Bbo.exch_ts` is the frame's envelope
  timestamp. The local clock can be ahead of it by a few milliseconds.
- `ticker` is sent on matches, not on every top-of-book change, so quotes that move
  without a trade are not seen until the next match. Building BBO from `level2` would
  catch them at the cost of the full book.
- The `level2` snapshot is the whole book in one ~4.5 MB frame (BTC-USD) and can arrive
  seconds after its `event_time`; `L2_update.exch_ts` is the latest `event_time` in the
  message.
- `sequence_num` counts per connection across channels, so a gap cannot be attributed to
  one product: every synced book on the `level2` connection is resubscribed. There is no
  checksum. Gap recovery is covered by tests; no gap was seen live.
- Trades are de-duplicated by numeric `trade_id` per product, so the backlog resent after
  a reconnect is not printed twice. Trades lost during a disconnect beyond that backlog
  are not recovered.
- Prices and sizes keep 8 decimal places (the `market-data` fixed point).

## CI

CI installs the pinned siblings and the opam dependencies through the shared
[ox-setup](https://github.com/winterchill-trading/infra/blob/main/docs/ci.md) action, which
caches the built opam switch between runs.
