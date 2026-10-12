open! Core
open Ppx_yojson_conv_lib.Yojson_conv.Primitives
module Md = Market_data

let time_of_string s =
  match String.lsplit2 s ~on:'T' with
  | None -> raise_s [%message "Coinbase timestamp: missing 'T'" s]
  | Some (date, rest) ->
    (match String.chop_suffix rest ~suffix:"Z" with
     | None -> raise_s [%message "Coinbase timestamp: zone is not Z" s]
     | Some ofday ->
       Time_ns.of_date_ofday
         ~zone:Time_float.Zone.utc
         (Date.of_string date)
         (Time_ns.Ofday.of_string ofday))
;;

module Kind = struct
  type t =
    | Snapshot
    | Update
  [@@deriving sexp, equal]

  let t_of_yojson json =
    match string_of_yojson json with
    | "snapshot" -> Snapshot
    | "update" -> Update
    | other -> raise_s [%message "unknown event type" other]
  ;;
end

(* Field converters for the derived codecs. Only decoding is needed. *)
module Px = struct
  type t = Md.Price.t

  let t_of_yojson json = Md.Price.of_string (string_of_yojson json)
end

module Sz = struct
  type t = Md.Size.t

  let t_of_yojson json = Md.Size.of_string (string_of_yojson json)
end

module Px_opt = struct
  type t = Md.Price.t option

  let t_of_yojson = function
    | `Null | `String "" -> None
    | json -> Some (Px.t_of_yojson json)
  ;;
end

module Sz_opt = struct
  type t = Md.Size.t option

  let t_of_yojson = function
    | `Null | `String "" -> None
    | json -> Some (Sz.t_of_yojson json)
  ;;
end

module Ts = struct
  type t = Time_ns.t

  let t_of_yojson json = time_of_string (string_of_yojson json)
end

module Trade = struct
  module Maker_side = struct
    type t = Md.Side.t

    let t_of_yojson json : t =
      match string_of_yojson json with
      | "BUY" -> Buy
      | "SELL" -> Sell
      | other -> raise_s [%message "unknown trade side" other]
    ;;
  end

  module Wire = struct
    type t =
      { product_id : string
      ; trade_id : string
      ; price : Px.t
      ; size : Sz.t
      ; time : Ts.t
      ; side : Maker_side.t
      }
    [@@deriving of_yojson] [@@yojson.allow_extra_fields]
  end

  type t =
    { product_id : string
    ; trade_id : string
    ; price : Md.Price.t
    ; size : Md.Size.t
    ; time : Time_ns.t
    ; maker_side : Md.Side.t
    }

  let sexp_of_t { product_id; trade_id; price; size; time; maker_side } =
    [%sexp
      { product_id : string
      ; trade_id : string
      ; price : Md.Price.t
      ; size : Md.Size.t
      ; time : Time_ns.Alternate_sexp.t
      ; maker_side : Md.Side.t
      }]
  ;;

  let t_of_yojson json =
    let { Wire.product_id; trade_id; price; size; time; side } = Wire.t_of_yojson json in
    { product_id; trade_id; price; size; time; maker_side = side }
  ;;
end

module Ticker = struct
  type t =
    { product_id : string
    ; best_bid : Px_opt.t [@default None]
    ; best_bid_quantity : Sz_opt.t [@default None]
    ; best_ask : Px_opt.t [@default None]
    ; best_ask_quantity : Sz_opt.t [@default None]
    }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  let sexp_of_t { product_id; best_bid; best_bid_quantity; best_ask; best_ask_quantity } =
    [%sexp
      { product_id : string
      ; best_bid : Md.Price.t option
      ; best_bid_quantity : Md.Size.t option
      ; best_ask : Md.Price.t option
      ; best_ask_quantity : Md.Size.t option
      }]
  ;;
end

module Level_update = struct
  module Book_side = struct
    type t =
      [ `Bid
      | `Offer
      ]
    [@@deriving sexp_of]

    let t_of_yojson json : t =
      match string_of_yojson json with
      | "bid" -> `Bid
      | "offer" | "ask" -> `Offer
      | other -> raise_s [%message "unknown book side" other]
    ;;
  end

  type t =
    { side : Book_side.t
    ; event_time : Ts.t
    ; price_level : Px.t
    ; new_quantity : Sz.t
    }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  let sexp_of_t { side; event_time; price_level; new_quantity } =
    [%sexp
      { side : Book_side.t
      ; event_time : Time_ns.Alternate_sexp.t
      ; price_level : Md.Price.t
      ; new_quantity : Md.Size.t
      }]
  ;;
