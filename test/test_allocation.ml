(* Minor words allocated per Live_feed message: what [Normalizer.frame] (JSON decode plus
   conversion, the work [Live_feed] does per websocket frame) allocates on the recorded
   mainnet minute. Counts differ by a few words between macOS and Linux, so they are
   pinned with a tolerance. The timing benchmark is in bench/. *)

open! Core
open Coinbase_feed

let words f =
  let before = Gc.minor_words () in
  f ();
  Gc.minor_words () - before
;;

let measure stream =
  let t = Normalizer.create () in
  List.map (Fixture.frames stream) ~f:(fun (recv_ts, frame) ->
    ( words (fun () ->
        ignore
          (Sys.opaque_identity (Normalizer.frame t ~recv_ts frame)
           : Normalizer.Output.t Or_error.t))
    , String.length frame ))
;;

(* Pinned counts. macOS and Linux differ by a few words, which [Approx.approx] absorbs.
   The tolerances below are the same kind of slack. *)
(* expected (words per frame, max words) per stream, within 2% and 1%, at least 16 words *)
(* Repinned 2026-10-13: the counts fell from 914/608/1982 with no change in this repo,
   because fixed-decimal now parses prices and sizes in place. Identical on macOS and
   Linux CI. *)
let expected : Market_data.Stream.t -> int * int = function
  | Trades -> 839, 20227
  | Bbo -> 560, 625
  | L2 -> 1728, 28539
  | Funding | Private -> 0, 0
;;

let%expect_test "minor words per Live_feed message" =
  List.iter Fixture.streams ~f:(fun stream ->
    let per_frame = measure stream in
    let n = List.length per_frame in
    let total = List.sum (module Int) per_frame ~f:fst in
    let bytes = List.sum (module Int) per_frame ~f:snd in
    let max = List.fold per_frame ~init:0 ~f:(fun acc (w, _) -> Int.max acc w) in
    let per_frame_words, max_words = expected stream in
    print_s
      [%message
        ""
          (stream : Market_data.Stream.t)
          ~frames:(n : int)
          ~words_per_frame:
            (Approx.approx
               ~expected:per_frame_words
               ~tolerance:(Int.max 16 (per_frame_words / 50))
               (total / n)
             : Sexp.t)
          ~max_words:
            (Approx.approx
               ~expected:max_words
               ~tolerance:(Int.max 16 (max_words / 100))
               max
             : Sexp.t)
          ~bytes_per_frame:(bytes / n : int)]);
  [%expect
    {|
    ((stream Trades) (frames 108) (words_per_frame 839+-16)
     (max_words 20227+-202) (bytes_per_frame 526))
    ((stream Bbo) (frames 135) (words_per_frame 560+-16) (max_words 625+-16)
     (bytes_per_frame 413))
    ((stream L2) (frames 122) (words_per_frame 1728+-34) (max_words 28539+-285)
     (bytes_per_frame 1247))
    |}]
;;
