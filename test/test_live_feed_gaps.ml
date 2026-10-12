(* [Live_feed.feed_with_gaps]: resync gaps on a level2 sequence break and on a reconnect,
   on a synthetic clock, against a scripted local websocket server. *)

open! Core
open Async
open Coinbase_feed
module Md = Market_data

let l2 ~seq ~kind ~product ~bid =
  sprintf
    {|{"channel":"l2_data","timestamp":"2026-10-12T12:00:00.5Z","sequence_num":%d,"events":[{"type":"%s","product_id":"%s","updates":[{"side":"bid","event_time":"2026-10-12T12:00:00Z","price_level":"%s","new_quantity":"1"},{"side":"offer","event_time":"2026-10-12T12:00:00Z","price_level":"200","new_quantity":"1"}]}]}|}
    seq
    kind
    product
    bid
;;

let ms time = Time_ns.to_int_ns_since_epoch time / 1_000_000

let print_gap ({ recv_ts; venue; instrument; stream; reason } : Md.Gap.t) =
  print_s
    [%message
      "gap"
        ~recv_ts_ms:(ms recv_ts : int)
        (venue : Md.Venue.t)
        ~instrument:(Option.map instrument ~f:Md.Instrument.to_string : string option)
        (stream : Md.Stream.t option)
        (reason : Md.Gap.Reason.t)]
;;

(* Reads the next L2 update, first printing every gap already written: a gap that must
   precede the update is printed before it. *)
let next_l2 (module F : Md.Feed.With_gaps.S) =
  let%map update = Pipe.read F.l2 in
  (match Pipe.read_now' F.gaps with
   | `Ok gaps -> Queue.iter gaps ~f:print_gap
   | `Nothing_available | `Eof -> ());
  match update with
  | `Eof -> print_endline "eof"
  | `Ok (update : Md.L2_update.t) ->
    print_s
      [%message
        "l2"
          ~recv_ts_ms:(ms update.recv_ts : int)
          ~instrument:(Md.Instrument.to_string update.instrument : string)
          ~kind:(update.kind : Md.L2_update.Kind.t)]
;;

let%expect_test "resync gaps: a level2 sequence break, then a reconnect" =
  Log.Global.set_output [];
  let%bind server = Fake_ws.start () in
  let clock = Time_source.create ~now:Time_ns.epoch () in
  let%bind live =
    Live_feed.start
      ~time_source:(Time_source.read_only clock)
      (Fake_ws.config server)
      ~symbols:[ "BTC-USD"; "ETH-USD" ]
      ~streams:[ L2 ]
  in
  let feed = Live_feed.feed_with_gaps live in
  let module F = (val feed) in
  let sent_l2 () =
    List.filter
      (Fake_ws.received server)
      ~f:(String.is_substring ~substring:{|"channel":"level2"|})
  in
  let%bind (_ : bool) = Fake_ws.wait_until (fun () -> List.length (sent_l2 ()) = 1) in
  Fake_ws.send server (l2 ~seq:0 ~kind:"snapshot" ~product:"BTC-USD" ~bid:"100");
  Fake_ws.send server (l2 ~seq:1 ~kind:"snapshot" ~product:"ETH-USD" ~bid:"10");
  Fake_ws.send server (l2 ~seq:2 ~kind:"update" ~product:"BTC-USD" ~bid:"101");
  let%bind () = next_l2 feed in
  let%bind () = next_l2 feed in
  let%bind () = next_l2 feed in
  [%expect
    {|
    (l2 (recv_ts_ms 0) (instrument coinbase:BTC-USD) (kind Snapshot))
    (l2 (recv_ts_ms 0) (instrument coinbase:ETH-USD) (kind Snapshot))
    (l2 (recv_ts_ms 0) (instrument coinbase:BTC-USD) (kind Delta))
    |}];
  (* seq 3 is lost: both synced books are resubscribed, one gap each. *)
  let%bind () = Time_source.advance_by_alarms_by clock (Time_ns.Span.of_int_ms 100) in
  Fake_ws.send server (l2 ~seq:4 ~kind:"update" ~product:"BTC-USD" ~bid:"102");
  let%bind (_ : bool) = Fake_ws.wait_until (fun () -> List.length (sent_l2 ()) = 3) in
  List.iter (List.drop (sent_l2 ()) 1) ~f:print_endline;
  Fake_ws.send server (l2 ~seq:5 ~kind:"snapshot" ~product:"BTC-USD" ~bid:"103");
  let%bind () = next_l2 feed in
  [%expect
    {|
    {"type":"unsubscribe","product_ids":["BTC-USD","ETH-USD"],"channel":"level2"}
    {"type":"subscribe","product_ids":["BTC-USD","ETH-USD"],"channel":"level2"}
    (gap (recv_ts_ms 100) (venue Coinbase) (instrument (coinbase:BTC-USD))
     (stream (L2)) (reason Resync))
    (gap (recv_ts_ms 100) (venue Coinbase) (instrument (coinbase:ETH-USD))
     (stream (L2)) (reason Resync))
    (l2 (recv_ts_ms 100) (instrument coinbase:BTC-USD) (kind Snapshot))
    |}];
  (* The socket drops at 0.1s; the first backoff is 0.5s with 20% jitter. Frames the
     server would have sent meanwhile are lost; the new connection starts with fresh
     snapshots, preceded by one gap for the whole connection. *)
  let%bind () = Fake_ws.drop server in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 50) in
  let%bind () = Time_source.advance_by_alarms_by clock (Time_ns.Span.of_int_ms 600) in
  let%bind (_ : bool) = Fake_ws.wait_until (fun () -> List.length (sent_l2 ()) = 4) in
  Fake_ws.send server (l2 ~seq:0 ~kind:"snapshot" ~product:"BTC-USD" ~bid:"104");
  Fake_ws.send server (l2 ~seq:1 ~kind:"update" ~product:"BTC-USD" ~bid:"105");
  let%bind () = next_l2 feed in
  let%bind () = next_l2 feed in
  print_s [%sexp (Live_feed.stats live : Live_feed.Stats.t)];
  [%expect
    {|
    (gap (recv_ts_ms 700) (venue Coinbase) (instrument ()) (stream (L2))
     (reason Resync))
    (l2 (recv_ts_ms 700) (instrument coinbase:BTC-USD) (kind Snapshot))
    (l2 (recv_ts_ms 700) (instrument coinbase:BTC-USD) (kind Delta))
    ((frames 7) (parse_errors 0) (reconnects 1))
    |}];
  let%bind () = F.close () in
  let%bind gaps_closed = Pipe.read F.gaps in
  print_s [%message "after close" (gaps_closed : [ `Eof | `Ok of Md.Gap.t ])];
  [%expect {| ("after close" (gaps_closed Eof)) |}];
  Fake_ws.close server
;;
