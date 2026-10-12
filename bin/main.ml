open! Core
open Async
module Md = Market_data

let streams_arg =
  Command.Arg_type.create (fun s ->
    String.split s ~on:',' |> List.map ~f:String.strip |> List.map ~f:Md.Stream.of_string)
;;

let feed =
  Command.async
    ~summary:"Print normalized Coinbase market data as sexps"
    (let%map_open.Command symbol =
       flag "-symbol" (required string) ~doc:"PRODUCT product id, e.g. BTC-USD"
     and streams =
       flag
         "-streams"
         (optional_with_default [ Md.Stream.Trades ] streams_arg)
         ~doc:"LIST comma separated: trades,bbo,l2,funding (default trades)"
     and count = flag "-count" (optional int) ~doc:"N stop after N events"
     and seconds = flag "-seconds" (optional float) ~doc:"S stop after S seconds"
     and url =
       flag "-url" (optional string) ~doc:"URL websocket endpoint (default mainnet)"
     and depth =
       flag
         "-print-depth"
         (optional_with_default 5 int)
         ~doc:"N print at most N levels per side of an L2 message (default 5)"
     and raw = flag "-raw" no_arg ~doc:" also print raw frames (truncated) to stderr" in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       let config =
         Coinbase_feed.Config.create ?url:(Option.map url ~f:Uri.of_string) ()
       in
       let on_raw =
         Option.some_if raw (fun ~stream ~recv_ts:_ frame ->
           Core.eprintf "%s %s\n%!" (Md.Stream.to_string stream) (String.prefix frame 300))
       in
       let%bind (module F) =
         Coinbase_feed.Live_feed.create ?on_raw config ~symbols:[ symbol ] ~streams
       in
       let printed = ref 0 in
       let finished = Ivar.create () in
       let print event =
         if not (Ivar.is_full finished)
         then (
           let event : Md.Event.t =
             match event with
             | L2 l2 ->
               L2
                 { l2 with
                   bids = List.take l2.bids depth
                 ; asks = List.take l2.asks depth
                 }
             | Trade _ | Bbo _ | Funding _ -> event
           in
           Core.print_s [%sexp (event : Md.Event.t)];
           incr printed;
           Option.iter count ~f:(fun count ->
             if !printed >= count then Ivar.fill_if_empty finished ()))
       in
       let forward pipe ~f =
         don't_wait_for (Pipe.iter_without_pushback pipe ~f:(fun x -> print (f x)))
       in
       forward F.trades ~f:(fun x -> Md.Event.Trade x);
       forward F.bbo ~f:(fun x -> Md.Event.Bbo x);
       forward F.l2 ~f:(fun x -> Md.Event.L2 x);
       forward F.funding ~f:(fun x -> Md.Event.Funding x);
       Option.iter seconds ~f:(fun s ->
         upon
           (Clock_ns.after (Time_ns.Span.of_sec s))
           (fun () -> Ivar.fill_if_empty finished ()));
       let%bind () = Ivar.read finished in
       F.close ())
;;

let () =
  Command_unix.run
    (Command.group ~summary:"Coinbase public market data feed" [ "feed", feed ])
;;
