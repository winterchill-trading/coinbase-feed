(** Frames of the Coinbase Advanced Trade public websocket (see
    [docs/coinbase-ws-spec.md]). Prices and sizes are decoded into {!Market_data.Price.t}
    and {!Market_data.Size.t}; timestamps into [Time_ns.t] (UTC). *)

open! Core

(** RFC 3339 timestamps as sent by Coinbase, e.g. ["2026-10-12T12:41:49.006210269Z"]. Up
    to nanosecond precision; the zone must be [Z]. *)
val time_of_string : string -> Time_ns.t

module Kind : sig
  type t =
    | Snapshot
    | Update
  [@@deriving sexp, equal]
end

module Trade : sig
  type t =
    { product_id : string
    ; trade_id : string
    ; price : Market_data.Price.t
    ; size : Market_data.Size.t
    ; time : Time_ns.t
    ; maker_side : Market_data.Side.t (** the wire's [side]: the resting order's side *)
    }
  [@@deriving sexp_of]
end

module Ticker : sig
  type t =
    { product_id : string
    ; best_bid : Market_data.Price.t option (** [None] when the wire sends [""] *)
    ; best_bid_quantity : Market_data.Size.t option
    ; best_ask : Market_data.Price.t option
    ; best_ask_quantity : Market_data.Size.t option
    }
  [@@deriving sexp_of]
end

module Level_update : sig
  type t =
    { side : [ `Bid | `Offer ]
    ; event_time : Time_ns.t
    ; price_level : Market_data.Price.t
    ; new_quantity : Market_data.Size.t (** absolute; zero removes the level *)
    }
  [@@deriving sexp_of]
end

module L2_event : sig
  type t =
    { kind : Kind.t
    ; product_id : string
    ; updates : Level_update.t list
    }
  [@@deriving sexp_of]
end

(** The envelope common to every data frame. *)
module Header : sig
  type t =
    { channel : string
    ; timestamp : Time_ns.t
    ; sequence_num : int (** per connection, across all channels *)
    }
  [@@deriving sexp_of]
end

module Message : sig
  type t =
    | Market_trades of Header.t * (Kind.t * Trade.t list) list
    | Ticker of Header.t * (Kind.t * Ticker.t list) list
    | L2_data of Header.t * L2_event.t list
    | Subscriptions of Header.t
    | Heartbeats of Header.t
    | Other of Header.t (** a channel this feed does not decode, e.g. [status] *)
    | Error of string (** [{"type":"error","message":...}] *)
  [@@deriving sexp_of]

  val header : t -> Header.t option
end

(** Parses one text frame. [Error] for invalid JSON or a malformed known channel. *)
val decode : string -> Message.t Or_error.t

(** Subscription requests. [product_ids] is omitted when empty (e.g. [heartbeats]). *)
val subscribe : channel:string -> product_ids:string list -> string

val unsubscribe : channel:string -> product_ids:string list -> string
