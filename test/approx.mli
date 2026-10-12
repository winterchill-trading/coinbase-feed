(** Pinning numbers that differ slightly between platforms in expect tests. *)

open! Core

(** [approx ~expected ~tolerance actual] is the atom [expected+-tolerance] when [actual]
    is within [tolerance] of [expected], and [actual] otherwise, so a small drift (minor
    words differ by a few between macOS and Linux) keeps the expected output, and a real
    change shows the new number. *)
val approx : expected:int -> tolerance:int -> int -> Sexp.t
