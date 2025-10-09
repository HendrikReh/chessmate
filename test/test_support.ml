open! Base
open Stdio

let load_fixture name =
  let source_root = Stdlib.Sys.getenv_opt "DUNE_SOURCEROOT" |> Option.value ~default:"." in
  let path = Stdlib.Filename.concat source_root (Stdlib.Filename.concat "test/fixtures" name) in
  In_channel.read_all path
