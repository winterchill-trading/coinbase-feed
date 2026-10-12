(* [Live_feed.stats] with frames pushed by a scripted local websocket server. *)

open! Core
open Async
open Coinbase_feed

let market_trades =
  {|{"channel":"market_trades","timestamp":"2026-10-12T12:41:57.536738524Z","sequence_num":1,"events":[{"type":"update","trades":[{"product_id":"BTC-USD","trade_id":"1105003397","price":"82666","size":"0.00011975","time":"2026-10-12T12:41:57.443974Z","side":"SELL"}]}]}|}
;;

let subscriptions =
  {|{"channel":"subscriptions","timestamp":"2026-10-12T12:41:57.4Z","sequence_num":0,"events":[{"subscriptions":{"market_trades":["BTC-USD"]}}]}|}
;;

let%expect_test "a malformed frame is counted and skipped" =
  Log.Global.set_output [];
  let%bind server = Fake_ws.start () in
  let%bind live =
    Live_feed.start (Fake_ws.config server) ~symbols:[ "BTC-USD" ] ~streams:[ Trades ]
  in
  let module F = (val Live_feed.feed live : Market_data.Feed.S) in
  let%bind (_ : bool) =
    Fake_ws.wait_until (fun () -> List.length (Fake_ws.received server) = 2)
  in
  List.iter (Fake_ws.received server) ~f:print_endline;
  [%expect
    {|
    {"type":"subscribe","product_ids":["BTC-USD"],"channel":"market_trades"}
    {"type":"subscribe","channel":"heartbeats"}
    |}];
  Fake_ws.send server subscriptions;
  Fake_ws.send server {|{"channel":"market_trades","timestamp":|};
  Fake_ws.send server market_trades;
  let%bind trade = Pipe.read F.trades in
  (match trade with
   | `Ok trade -> print_s [%sexp (trade.trade_id : string)]
   | `Eof -> print_endline "eof");
  print_s [%sexp (Live_feed.stats live : Live_feed.Stats.t)];
  [%expect {|
    1105003397
    ((frames 3) (parse_errors 1) (reconnects 0))
    |}];
  let%bind () = F.close () in
  Fake_ws.close server
;;

let%expect_test "reconnects on a synthetic clock and resubscribes" =
  Log.Global.set_output [];
  let%bind server = Fake_ws.start () in
  let clock = Time_source.create ~now:Time_ns.epoch () in
  let%bind live =
    Live_feed.start
      ~time_source:(Time_source.read_only clock)
      (Fake_ws.config server)
      ~symbols:[ "BTC-USD" ]
      ~streams:[ Trades ]
  in
  let module F = (val Live_feed.feed live : Market_data.Feed.S) in
  let subscribes () =
    List.count
      (Fake_ws.received server)
      ~f:(String.is_substring ~substring:{|"channel":"market_trades"|})
  in
  let%bind (_ : bool) = Fake_ws.wait_until (fun () -> subscribes () = 1) in
  let%bind () = Fake_ws.drop server in
  (* The first backoff is 0.5s with 20% jitter: nothing before 0.4s, a new connection by
     0.6s. Real I/O is given time to happen at each step. *)
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 50) in
  let%bind () = Time_source.advance_by_alarms_by clock (Time_ns.Span.of_int_ms 390) in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 50) in
  print_s [%message "after 0.39s" ~connections:(Fake_ws.connections server : int)];
  let%bind () = Time_source.advance_by_alarms_by clock (Time_ns.Span.of_int_ms 210) in
  let%bind (_ : bool) = Fake_ws.wait_until (fun () -> subscribes () = 2) in
  print_s
    [%message
      "after 0.6s"
        ~connections:(Fake_ws.connections server : int)
        ~subscribes:(subscribes () : int)
        ~stats:(Live_feed.stats live : Live_feed.Stats.t)];
  Fake_ws.send server market_trades;
  let%bind trade = Pipe.read F.trades in
  (match trade with
   | `Ok trade ->
     print_s
       [%message
         "" ~recv_ts_ms:(Time_ns.to_int_ns_since_epoch trade.recv_ts / 1_000_000 : int)]
   | `Eof -> print_endline "eof");
  [%expect
    {|
    ("after 0.39s" (connections 1))
    ("after 0.6s" (connections 2) (subscribes 2)
     (stats ((frames 0) (parse_errors 0) (reconnects 1))))
    (recv_ts_ms 600)
    |}];
  let%bind () = F.close () in
  Fake_ws.close server
;;
