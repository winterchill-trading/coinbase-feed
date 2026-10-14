# AGENTS.md: coinbase-feed/bench

Two benchmark executables, `main` and `live`, declared in `bench/dune` and built by
`@coinbase-feed/all`. `live` needs network access and is not run in CI.

Rules:
- Report words per call and ns per event, and name the platform whenever a number is kept
  in a comment or the README.
- Do not turn a benchmark result into a test threshold without a tolerance.
