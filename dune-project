(lang dune 3.17)

(name coinbase-feed)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/coinbase-feed))

(package
 (name coinbase-feed)
 (synopsis "Read-only public market data feed for Coinbase spot")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  async_ssl
  venue-net
  market-data
  exchange-core
  ppx_jane
  ppx_yojson_conv
  ppx_yojson_conv_lib
  yojson
  uri
  (core_bench :with-test)))
