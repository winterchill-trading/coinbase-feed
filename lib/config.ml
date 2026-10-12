open! Core

type t = { url : Uri.t }

let sexp_of_t { url } = [%sexp { url = (Uri.to_string url : string) }]
let mainnet_url = Uri.of_string "wss://advanced-trade-ws.coinbase.com"
let mainnet = { url = mainnet_url }
let create ?(url = mainnet_url) () = { url }
