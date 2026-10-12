open! Core
open Coinbase_feed
module Md = Market_data

let recv_ts = Time_ns.of_int_ns_since_epoch 0
let utc = Time_ns.to_string_utc

let levels (levels : Md.L2_update.Level.t list) =
  List.map levels ~f:(fun { price; size } ->
    [%sexp (price : Md.Price.t), (size : Md.Size.t)])
;;

(* Timestamps in UTC so the output does not depend on the machine's zone. *)
let sexp_of_event : Md.Event.t -> Sexp.t = function
  | Trade { instrument; exch_ts; price; size; side; trade_id; recv_ts = _ } ->
    [%sexp
      Trade
        { instrument = (Md.Instrument.to_string instrument : string)
        ; exch_ts = (utc exch_ts : string)
        ; price : Md.Price.t
        ; size : Md.Size.t
        ; side : Md.Side.t
        ; trade_id : string
        }]
  | Bbo { instrument; exch_ts; bid_price; bid_size; ask_price; ask_size; recv_ts = _ } ->
    [%sexp
      Bbo
        { instrument = (Md.Instrument.to_string instrument : string)
        ; exch_ts = (utc exch_ts : string)
        ; bid = ((bid_price, bid_size) : Md.Price.t * Md.Size.t)
        ; ask = ((ask_price, ask_size) : Md.Price.t * Md.Size.t)
        }]
  | L2 { instrument; exch_ts; kind; bids; asks; recv_ts = _ } ->
    [%sexp
      L2
        { instrument = (Md.Instrument.to_string instrument : string)
        ; exch_ts = (utc exch_ts : string)
        ; kind : Md.L2_update.Kind.t
        ; bids = (levels bids : Sexp.t list)
        ; asks = (levels asks : Sexp.t list)
        }]
  | Funding _ -> [%sexp Funding]
;;

let feed t frame =
  match Normalizer.frame t ~recv_ts frame with
  | Error error -> print_s [%sexp Error (error : Error.t)]
  | Ok { events; resubscribe } ->
    List.iter events ~f:(fun event -> print_s (sexp_of_event event));
    if not (List.is_empty resubscribe)
    then print_s [%sexp Resubscribe (resubscribe : string list)]
;;

let envelope ~channel ~seq events =
  sprintf
    {|{"channel":"%s","timestamp":"2026-10-12T12:00:00.5Z","sequence_num":%d,"events":[%s]}|}
    channel
    seq
    events
;;

let trade ~id ~price ~side ~time =
  sprintf
    {|{"product_id":"BTC-USD","trade_id":"%d","price":"%s","size":"0.01","time":"2026-10-12T12:00:%sZ","side":"%s"}|}
    id
    price
    time
    side
;;

let%expect_test "trades: oldest first, taker side, snapshot backlog not repeated" =
  let t = Normalizer.create () in
  let batch ~seq ~kind trades =
    envelope
      ~channel:"market_trades"
      ~seq
      (sprintf {|{"type":"%s","trades":[%s]}|} kind (String.concat ~sep:"," trades))
  in
  feed
    t
    (batch
       ~seq:0
       ~kind:"snapshot"
       [ trade ~id:12 ~price:"100.5" ~side:"SELL" ~time:"02"
       ; trade ~id:11 ~price:"100" ~side:"BUY" ~time:"01"
       ]);
  [%expect
    {|
    (Trade
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:01.000000000Z")
      (price 100) (size 0.01) (side Sell) (trade_id 11)))
    (Trade
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:02.000000000Z")
      (price 100.5) (size 0.01) (side Buy) (trade_id 12)))
    |}];
  (* A resubscribe sends the backlog again, now with one new trade. *)
  feed
    t
    (batch
       ~seq:1
       ~kind:"snapshot"
       [ trade ~id:13 ~price:"101" ~side:"SELL" ~time:"03"
       ; trade ~id:12 ~price:"100.5" ~side:"SELL" ~time:"02"
       ]);
  [%expect
    {|
    (Trade
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:03.000000000Z")
      (price 101) (size 0.01) (side Buy) (trade_id 13)))
    |}]
;;

let ticker ~bid ~ask =
  sprintf
    {|{"type":"update","tickers":[{"type":"ticker","product_id":"ETH-USD","price":"1","best_bid":"%s","best_bid_quantity":"1.5","best_ask":"%s","best_ask_quantity":"2"}]}|}
    bid
    ask
;;

let%expect_test "ticker: bbo stamped with the envelope time, one-sided skipped" =
  let t = Normalizer.create () in
  feed t (envelope ~channel:"ticker" ~seq:0 (ticker ~bid:"3000.1" ~ask:"3000.2"));
  feed t (envelope ~channel:"ticker" ~seq:1 (ticker ~bid:"3000.1" ~ask:""));
  [%expect
    {|
    (Bbo
     ((instrument coinbase:ETH-USD) (exch_ts "2026-10-12 12:00:00.500000000Z")
      (bid (3000.1 1.5)) (ask (3000.2 2))))
    |}]
;;

let level ~side ~price ~qty ~time =
  sprintf
    {|{"side":"%s","event_time":"2026-10-12T12:00:%sZ","price_level":"%s","new_quantity":"%s"}|}
    side
    time
    price
    qty
;;

let l2 ~seq ~kind ~product updates =
  envelope
    ~channel:"l2_data"
    ~seq
    (sprintf
       {|{"type":"%s","product_id":"%s","updates":[%s]}|}
       kind
       product
       (String.concat ~sep:"," updates))
;;

