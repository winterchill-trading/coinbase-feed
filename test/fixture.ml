open! Core

let data_dir = "fixtures"
let date = Date.of_string "2026-10-12"
let streams : Market_data.Stream.t list = [ Trades; Bbo; L2 ]

let frames stream =
  let path =
    sprintf
      "%s/raw/coinbase/%s/BTC-USD/2026/10/12/16-54.ndjson"
      data_dir
      (Market_data.Stream.to_string stream)
  in
  In_channel.read_lines path
  |> List.filter_map ~f:(fun line ->
    match Market_data.Raw_minute.Line.parse line |> ok_exn with
    | Frame { recv_ts; payload } -> Some (recv_ts, payload)
    | Disconnect -> None)
;;
