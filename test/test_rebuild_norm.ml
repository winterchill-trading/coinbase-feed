(* [Market_data.Rebuild_norm] over the recorded minute with [Raw_normalizer], then the
   event logs read back. *)

open! Core
open Async
open Coinbase_feed

let%expect_test "rebuild-norm over the recorded minute" =
  Log.Global.set_output [];
  let out_dir = Filename_unix.temp_dir "coinbase-rebuild" "" in
  let%bind stats =
    Market_data.Rebuild_norm.run
      ~normalizers:[ (module Raw_normalizer) ]
      ~data_dir:Fixture.data_dir
      ~out_dir
      Fixture.date
  in
  print_s [%sexp (ok_exn stats : Market_data.Rebuild_norm.Stats.t)];
  [%expect
    {|
    ((files 3) (frames 365) (disconnects 0) (events 523) (frame_errors 0)
     (first_errors ()) (skipped_files 0) (skipped_venues ()))
    |}];
  let instrument = Normalizer.instrument "BTC-USD" in
  let%bind () =
    Deferred.List.iter ~how:`Sequential Fixture.streams ~f:(fun stream ->
      let path = Market_data.Event_log.path ~dir:out_dir instrument stream Fixture.date in
      let%map events, tail = Market_data.Event_log.load_file path in
      let first_and_last =
        match events, List.last events with
        | first :: _, Some last ->
          Some
            ( Market_data.Event.recv_ts first |> Time_ns.to_string_utc
            , Market_data.Event.recv_ts last |> Time_ns.to_string_utc )
        | _ -> None
      in
      print_s
        [%message
          ""
            (stream : Market_data.Stream.t)
            ~file:(String.chop_prefix_exn path ~prefix:out_dir : string)
            ~events:(List.length events : int)
            (first_and_last : (string * string) option)
            (tail : Market_data.Framed.Tail.t)])
  in
  [%expect
    {|
    ((stream Trades) (file /coinbase/BTC-USD/norm/trades/2026-10-12.bin)
     (events 298)
     (first_and_last
      (("2026-10-12 16:54:01.945854000Z" "2026-10-12 16:54:26.336560000Z")))
     (tail Clean))
    ((stream Bbo) (file /coinbase/BTC-USD/norm/bbo/2026-10-12.bin) (events 111)
     (first_and_last
      (("2026-10-12 16:54:01.926109000Z" "2026-10-12 16:54:24.673614000Z")))
     (tail Clean))
    ((stream L2) (file /coinbase/BTC-USD/norm/l2/2026-10-12.bin) (events 114)
     (first_and_last
      (("2026-10-12 16:54:02.676330000Z" "2026-10-12 16:54:08.383978000Z")))
     (tail Clean))
    |}];
  Process.run_expect_no_stdout_exn ~prog:"rm" ~args:[ "-rf"; out_dir ] ()
;;
