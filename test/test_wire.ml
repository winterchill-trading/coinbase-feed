open! Core
open Coinbase_feed

let decode frame = print_s [%sexp (Wire.decode frame : Wire.Message.t Or_error.t)]

let%expect_test "timestamps keep nanoseconds and are UTC" =
  List.iter
    [ "2026-10-12T12:41:49.006210269Z"
    ; "2026-10-12T12:41:49.813361Z"
    ; "2026-10-12T00:00:00Z"
    ]
    ~f:(fun s -> print_endline (Time_ns.to_string_utc (Wire.time_of_string s)));
  [%expect
    {|
    2026-10-12 12:41:49.006210269Z
    2026-10-12 12:41:49.813361000Z
    2026-10-12 00:00:00.000000000Z
    |}];
  print_s
    [%sexp
      (Or_error.try_with (fun () -> Wire.time_of_string "2026-10-12T12:41:49+01:00")
       : Time_ns.Alternate_sexp.t Or_error.t)];
  [%expect {| (Error ("Coinbase timestamp: zone is not Z" 2026-10-12T12:41:49+01:00)) |}]
;;

let%expect_test "market_trades" =
  decode
    {|{"channel":"market_trades","timestamp":"2026-10-12T12:41:57.536738524Z","sequence_num":2,"events":[{"type":"update","trades":[{"product_id":"BTC-USD","trade_id":"1105003397","price":"82666","size":"0.00011975","time":"2026-10-12T12:41:57.443974Z","side":"SELL"}]}]}|};
  [%expect
    {|
    (Ok
     (Market_trades
      ((channel market_trades) (timestamp "2026-10-12 12:41:57.536738524Z")
       (sequence_num 2))
      ((Update
        (((product_id BTC-USD) (trade_id 1105003397) (price 82666)
          (size 0.00011975) (time "2026-10-12 12:41:57.443974Z")
          (maker_side Sell)))))))
    |}]
;;

let%expect_test "ticker, with an empty side" =
  decode
    {|{"channel":"ticker","timestamp":"2026-10-12T12:41:49.204126545Z","sequence_num":3,"events":[{"type":"update","tickers":[{"type":"ticker","product_id":"BTC-USD","price":"82659.51","volume_24_h":"3542.91343571","best_bid":"82662.26","best_ask":"","best_bid_quantity":"0.0272185","best_ask_quantity":""}]}]}|};
  [%expect
    {|
    (Ok
     (Ticker
      ((channel ticker) (timestamp "2026-10-12 12:41:49.204126545Z")
       (sequence_num 3))
      ((Update
        (((product_id BTC-USD) (best_bid (82662.26))
          (best_bid_quantity (0.0272185)) (best_ask ()) (best_ask_quantity ())))))))
    |}]
;;

let%expect_test "l2_data, subscriptions, heartbeats, status, error" =
  decode
    {|{"channel":"l2_data","timestamp":"2026-10-12T12:41:50.41147103Z","sequence_num":3,"events":[{"type":"update","product_id":"BTC-USD","updates":[{"side":"bid","event_time":"2026-10-12T12:41:49.866547Z","price_level":"82642.8","new_quantity":"0.0012084"},{"side":"offer","event_time":"2026-10-12T12:41:49.866547Z","price_level":"82675.97","new_quantity":"0"}]}]}|};
  [%expect
    {|
    (Ok
     (L2_data
      ((channel l2_data) (timestamp "2026-10-12 12:41:50.41147103Z")
       (sequence_num 3))
      (((kind Update) (product_id BTC-USD)
        (updates
         (((side Bid) (event_time "2026-10-12 12:41:49.866547Z")
           (price_level 82642.8) (new_quantity 0.0012084))
          ((side Offer) (event_time "2026-10-12 12:41:49.866547Z")
           (price_level 82675.97) (new_quantity 0))))))))
    |}];
  decode
    {|{"channel":"subscriptions","timestamp":"2026-10-12T12:41:51.796611103Z","sequence_num":2,"events":[{"subscriptions":{"heartbeats":["heartbeats"],"ticker_batch":["BTC-USD"]}}]}|};
  decode
    {|{"channel":"heartbeats","timestamp":"2026-10-12T12:41:52.752094158Z","sequence_num":3,"events":[{"current_time":"2026-10-12 12:41:52.750927205 +0000 UTC m=+501283.250956184","heartbeat_counter":501263}]}|};
  decode
    {|{"channel":"status","timestamp":"2026-10-12T12:42:13.508456481Z","sequence_num":0,"events":[{"type":"snapshot","products":[]}]}|};
  decode {|{"type":"error","message":"authentication failure"}|};
  [%expect
    {|
    (Ok
     (Subscriptions
      ((channel subscriptions) (timestamp "2026-10-12 12:41:51.796611103Z")
       (sequence_num 2))))
    (Ok
     (Heartbeats
      ((channel heartbeats) (timestamp "2026-10-12 12:41:52.752094158Z")
       (sequence_num 3))))
    (Ok
     (Other
      ((channel status) (timestamp "2026-10-12 12:42:13.508456481Z")
       (sequence_num 0))))
    (Ok (Error "authentication failure"))
    |}]
;;

let%expect_test "bad frames" =
  decode "not json";
  decode {|{"channel":"ticker"}|};
  decode
    {|{"channel":"market_trades","timestamp":"2026-10-12T12:41:57Z","sequence_num":1,"events":[{"type":"update","trades":[{"product_id":"BTC-USD","trade_id":"1","price":"1","size":"1","time":"2026-10-12T12:41:57Z","side":"SIDEWAYS"}]}]}|};
  [%expect
    {|
    (Error
     ("cannot decode Coinbase frame"
       "Line 1, bytes 0-8:\
      \nInvalid token 'not json'"))
    (Error
     ("cannot decode Coinbase frame"
      "the following record elements were undefined: timestamp sequence_num"))
    (Error ("cannot decode Coinbase frame" "(\"unknown trade side\" SIDEWAYS)"))
    |}]
;;

let%expect_test "requests" =
  print_endline (Wire.subscribe ~channel:"level2" ~product_ids:[ "BTC-USD"; "ETH-USD" ]);
  print_endline (Wire.subscribe ~channel:"heartbeats" ~product_ids:[]);
  print_endline (Wire.unsubscribe ~channel:"level2" ~product_ids:[ "BTC-USD" ]);
  [%expect
    {|
    {"type":"subscribe","product_ids":["BTC-USD","ETH-USD"],"channel":"level2"}
    {"type":"subscribe","channel":"heartbeats"}
    {"type":"unsubscribe","product_ids":["BTC-USD"],"channel":"level2"}
    |}]
;;
