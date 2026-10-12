(** A live {!Market_data.Feed.t} over the Coinbase Advanced Trade public websocket.
    Read-only, no credentials.

    Each requested stream gets its own {!Venue_net.Ws_client} connection (so [on_raw]
    knows the stream of every frame, and [sequence_num] gaps are tracked per connection),
    subscribed to its channel for all [symbols] plus [heartbeats], which keeps idle
    subscriptions open:

    - [Trades]: [market_trades];
    - [Bbo]: [ticker];
    - [L2]: [level2] (frames on [l2_data]).

    [Funding] is not available on Coinbase spot: its pipe is closed immediately, and no
    connection is opened for it. Conversion rules are in {!Normalizer}.

    [recv_ts] is [Time_ns.now ()] when the frame is received. [on_raw] gets that frame
    unparsed, first, including acks and heartbeats. Undecodable frames and error frames
    are logged and skipped.

    On a disconnect the client reconnects with exponential backoff and subscribes again;
    Coinbase answers with a fresh [level2] snapshot, which is emitted as usual. A sequence
    gap on the [level2] connection unsubscribes and resubscribes the affected products to
    get a new snapshot. Writes do not wait for readers, so consumers should keep up. *)

open! Core
open Async

(** The channel subscribed for a stream; [None] for [Funding] (and [Private]). *)
val channel : Market_data.Stream.t -> string option

(** Raises if a first connection fails, or if [streams] contains [Private]. *)
val create
  :  ?on_raw:(stream:Market_data.Stream.t -> recv_ts:Time_ns.t -> string -> unit)
  -> Config.t
  -> symbols:string list
  -> streams:Market_data.Stream.t list
  -> Market_data.Feed.t Deferred.t

(** A running feed with its counters. *)
type t

(** Like {!create}, keeping the handle for {!stats}. *)
val start
  :  ?on_raw:(stream:Market_data.Stream.t -> recv_ts:Time_ns.t -> string -> unit)
  -> Config.t
  -> symbols:string list
  -> streams:Market_data.Stream.t list
  -> t Deferred.t

val feed : t -> Market_data.Feed.t

module Stats : sig
  type t =
    { frames : int (** websocket text frames received, acks and heartbeats included *)
    ; parse_errors : int
    (** frames that did not decode, or were error frames, and were dropped *)
    ; reconnects : int (** successful reconnections, summed over the connections *)
    }
  [@@deriving sexp_of]
end

val stats : t -> Stats.t