let snapshot ~seq ~product =
  l2
    ~seq
    ~kind:"snapshot"
    ~product
    [ level ~side:"bid" ~price:"99" ~qty:"2" ~time:"00"
    ; level ~side:"offer" ~price:"102" ~qty:"3" ~time:"00"
    ; level ~side:"bid" ~price:"100" ~qty:"1" ~time:"00"
    ; level ~side:"offer" ~price:"101" ~qty:"4" ~time:"00"
    ]
;;

let delta ~seq ~product =
  l2
    ~seq
    ~kind:"update"
    ~product
    [ level ~side:"bid" ~price:"100" ~qty:"0" ~time:"01.25"
    ; level ~side:"offer" ~price:"100.5" ~qty:"0.5" ~time:"01.5"
    ]
;;

let%expect_test "l2: snapshot then deltas; updates before a snapshot dropped" =
  let t = Normalizer.create () in
  feed t (delta ~seq:0 ~product:"BTC-USD");
  [%expect {| |}];
  feed t (snapshot ~seq:1 ~product:"BTC-USD");
  feed t (envelope ~channel:"subscriptions" ~seq:2 {|{"subscriptions":{}}|});
  feed t (delta ~seq:3 ~product:"BTC-USD");
  [%expect
    {|
    (L2
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:00.000000000Z")
      (kind Snapshot) (bids ((100 1) (99 2))) (asks ((101 4) (102 3)))))
    (L2
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:01.500000000Z")
      (kind Delta) (bids ((100 0))) (asks ((100.5 0.5)))))
    |}];
  print_s [%sexp (Normalizer.is_synced t "BTC-USD" : bool)];
  [%expect {| true |}]
;;

let%expect_test "l2: a sequence gap resubscribes every synced product" =
  let t = Normalizer.create () in
  feed t (snapshot ~seq:0 ~product:"BTC-USD");
  feed t (snapshot ~seq:1 ~product:"ETH-USD");
  [%expect
    {|
    (L2
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:00.000000000Z")
      (kind Snapshot) (bids ((100 1) (99 2))) (asks ((101 4) (102 3)))))
    (L2
     ((instrument coinbase:ETH-USD) (exch_ts "2026-10-12 12:00:00.000000000Z")
      (kind Snapshot) (bids ((100 1) (99 2))) (asks ((101 4) (102 3)))))
    |}];
  (* seq 2 is lost. *)
  feed t (delta ~seq:3 ~product:"BTC-USD");
  [%expect {| (Resubscribe (BTC-USD ETH-USD)) |}];
  (* Updates still in flight until the unsubscribe lands are dropped. *)
  feed t (delta ~seq:4 ~product:"ETH-USD");
  feed t (envelope ~channel:"subscriptions" ~seq:5 {|{"subscriptions":{}}|});
  [%expect {| |}];
  feed t (snapshot ~seq:6 ~product:"BTC-USD");
  feed t (delta ~seq:7 ~product:"BTC-USD");
  feed t (delta ~seq:8 ~product:"ETH-USD");
  [%expect
    {|
    (L2
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:00.000000000Z")
      (kind Snapshot) (bids ((100 1) (99 2))) (asks ((101 4) (102 3)))))
    (L2
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:01.500000000Z")
      (kind Delta) (bids ((100 0))) (asks ((100.5 0.5)))))
    |}]
;;

let%expect_test "l2: a new connection unsyncs books; late duplicates are dropped" =
  let t = Normalizer.create () in
  feed t (snapshot ~seq:0 ~product:"BTC-USD");
  feed t (delta ~seq:1 ~product:"BTC-USD");
  feed t (delta ~seq:1 ~product:"BTC-USD");
  [%expect
    {|
    (L2
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:00.000000000Z")
      (kind Snapshot) (bids ((100 1) (99 2))) (asks ((101 4) (102 3)))))
    (L2
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:01.500000000Z")
      (kind Delta) (bids ((100 0))) (asks ((100.5 0.5)))))
    |}];
  (* Reconnected: the counter restarts and the first frame is not the snapshot. *)
  feed t (envelope ~channel:"heartbeats" ~seq:0 {|{"heartbeat_counter":1}|});
  feed t (delta ~seq:1 ~product:"BTC-USD");
  print_s [%sexp (Normalizer.is_synced t "BTC-USD" : bool)];
  [%expect {| false |}];
  feed t (snapshot ~seq:2 ~product:"BTC-USD");
  [%expect
    {|
    (L2
     ((instrument coinbase:BTC-USD) (exch_ts "2026-10-12 12:00:00.000000000Z")
      (kind Snapshot) (bids ((100 1) (99 2))) (asks ((101 4) (102 3)))))
    |}]
;;

let%expect_test "error and undecodable frames" =
  let t = Normalizer.create () in
  feed t {|{"type":"error","message":"authentication failure"}|};
  feed t "{";
  feed
    t
    (l2
       ~seq:0
       ~kind:"snapshot"
       ~product:"BTC-USD"
       [ level ~side:"bid" ~price:"abc" ~qty:"1" ~time:"00" ]);
  [%expect
    {|
    (Error ("Coinbase error frame" "authentication failure"))
    (Error
     ("cannot decode Coinbase frame"
       "Line 1, bytes 0-1:\
      \nUnexpected end of input"))
    (Error
     ("cannot decode Coinbase frame"
      "(\"Fixed_decimal.of_string: invalid decimal\" abc)"))
    |}];
  print_s [%sexp (Normalizer.is_synced t "BTC-USD" : bool)];
  [%expect {| false |}]
;;
