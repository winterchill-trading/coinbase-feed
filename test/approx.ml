open! Core

let approx ~expected ~tolerance actual =
  if abs (actual - expected) <= tolerance
  then Sexp.Atom (sprintf "%d+-%d" expected tolerance)
  else [%sexp (actual : int)]
;;
