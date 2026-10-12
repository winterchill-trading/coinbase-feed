open! Core
module Md = Market_data

module Output = struct
  type t =
    { events : Md.Event.t list
    ; resubscribe : string list
    }
  [@@deriving sexp_of]

  let empty = { events = []; resubscribe = [] }
end

type t =
  { mutable last_sequence : int option
  ; synced : String.Hash_set.t (** products whose L2 snapshot has arrived *)
  ; last_trade_id : int String.Table.t
  }

let create () =
  { last_sequence = None
  ; synced = String.Hash_set.create ()
  ; last_trade_id = String.Table.create ()
  }
;;

let instrument product_id = Md.Instrument.create Coinbase product_id
let is_synced t product_id = Hash_set.mem t.synced product_id

let is_new_trade t (trade : Wire.Trade.t) =
  match Int.of_string_opt trade.trade_id with
  | None -> true
  | Some id ->
    (match Hashtbl.find t.last_trade_id trade.product_id with
     | Some last when id <= last -> false
     | Some _ | None ->
       Hashtbl.set t.last_trade_id ~key:trade.product_id ~data:id;
       true)
;;

let trades t ~recv_ts events =
  List.concat_map events ~f:(fun (_kind, trades) ->
    (* Batches arrive newest first. *)
    List.rev trades
    |> List.filter ~f:(is_new_trade t)
    |> List.map ~f:(fun (trade : Wire.Trade.t) ->
      Md.Event.Trade
        { instrument = instrument trade.product_id
        ; exch_ts = trade.time
        ; recv_ts
        ; price = trade.price
        ; size = trade.size
        ; side = Md.Side.flip trade.maker_side
        ; trade_id = trade.trade_id
        }))
;;

let bbo ~(header : Wire.Header.t) ~recv_ts events =
  List.concat_map events ~f:(fun (_kind, tickers) ->
    List.filter_map tickers ~f:(fun (ticker : Wire.Ticker.t) ->
      match ticker with
      | { best_bid = Some bid_price
        ; best_bid_quantity = Some bid_size
        ; best_ask = Some ask_price
        ; best_ask_quantity = Some ask_size
        ; product_id
        } ->
        Some
          (Md.Event.Bbo
             { instrument = instrument product_id
             ; exch_ts = header.timestamp
             ; recv_ts
             ; bid_price
             ; bid_size
             ; ask_price
             ; ask_size
             })
      | _ -> None))
;;

let l2_update
  ~(header : Wire.Header.t)
  ~recv_ts
  ~(kind : Md.L2_update.Kind.t)
  (event : Wire.L2_event.t)
  =
  let exch_ts =
    List.fold event.updates ~init:None ~f:(fun acc (u : Wire.Level_update.t) ->
      match acc with
      | Some ts when Time_ns.( >= ) ts u.event_time -> acc
      | Some _ | None -> Some u.event_time)
    |> Option.value ~default:header.timestamp
  in
  let level (u : Wire.Level_update.t) =
    { Md.L2_update.Level.price = u.price_level; size = u.new_quantity }
  in
  let bids, asks =
    List.partition_map event.updates ~f:(fun u ->
      match u.side with
      | `Bid -> First (level u)
      | `Offer -> Second (level u))
  in
  let bids, asks =
    match kind with
    | Delta -> bids, asks
    | Snapshot ->
      ( List.sort bids ~compare:(fun (a : Md.L2_update.Level.t) b ->
          Md.Price.compare b.price a.price)
      , List.sort asks ~compare:(fun (a : Md.L2_update.Level.t) b ->
          Md.Price.compare a.price b.price) )
  in
  Md.Event.L2
    { instrument = instrument event.product_id; exch_ts; recv_ts; kind; bids; asks }
;;

let l2 t ~header ~recv_ts events =
  List.filter_map events ~f:(fun (event : Wire.L2_event.t) ->
    match event.kind with
    | Snapshot ->
      Hash_set.add t.synced event.product_id;
      Some (l2_update ~header ~recv_ts ~kind:Snapshot event)
    | Update when is_synced t event.product_id ->
      Some (l2_update ~header ~recv_ts ~kind:Delta event)
    | Update -> None)
;;

(* [`Ok resubscribe] to process the frame, [`Drop] for a late duplicate. *)
let check_sequence t (header : Wire.Header.t) =
  let seq = header.sequence_num in
  let previous = t.last_sequence in
  match previous with
  | None ->
    t.last_sequence <- Some seq;
    `Ok []
  | Some last when seq = last + 1 ->
    t.last_sequence <- Some seq;
    `Ok []
  | Some _ when seq = 0 ->
    (* A new connection: books are rebuilt from the snapshots it sends. *)
    t.last_sequence <- Some seq;
    Hash_set.clear t.synced;
    `Ok []
  | Some last when seq <= last -> `Drop
  | Some last ->
    t.last_sequence <- Some seq;
    let lost = Hash_set.to_list t.synced |> List.sort ~compare:String.compare in
    Hash_set.clear t.synced;
    if not (List.is_empty lost)
    then
      Async.Log.Global.info_s
        [%message
          "coinbase feed: sequence gap, resubscribing"
            ~expected:(last + 1 : int)
            ~received:(seq : int)
            ~products:(lost : string list)];
    `Ok lost
;;

let message t ~recv_ts (message : Wire.Message.t) : Output.t =
  match Wire.Message.header message with
  | None -> Output.empty
  | Some header ->
    (match check_sequence t header with
     | `Drop -> Output.empty
     | `Ok resubscribe ->
       let events =
         match message with
         | Market_trades (_, events) -> trades t ~recv_ts events
         | Ticker (header, events) -> bbo ~header ~recv_ts events
         | L2_data (header, events) -> l2 t ~header ~recv_ts events
         | Subscriptions _ | Heartbeats _ | Other _ | Error _ -> []
       in
       { events; resubscribe })
;;

let frame t ~recv_ts frame =
  match%bind.Or_error Wire.decode frame with
  | Error message -> Or_error.error_s [%message "Coinbase error frame" message]
  | decoded -> Or_error.try_with (fun () -> message t ~recv_ts decoded)
;;
