# AGENTS.md: coinbase-feed/bin

The `coinbase-feed` command (`main.ml`): `feed` with `-symbol`, `-streams`, `-count`,
`-seconds` and `-raw`. The full flags are in `../README.md`.

Build: `opam exec --switch 5.2.0+ox -- dune build --root .. @coinbase-feed/all`.

Rules:
- The command reads only public channels. Do not add a code path that needs a key.
- `-raw` prints truncated raw frames to stderr; it does not write files.
