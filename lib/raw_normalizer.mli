(** {!Normalizer} as a {!Market_data.Normalizer.S}, so [Market_data.Rebuild_norm] can
    rebuild Coinbase event logs from market-recorder raw files:

    {[
      Market_data.Rebuild_norm.command [ (module Coinbase_feed.Raw_normalizer) ]
    ]}

    {!Normalizer} has no reset; [disconnect] replaces the state with a fresh one, as a new
    connection would start it. Error frames from Coinbase count as rejected frames. *)

include Market_data.Normalizer.S
