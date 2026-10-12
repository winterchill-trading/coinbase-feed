(* Normalizer per frame on the recorded mainnet minute (test/fixtures).

   [trades] and [bbo] cycle through their recorded frames on one normalizer, one frame per
   run (after the first pass the trades are dropped as already seen, after decoding).
   [l2 replay] is the whole level2 recording per run: a fresh normalizer, the 50-level
   snapshot and 113 deltas (122 frames with acks and heartbeats). *)

open! Core
open Core_bench
open Coinbase_feed

(* Raw minute lines are [<recv_ts> <frame>]. *)
let frames text =
  String.split_lines text
  |> List.filter_map ~f:(fun line ->
    Option.map (String.lsplit2 line ~on:' ') ~f:(fun (_, frame) -> frame))
;;

let normalize t frame =
  ignore
    (Sys.opaque_identity (Normalizer.frame t ~recv_ts:Time_ns.epoch frame)
     : Normalizer.Output.t Or_error.t)
;;

let per_frame name text =
  let frames = Array.of_list (frames text) in
  let t = Normalizer.create () in
  let i = ref 0 in
  Bench.Test.create ~name (fun () ->
    let frame = frames.(!i) in
    i := (!i + 1) % Array.length frames;
    normalize t frame)
;;

let l2_replay () =
  let frames = frames Frames.l2 in
  Bench.Test.create ~name:"l2 replay" (fun () ->
    let t = Normalizer.create () in
    List.iter frames ~f:(normalize t))
;;

let () =
  Command_unix.run
    (Bench.make_command
       [ per_frame "trades" Frames.trades; per_frame "bbo" Frames.bbo; l2_replay () ])
;;
