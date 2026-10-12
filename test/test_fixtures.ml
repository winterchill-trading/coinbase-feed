(* The recorded minute per stream, decoded and normalized the way [Live_feed] does it. *)

open! Core
open Coinbase_feed

type counts =
  { frames : int
  ; empty : int
  ; errors : int
  ; trades : int
  ; bbos : int
  ; snapshots : int
  ; deltas : int
  ; resubscribes : int
  }
[@@deriving sexp_of]

let zero =
  { frames = 0
  ; empty = 0
  ; errors = 0
  ; trades = 0
  ; bbos = 0
  ; snapshots = 0
  ; deltas = 0
  ; resubscribes = 0
  }
;;

let count_event c (event : Market_data.Event.t) =
  match event with
  | Trade _ -> { c with trades = c.trades + 1 }
  | Bbo _ -> { c with bbos = c.bbos + 1 }
  | Funding _ -> c
  | L2 { kind = Snapshot; _ } -> { c with snapshots = c.snapshots + 1 }
  | L2 { kind = Delta; _ } -> { c with deltas = c.deltas + 1 }
;;

let replay stream =
  let t = Normalizer.create () in
  List.fold (Fixture.frames stream) ~init:zero ~f:(fun c (recv_ts, frame) ->
    let c = { c with frames = c.frames + 1 } in
    match Normalizer.frame t ~recv_ts frame with
    | Error _ -> { c with errors = c.errors + 1 }
    | Ok { events; resubscribe } ->
      let c =
        if List.is_empty resubscribe
        then c
        else { c with resubscribes = c.resubscribes + 1 }
      in
      if List.is_empty events
      then { c with empty = c.empty + 1 }
      else List.fold events ~init:c ~f:count_event)
;;

let%expect_test "every recorded frame decodes and normalizes" =
  List.iter Fixture.streams ~f:(fun stream ->
    print_s [%message "" (stream : Market_data.Stream.t) ~_:(replay stream : counts)]);
  [%expect
    {|
    ((stream Trades)
     ((frames 108) (empty 27) (errors 0) (trades 298) (bbos 0) (snapshots 0)
      (deltas 0) (resubscribes 0)))
    ((stream Bbo)
     ((frames 135) (empty 24) (errors 0) (trades 0) (bbos 111) (snapshots 0)
      (deltas 0) (resubscribes 0)))
    ((stream L2)
     ((frames 122) (empty 8) (errors 0) (trades 0) (bbos 0) (snapshots 1)
      (deltas 113) (resubscribes 0)))
    |}]
;;
