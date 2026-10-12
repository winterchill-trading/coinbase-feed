(** A recorded Coinbase mainnet minute of BTC-USD under [fixtures/raw], in the
    market-recorder raw minute layout ([<recv_ts> <frame>] per line), one websocket
    connection per stream: [trades] ([market_trades]), [bbo] ([ticker]) and [l2]
    ([level2], with the snapshot trimmed to 50 levels a side). Each file is the first
    frames of 16:54 UTC, cut at a size budget, heartbeats and acks included. *)

open! Core

(** The [raw/...] root, usable as a market-recorder [data_dir]. *)
val data_dir : string

val date : Date.t
val streams : Market_data.Stream.t list

(** The frames of one stream with their receive times, in arrival order. *)
val frames : Market_data.Stream.t -> (Time_ns.t * string) list
