open! Core
open Async
module Md = Market_data
module Ws_client = Venue_net.Ws_client

let channel : Md.Stream.t -> string option = function
  | Trades -> Some "market_trades"
  | Bbo -> Some "ticker"
  | L2 -> Some "level2"
  | Funding | Private -> None
;;

let heartbeats = "heartbeats"

let subscribe ws ~channel ~symbols =
  let%bind () = Ws_client.send ws (Wire.subscribe ~channel ~product_ids:symbols) in
  Ws_client.send ws (Wire.subscribe ~channel:heartbeats ~product_ids:[])
;;

let resubscribe ws ~channel ~products =
  let%bind () = Ws_client.send ws (Wire.unsubscribe ~channel ~product_ids:products) in
  Ws_client.send ws (Wire.subscribe ~channel ~product_ids:products)
;;

module Stats = struct
  type t =
    { frames : int
    ; parse_errors : int
    ; reconnects : int
    }
  [@@deriving sexp_of]
end

type counters =
  { mutable frames : int
  ; mutable parse_errors : int
  }

type t =
  { feed : Md.Feed.With_gaps.t
  ; counters : counters
  ; clients : Ws_client.t list
  }

let feed t = Md.Feed.With_gaps.to_feed t.feed
let feed_with_gaps t = t.feed

let stats t : Stats.t =
  { frames = t.counters.frames
  ; parse_errors = t.counters.parse_errors
  ; reconnects = List.sum (module Int) t.clients ~f:Ws_client.reconnects
  }
;;

let start
  ?on_raw
  ?(time_source = Time_source.wall_clock ())
  (config : Config.t)
  ~symbols
  ~streams
  =
  let streams = List.dedup_and_sort streams ~compare:Md.Stream.compare in
  if List.mem streams Private ~equal:Md.Stream.equal
  then raise_s [%message "Live_feed.create: the private stream is not a market feed"];
  let trades_r, trades_w = Pipe.create () in
  let bbo_r, bbo_w = Pipe.create () in
  let l2_r, l2_w = Pipe.create () in
  let funding_r, funding_w = Pipe.create () in
  if List.mem streams Funding ~equal:Md.Stream.equal
  then Log.Global.info "coinbase feed: no funding on Coinbase spot, funding pipe closed";
  Pipe.close funding_w;
  let gaps_r, gaps_w = Pipe.create () in
  let gap ~recv_ts ~stream ?instrument () =
    Pipe.write_without_pushback_if_open
      gaps_w
      { Md.Gap.recv_ts
      ; venue = Coinbase
      ; instrument
      ; stream = Some stream
      ; reason = Resync
      }
  in
  let emit : Md.Event.t -> unit = function
    | Trade x -> Pipe.write_without_pushback_if_open trades_w x
    | Bbo x -> Pipe.write_without_pushback_if_open bbo_w x
    | L2 x -> Pipe.write_without_pushback_if_open l2_w x
    | Funding x -> Pipe.write_without_pushback_if_open funding_w x
  in
  let counters = { frames = 0; parse_errors = 0 } in
  let connect stream ~channel =
    let normalizer = Normalizer.create () in
    let stream_name = Md.Stream.to_string stream in
    (* Reconnects already reported as a gap. [on_connect] runs before the subscriptions
       are sent, and Coinbase sends nothing before them, so the gap normally precedes the
       new connection's frames; [handle] checks too, so whichever runs first reports it. *)
    let reported = ref 0 in
    let report_reconnect ws ~recv_ts =
      let reconnects = Ws_client.reconnects ws in
      if reconnects > !reported
      then (
        reported := reconnects;
        gap ~recv_ts ~stream ())
    in
    let on_connect ws =
      if Ws_client.reconnects ws > 0
      then (
        report_reconnect ws ~recv_ts:(Time_source.now time_source);
        Log.Global.info "coinbase feed: %s reconnected" stream_name);
      subscribe ws ~channel ~symbols
    in
    let%map ws =
      Ws_client.connect
        ~ping:(`Frame (Time_ns.Span.of_sec 10.))
        ~on_connect
        ~log_name:("coinbase " ^ stream_name)
        ~time_source
        ~url:config.url
        ()
      >>| Or_error.ok_exn
    in
    let handle frame =
      let recv_ts = Time_source.now time_source in
      counters.frames <- counters.frames + 1;
      report_reconnect ws ~recv_ts;
      Option.iter on_raw ~f:(fun on_raw -> on_raw ~stream ~recv_ts frame);
      match Normalizer.frame normalizer ~recv_ts frame with
      | Error error ->
        counters.parse_errors <- counters.parse_errors + 1;
        Log.Global.error_s
          [%message
            "coinbase feed: cannot use frame"
              ~stream:stream_name
              ~frame:(String.prefix frame 500 : string)
              (error : Error.t)]
      | Ok { events; resubscribe = products } ->
        List.iter products ~f:(fun product ->
          gap ~recv_ts ~stream ~instrument:(Normalizer.instrument product) ());
        List.iter events ~f:emit;
        if not (List.is_empty products)
        then don't_wait_for (resubscribe ws ~channel ~products)
    in
    don't_wait_for (Pipe.iter_without_pushback (Ws_client.messages ws) ~f:handle);
    ws
  in
  let opened = ref [] in
  let close_all () = Deferred.List.iter !opened ~how:`Parallel ~f:Ws_client.close in
  let%bind () =
    match%bind
      Monitor.try_with (fun () ->
        Deferred.List.iter streams ~how:`Sequential ~f:(fun stream ->
          match channel stream with
          | None -> return ()
          | Some channel ->
            let%map ws = connect stream ~channel in
            opened := ws :: !opened))
    with
    | Ok () -> return ()
    | Error exn ->
      let%map () = close_all () in
      raise exn
  in
  let closed =
    Lazy_deferred.create (fun () ->
      let%map () = close_all () in
      Pipe.close trades_w;
      Pipe.close bbo_w;
      Pipe.close l2_w;
      Pipe.close gaps_w)
  in
  let feed =
    (module struct
      let trades = trades_r
      let bbo = bbo_r
      let l2 = l2_r
      let funding = funding_r
      let gaps = gaps_r
      let close () = Lazy_deferred.force_exn closed
    end : Md.Feed.With_gaps.S)
  in
  return { feed; counters; clients = !opened }
;;

let create ?on_raw ?time_source config ~symbols ~streams =
  let%map t = start ?on_raw ?time_source config ~symbols ~streams in
  feed t
;;
