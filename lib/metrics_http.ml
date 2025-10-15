(*  Chessmate - Hybrid chess tutor combining Postgres metadata with Qdrant
    vector search
   Copyright (C) 2025 Hendrik Reh <hendrik.reh@blacksmith-consulting.ai>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*)

open! Base
open Stdio

module Server = Prometheus_app.Cohttp (Cohttp_lwt_unix.Server)

type t = {
  thread : Thread.t;
  promise : unit Lwt.t;
  active : bool Stdlib.Atomic.t;
}

let validate_port port =
  if port < 1 || port > 65_535 then
    Or_error.errorf "prometheus port %d must be between 1 and 65535" port
  else Or_error.return port

let run_server promise =
  try Lwt_main.run promise
  with
  | Lwt.Canceled -> ()
  | exn ->
      eprintf "[metrics][error] Prometheus exporter stopped unexpectedly: %s\n%!"
        (Exn.to_string exn)

let start ~port =
  match validate_port port with
  | Error _ as err -> err
  | Ok port ->
      let mode = `TCP (`Port port) in
      let callback = Server.callback in
      let server =
        Cohttp_lwt_unix.Server.create ~mode
          (Cohttp_lwt_unix.Server.make ~callback ())
      in
      let runner =
        Thread.create
          (fun promise -> run_server promise)
          server
      in
      let active = Stdlib.Atomic.make true in
      eprintf "[metrics] Prometheus exporter listening on :%d\n%!" port;
      Or_error.return { thread = runner; promise = server; active }

let stop exporter =
  let was_active = Stdlib.Atomic.exchange exporter.active false in
  if was_active then (
    Lwt.cancel exporter.promise;
    (* Ignore join failures — the thread might already be finished. *)
    try Thread.join exporter.thread with _ -> ())

let start_if_configured ~port =
  match port with
  | None -> Or_error.return None
  | Some port -> start ~port |> Or_error.map ~f:Option.some

let stop_opt = function None -> () | Some exporter -> stop exporter
