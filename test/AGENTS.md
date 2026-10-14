# AGENTS.md: coinbase-feed/test

Expect and property tests. `fake_ws.ml` is an in-memory websocket. `fixtures/` holds
recorded raw minutes for Coinbase BTC-USD, read through `fixture.ml`. `test_allocation.ml`
pins word counts, `test_delivery.ml` checks that the pipe and the `on_message` paths
produce identical events, gaps and stats.

Run: `opam exec --switch 5.2.0+ox -- dune build --root .. @coinbase-feed/runtest`.

Rules:
- Copy fixtures with `cp -RL` if you duplicate them; dune's sandbox holds them as symlinks.
- Promote only after reading the diff, and only after a successful `@runtest` build.
- Never print an absolute path in expect output; print the file name.
- A pinned allocation count changes only with a comment saying why.
