(* [Live_feed] takes frames from [Ws_client] through [on_message]; before, it read
   [Ws_client.messages] one frame at a time ([Live_feed.For_testing.start_via_messages]).
   Both deliveries are run over the recorded mainnet minute of every stream, written in
   one burst by the fake server: they must produce the same events, gaps and stats, and
   the new one saves the pipe hop's words per frame. *)

open! Core
open Async
open Coinbase_feed

let symbols = [ "BTC-USD" ]
let fixture_frames stream = List.map (Fixture.frames stream) ~f:snd
let key = {|"sequence_num":|}

(* [frame] with its [sequence_num] replaced by [seq], so repeated fixture frames read as
   one gapless connection. *)
let renumber frame ~seq =
  match String.substr_index frame ~pattern:key with
  | None -> frame
  | Some i ->
    let start = i + String.length key in
    let stop =
      String.lfindi frame ~pos:start ~f:(fun _ c -> not (Char.is_digit c))
      |> Option.value ~default:(String.length frame)
    in
    String.prefix frame start ^ Int.to_string seq ^ String.drop_prefix frame stop
;;

type run =
  { live : Live_feed.t
  ; server : Fake_ws.t
  ; seen : int ref
  ; until : (int * unit Ivar.t) option ref
  }

let start start stream =
  let%bind server = Fake_ws.start () in
  (* A clock that never moves: [recv_ts] is the same on both runs and no keepalive fires. *)
  let time_source = Time_source.read_only (Time_source.create ~now:Time_ns.epoch ()) in
  let seen = ref 0 in
  let until = ref None in
  (* Counts frames and wakes [deliver], without polling (a polling loop would add its own
     words to the measurement). *)
  let on_raw ~stream:_ ~recv_ts:_ _ =
    incr seen;
    match !until with
    | Some (target, ivar) when !seen >= target -> Ivar.fill_if_empty ivar ()
    | _ -> ()
  in
  let%bind live =
    start ~on_raw ~time_source (Fake_ws.config server) ~symbols ~streams:[ stream ]
  in
  let%map (_ : bool) =
    Fake_ws.wait_until (fun () -> not (List.is_empty (Fake_ws.received server)))
  in
  { live; server; seen; until }
;;

let burst frames = String.concat (List.map frames ~f:Fake_ws.encode_text_frame)

(* Writes [frames] in one burst and waits until the feed has seen them all. *)
let deliver { server; seen; until; _ } frames =
  let ivar = Ivar.create () in
  until := Some (!seen + List.length frames, ivar);
  Fake_ws.write_raw server (burst frames);
  Ivar.read ivar
;;

let drain pipe sexp_of =
  match Pipe.read_now' pipe with
  | `Ok q -> List.map (Queue.to_list q) ~f:sexp_of
  | `Eof | `Nothing_available -> []
;;

let outputs { live; _ } =
  let module F = (val Live_feed.feed_with_gaps live : Market_data.Feed.With_gaps.S) in
  [%sexp
    { trades = (drain F.trades Market_data.Trade.sexp_of_t : Sexp.t list)
    ; bbo = (drain F.bbo Market_data.Bbo.sexp_of_t : Sexp.t list)
    ; l2 = (drain F.l2 Market_data.L2_update.sexp_of_t : Sexp.t list)
    ; funding = (drain F.funding Market_data.Funding.sexp_of_t : Sexp.t list)
    ; gaps = (drain F.gaps Market_data.Gap.sexp_of_t : Sexp.t list)
    ; stats = (Live_feed.stats live : Live_feed.Stats.t)
    }]
;;

let stop { live; server; _ } =
  let module F = (val Live_feed.feed live : Market_data.Feed.S) in
  let%bind () = F.close () in
  Fake_ws.close server
;;

let via_messages ~on_raw ~time_source config ~symbols ~streams =
  Live_feed.For_testing.start_via_messages ~on_raw ~time_source config ~symbols ~streams
;;

let on_message ~on_raw ~time_source config ~symbols ~streams =
  Live_feed.start ~on_raw ~time_source config ~symbols ~streams
;;

let%expect_test "on_message and the messages pipe give the same output on every stream" =
  Log.Global.set_output [];
  let%map () =
    Deferred.List.iter ~how:`Sequential Fixture.streams ~f:(fun stream ->
      let frames = fixture_frames stream in
      let%bind old = start via_messages stream in
      let%bind new_ = start on_message stream in
      let%bind () = deliver old frames in
      let%bind () = deliver new_ frames in
      let old_out = outputs old in
      let new_out = outputs new_ in
      print_s
        [%message
          ""
            (stream : Market_data.Stream.t)
            ~frames:(List.length frames : int)
            ~same:(Sexp.equal old_out new_out : bool)
            ~sexp_bytes:(String.length (Sexp.to_string old_out) : int)];
      let%bind () = stop old in
      stop new_)
  in
  [%expect
    {|
    ((stream Trades) (frames 108) (same true) (sexp_bytes 60875))
    ((stream Bbo) (frames 135) (same true) (sexp_bytes 24658))
    ((stream L2) (frames 122) (same true) (sexp_bytes 56389))
    |}]
;;

(* Minor words per frame over the whole receive phase: socket reads, websocket framing,
   the delivery, [Normalizer.frame] and the pipe writes. The fake server's raw write of
   the burst is included and costs a few words in total. *)
let words_per_frame start_fn =
  let one_minute = fixture_frames Trades in
  let repeats = 10 in
  let frames ~from =
    List.concat (List.init repeats ~f:(fun _ -> one_minute))
    |> List.mapi ~f:(fun i frame -> renumber frame ~seq:(from + i))
  in
  let n = repeats * List.length one_minute in
  let warm_up = frames ~from:0 in
  let measured = frames ~from:n in
  let%bind run = start start_fn Market_data.Stream.Trades in
  (* A warm-up burst, so buffers are grown before measuring. *)
  let%bind () = deliver run warm_up in
  ignore (outputs run : Sexp.t);
  let before = Gc.minor_words () in
  let%bind () = deliver run measured in
  let words = Gc.minor_words () - before in
  ignore (outputs run : Sexp.t);
  let%map () = stop run in
  Float.of_int words /. Float.of_int n
;;

(* Prints [~expected] when [actual] is within [tolerance] of it, the value otherwise. *)
let approx ~expected ~tolerance actual =
  if Float.( <= ) (Float.abs (actual -. expected)) tolerance
  then sprintf "~%g" expected
  else sprintf "%.1f (pinned %g +/- %g)" actual expected tolerance
;;

let%expect_test "words per trades frame, end to end" =
  Log.Global.set_output [];
  let%bind old = words_per_frame via_messages in
  let%bind new_ = words_per_frame on_message in
  (* arm64 macOS, dev profile: 918.6 and 905.5, mostly the Yojson decode of trades frames.
     The totals carry the socket and framing work, so they get a few words of slack for
     Linux CI; the saving is the pipe hop, about 13 words per frame on every platform
     (venue-net's README). *)
  print_s
    [%message
      ""
        ~via_messages:(approx ~expected:919. ~tolerance:8. old : string)
        ~on_message:(approx ~expected:906. ~tolerance:8. new_ : string)
        ~saved:(approx ~expected:13. ~tolerance:1. (old -. new_) : string)];
  [%expect {| ((via_messages ~919) (on_message ~906) (saved ~13)) |}];
  return ()
;;
