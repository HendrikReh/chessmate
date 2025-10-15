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
open Cohttp
open Cohttp_lwt_unix

module Metrics = struct
  type t = {
    processed : int;
    failed : int;
    jobs_per_min : float;
    chars_per_sec : float;
    queue_depth : int;
  }
end

let respond_json status body =
  let headers = Header.init_with "Content-Type" "application/json" in
  Server.respond_string ~status ~headers ~body ()

let respond_text status body =
  let headers = Header.init_with "Content-Type" "text/plain; charset=utf-8" in
  Server.respond_string ~status ~headers ~body ()

let format_metrics (metrics : Metrics.t) =
  Printf.sprintf
    "embedding_worker_processed_total %d\n\
     embedding_worker_failed_total %d\n\
     embedding_worker_jobs_per_min %.6f\n\
     embedding_worker_characters_per_sec %.6f\n\
     embedding_worker_queue_depth %d\n"
    metrics.processed metrics.failed metrics.jobs_per_min metrics.chars_per_sec
    metrics.queue_depth

let start ~port ~summary ~metrics =
  Or_error.try_with (fun () ->
      let stop_waiter, stopper = Lwt.wait () in
      let callback _conn req _body =
        let uri = Request.uri req in
        match (Request.meth req, Uri.path uri) with
        | `GET, "/health" ->
            let summary = summary () in
            let status = Health.http_status_of summary.Health.status in
            let status_code = (status :> Cohttp.Code.status_code) in
            let body =
              summary |> Health.summary_to_yojson |> Yojson.Safe.to_string
            in
            respond_json status_code body
        | `GET, "/metrics" -> (
            match metrics () with
            | Ok metrics ->
                let body = format_metrics metrics in
                respond_text `OK body
            | Error err ->
                let message = Sanitizer.sanitize_string err in
                respond_text `Internal_server_error
                  (Printf.sprintf "error %s\n" message))
        | _ -> Server.respond_not_found ()
      in
      let server = Server.make ~callback () in
      let mode = `TCP (`Port port) in
      let thread =
        Thread.create
          (fun () ->
            try
              Stdio.eprintf "[worker][health] listening on 0.0.0.0:%d\n%!" port;
              Lwt_main.run (Server.create ~mode ~stop:stop_waiter server)
            with exn ->
              Stdio.eprintf "[worker][health] server exception: %s\n%!"
                (Sanitizer.sanitize_string (Exn.to_string exn)))
          ()
      in
      fun () ->
        if Lwt.is_sleeping stop_waiter then Lwt.wakeup_later stopper ();
        Thread.join thread)
