open! Core

type t = Normalizer.t ref

let venue = Market_data.Venue.Coinbase
let create () = ref (Normalizer.create ())

let frame t ~recv_ts payload =
  Or_error.map (Normalizer.frame !t ~recv_ts payload) ~f:(fun (o : Normalizer.Output.t) ->
    o.events)
;;

let disconnect t = t := Normalizer.create ()
