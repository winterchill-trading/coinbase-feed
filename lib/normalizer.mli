(** Coinbase frames to {!Market_data} records. Pure apart from logging; the Async driver
    is {!Live_feed}. Use one [t] per websocket connection: [sequence_num] counts frames
    per connection.

    - [market_trades]: one {!Market_data.Trade.t} per trade, oldest first. The wire [side]
      is the maker's, so the taker side is its opposite. Trades whose numeric [trade_id]
      is not above the last emitted one for the product are dropped, so the snapshot of
      recent trades sent after every (re)subscribe does not repeat prints.
    - [ticker]: one {!Market_data.Bbo.t} per ticker with both sides present, [exch_ts] the
      envelope timestamp (tickers carry no time of their own).
    - [level2] ([l2_data]): a [snapshot] event becomes a [Snapshot] (bids best first, asks
      best first) and marks the product synced; [update] events of synced products become
      [Delta]s. [exch_ts] is the latest [event_time] in the event. Updates of products
      without a snapshot are dropped.

    Sequencing: a [sequence_num] of [0] after other frames is a new connection and unsyncs
    every book until its snapshot arrives. A jump of more than one is a lost frame: every
    product that was synced is unsynced and listed in [resubscribe]. A lower non-zero
    number is a late duplicate and is dropped. *)

open! Core

module Output : sig
  type t =
    { events : Market_data.Event.t list
    ; resubscribe : string list (** product ids whose book must be fetched again *)
    }
  [@@deriving sexp_of]

  val empty : t
end

type t

val create : unit -> t
val message : t -> recv_ts:Time_ns.t -> Wire.Message.t -> Output.t

(** {!Wire.decode} then {!message}. [Error] for undecodable frames and Coinbase error
    frames. *)
val frame : t -> recv_ts:Time_ns.t -> string -> Output.t Or_error.t

val is_synced : t -> string -> bool
val instrument : string -> Market_data.Instrument.t