end

module L2_event = struct
  module Wire = struct
    type t =
      { type_ : Kind.t [@key "type"]
      ; product_id : string
      ; updates : Level_update.t list
      }
    [@@deriving of_yojson] [@@yojson.allow_extra_fields]
  end

  type t =
    { kind : Kind.t
    ; product_id : string
    ; updates : Level_update.t list
    }
  [@@deriving sexp_of]

  let t_of_yojson json =
    let { Wire.type_; product_id; updates } = Wire.t_of_yojson json in
    { kind = type_; product_id; updates }
  ;;
end

module Trades_event = struct
  type t =
    { type_ : Kind.t [@key "type"]
    ; trades : Trade.t list
    }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]
end

module Ticker_event = struct
  type t =
    { type_ : Kind.t [@key "type"]
    ; tickers : Ticker.t list
    }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]
end

module Header = struct
  type t =
    { channel : string
    ; timestamp : Time_ns.t
    ; sequence_num : int
    }

  let sexp_of_t { channel; timestamp; sequence_num } =
    [%sexp { channel : string; timestamp : Time_ns.Alternate_sexp.t; sequence_num : int }]
  ;;
end

module Json = struct
  type t = Yojson.Safe.t

  let t_of_yojson json = json
end

module Envelope = struct
  type t =
    { channel : string
    ; timestamp : Ts.t
    ; sequence_num : int
    ; events : Json.t list [@default []]
    }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]
end

module Message = struct
  type t =
    | Market_trades of Header.t * (Kind.t * Trade.t list) list
    | Ticker of Header.t * (Kind.t * Ticker.t list) list
    | L2_data of Header.t * L2_event.t list
    | Subscriptions of Header.t
    | Heartbeats of Header.t
    | Other of Header.t
    | Error of string
  [@@deriving sexp_of]

  let header = function
    | Market_trades (h, _)
    | Ticker (h, _)
    | L2_data (h, _)
    | Subscriptions h
    | Heartbeats h
    | Other h -> Some h
    | Error _ -> None
  ;;
end

let error_message json =
  match json with
  | `Assoc fields ->
    (match List.Assoc.find fields "type" ~equal:String.equal with
     | Some (`String "error") ->
       Some
         (match List.Assoc.find fields "message" ~equal:String.equal with
          | Some (`String message) -> message
          | Some other -> Yojson.Safe.to_string other
          | None -> "")
     | _ -> None)
  | _ -> None
;;

let decode frame =
  Or_error.try_with (fun () ->
    let json = Yojson.Safe.from_string frame in
    match error_message json with
    | Some message -> Message.Error message
    | None ->
      let { Envelope.channel; timestamp; sequence_num; events } =
        Envelope.t_of_yojson json
      in
      let header = { Header.channel; timestamp; sequence_num } in
      (match channel with
       | "market_trades" ->
         Market_trades
           ( header
           , List.map events ~f:(fun json ->
               let { Trades_event.type_; trades } = Trades_event.t_of_yojson json in
               type_, trades) )
       | "ticker" ->
         Ticker
           ( header
           , List.map events ~f:(fun json ->
               let { Ticker_event.type_; tickers } = Ticker_event.t_of_yojson json in
               type_, tickers) )
       | "l2_data" -> L2_data (header, List.map events ~f:L2_event.t_of_yojson)
       | "subscriptions" -> Subscriptions header
       | "heartbeats" -> Heartbeats header
       | _ -> Other header))
  |> Result.map_error ~f:(fun error ->
    (* Decoder exceptions embed source paths; keep only their message. *)
    let reason =
      let rec reason = function
        | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (exn, _) -> reason exn
        | Yojson.Json_error message -> message
        | Failure message ->
          (match String.substr_index message ~pattern:"_of_yojson: " with
           | Some i -> String.drop_prefix message (i + String.length "_of_yojson: ")
           | None -> message)
        | exn -> Exn.to_string exn
      in
      reason (Error.to_exn error)
    in
    Error.create_s [%message "cannot decode Coinbase frame" reason])
;;

let request ~type_ ~channel ~product_ids =
  let product_ids =
    match product_ids with
    | [] -> []
    | ids -> [ "product_ids", `List (List.map ids ~f:(fun id -> `String id)) ]
  in
  Yojson.Safe.to_string
    (`Assoc ([ "type", `String type_ ] @ product_ids @ [ "channel", `String channel ]))
;;

let subscribe = request ~type_:"subscribe"
let unsubscribe = request ~type_:"unsubscribe"
