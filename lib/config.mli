(** Where the feed connects. *)

open! Core

type t = { url : Uri.t } [@@deriving sexp_of]

(** [wss://advanced-trade-ws.coinbase.com], the public market data endpoint. *)
val mainnet_url : Uri.t

val mainnet : t

(** [mainnet] unless [url] is given (e.g. a local test server). *)
val create : ?url:Uri.t -> unit -> t
