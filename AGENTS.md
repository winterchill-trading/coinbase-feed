# AGENTS.md: coinbase-feed

## Purpose

Read-only public market data for Coinbase spot over the Advanced Trade websocket. It
normalizes trades, best bid and offer, and L2 books into `Market_data` records and reports
gaps on reconnects. No API keys and no order entry.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | The library `coinbase-feed` (module `Coinbase_feed`): config, wire decoders, normalizer, live feed, raw normalizer (see `lib/AGENTS.md`) |
| `bin/` | The `coinbase-feed` command: live feed, raw recording (see `bin/AGENTS.md`) |
| `bench/` | Live and offline benchmarks (see `bench/AGENTS.md`) |
| `test/` | Fixture, fake websocket, delivery and allocation tests; `test/fixtures/` holds recorded raw minutes (see `test/AGENTS.md`) |
| `docs/` | `coinbase-ws-spec.md`: the channel facts this code relies on (see `docs/AGENTS.md`) |
| `.github/` | CI workflow and the shared obj-magic check (see `.github/AGENTS.md`) |
| `README.md` | Streams, command line, gaps, limitations |
| `dune-project` | Package metadata; edit this, not the generated `coinbase-feed.opam` |

## Build, test

Run from this repository. The workspace root is one level up, so every command takes
`--root ..`.

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @coinbase-feed/all
opam exec --switch 5.2.0+ox -- dune build --root .. @coinbase-feed/runtest
```

Parallel work with another agent: prefix both with `DUNE_BUILD_DIR=_build-coinbase-feed`.

Standalone (outside the workspace): the org opam repository is the target for published
packages (see `../specs/repos/opam-repository.md`). Until a package is there, pin the
siblings from the CI list below in order, then `opam install . --deps-only --with-test`
and `dune build`.

## Conventions

- Format only this repository: `dune build --root .. @coinbase-feed/fmt --auto-promote`.
  Never run `dune fmt` at the workspace root.
- Every module has an `.mli`. Consume siblings by public opam name.
- Pure normalization in `Normalizer`; I/O only in `Live_feed`. Tests drive the normalizer
  with recorded frames.
- Allocation pins: the word counts in `test/test_allocation.ml` are measured on one
  platform. Where they differ between macOS arm64 and Linux amd64, the test carries a
  comment and a tolerance; keep both values in sync when changing either.
- Comments for humans at non-obvious choices (sequence rules, gap timing).

## Dependencies and dependents

Sibling checkouts: `fixed-decimal`, `exchange-core`, `parquet`, `market-data`,
`venue-net`. CI pins them in that order (`.github/workflows/ci.yml`). The recorder and
replay tools in `../market-recorder` and `../market-replay` consume this feed's
`Raw_normalizer`.

## CI

`.github/workflows/ci.yml`: checkout, the shared `ox-setup` action (opam switch cache keyed
on the pins), `dune build`, `dune test`, then the reusable obj-magic workflow from
`../infra`. Pushes cancel the running job; push once per finished change.

To check a run: one `gh run list --limit 1`, then at most one `gh run watch <id>
--exit-status`. Never poll in a loop.

## Pitfalls

- Coinbase `sequence_num` counts per connection across all channels. One sequence break
  means every synced product on that socket is out of sync: one gap per product, one
  resubscribe.
- `market_trades` `side` is the maker's side. The taker is the opposite.
- Trade batches arrive newest first, and every subscribe resends a backlog. De-duplicate
  by trade id.
- Coinbase closes idle channels after 60 to 90 s unless `heartbeats` is subscribed, and
  drops a connection that sends no subscribe within 5 s of connecting.
- The `level2` channel needs authentication on this API; use `l2_data` on Advanced Trade.
  The BTC-USD snapshot is one 4.5 MB frame, so size buffers for it.
- A replay must renumber `sequence_num` and drop recorded subscriptions and heartbeats, or
  the replayed stream looks like a gap.

## Where to read more

- `README.md`: streams, command line, gaps and reconnects, tests and benchmark.
- `docs/coinbase-ws-spec.md`: the channel facts.
- `../specs/repos/coinbase-feed.md`: key modules and status.
- `../market-data/`: the `Feed.S` and `Gap` types this repository produces.
- `../oxcaml-claude-skills/skills/oxcaml-performance/`: for the scanner and allocation work.
- `../oxcaml-claude-skills/AGENTS.md`: workspace-wide guide.
- `../oxcaml-claude-skills/GOTCHAS.md`: the feed repositories sections.

## Never do

- Install opam packages that change the compiler or `core`, `base`, `async`, `ppx_jane`
  on the shared `5.2.0+ox` switch. Dry-run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Publish, tag or release.
- Commit credentials or print secrets.
- Poll CI in loops.
