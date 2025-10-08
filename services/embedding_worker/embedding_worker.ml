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
open Chessmate

let prefix_for = function
  | None -> "[worker]"
  | Some label -> Printf.sprintf "[worker:%s]" label

let log ?label msg = printf "%s %s\n%!" (prefix_for label) msg
let warn ?label msg = eprintf "%s %s\n%!" (prefix_for label) msg
let error ?label msg = eprintf "%s %s\n%!" (prefix_for label) msg

let fetch_env name =
  match Stdlib.Sys.getenv_opt name with
  | Some value when not (String.is_empty (String.strip value)) -> Or_error.return value
  | _ -> Or_error.errorf "%s not set" name

let process_job repo embedding_client ~label (job : Embedding_job.t) =
  match Embedding_client.embed_fens embedding_client [ job.fen ] with
  | Error err ->
      let _ = Repo_postgres.mark_job_failed repo ~job_id:job.id ~error:(Error.to_string_hum err) in
      error ?label (Printf.sprintf "job %d failed: %s" job.id (Error.to_string_hum err))
  | Ok vectors ->
      let vector_id = Stdlib.Digest.string job.fen |> Stdlib.Digest.to_hex in
      let () = ignore vectors in
      (match Repo_postgres.mark_job_completed repo ~job_id:job.id ~vector_id with
      | Ok () -> log ?label (Printf.sprintf "job %d completed" job.id)
      | Error err -> error ?label (Printf.sprintf "job %d completion update failed: %s" job.id (Error.to_string_hum err)))

let rec work_loop repo embedding_client ~poll_sleep ~label =
  match Repo_postgres.claim_pending_jobs repo ~limit:16 with
  | Error err ->
      warn ?label (Printf.sprintf "failed to fetch jobs: %s" (Error.to_string_hum err));
      Unix.sleepf poll_sleep;
      work_loop repo embedding_client ~poll_sleep ~label
  | Ok [] ->
      Unix.sleepf poll_sleep;
      work_loop repo embedding_client ~poll_sleep ~label
  | Ok jobs ->
      List.iter jobs ~f:(process_job repo embedding_client ~label);
      work_loop repo embedding_client ~poll_sleep ~label

let poll_sleep = ref 2.0
let concurrency = ref 1

let usage_msg = "Usage: embedding_worker [--poll-sleep SECONDS] [--workers COUNT]"

let anon_args = ref []

let () =
  let speclist =
    [ ( "--poll-sleep"
      , Stdlib.Arg.Set_float poll_sleep
      , "Seconds between polling attempts (default: 2.0)" )
    ; ( "--workers"
      , Stdlib.Arg.Set_int concurrency
      , "Number of worker loops to run concurrently (default: 1)" )
    ; ( "-w"
      , Stdlib.Arg.Set_int concurrency
      , "Alias for --workers" )
    ]
  in
  Stdlib.Arg.parse
    speclist
    (fun arg -> anon_args := arg :: !anon_args)
    usage_msg;
  (match !anon_args with
  | [] -> ()
  | _ ->
      eprintf "[worker][fatal] unexpected positional arguments: %s\n%!" (String.concat ~sep:" " (List.rev !anon_args));
      Stdlib.exit 1);
  let worker_count = Int.max 1 !concurrency in
  let sleep_interval = Float.max 0.1 !poll_sleep in
  let env_result =
    fetch_env "DATABASE_URL"
    |> Or_error.bind ~f:(fun db_url ->
           fetch_env "OPENAI_API_KEY"
           |> Or_error.bind ~f:(fun api_key ->
                  Repo_postgres.create db_url
                  |> Or_error.bind ~f:(fun repo ->
                         Embedding_client.create
                           ~api_key
                           ~endpoint:"https://api.openai.com/v1/embeddings"
                         |> Or_error.map ~f:(fun embedding_client -> (repo, embedding_client)))))
  in
  match env_result with
  | Error err ->
      eprintf "[worker][fatal] %s\n%!" (Error.to_string_hum err);
      Stdlib.exit 1
  | Ok (repo, embedding_client) ->
      if Int.equal worker_count 1 then (
        log "starting polling loop";
        work_loop repo embedding_client ~poll_sleep:sleep_interval ~label:None)
      else (
        log (Printf.sprintf "starting %d worker loops (poll_sleep=%.2fs)" worker_count sleep_interval);
        let labels =
          List.init worker_count ~f:(fun idx -> Some (Int.to_string (idx + 1)))
        in
        let threads =
          List.map labels ~f:(fun label ->
              Thread.create
                (fun label ->
                  log ?label "starting polling loop";
                  work_loop repo embedding_client ~poll_sleep:sleep_interval ~label)
                label)
        in
        List.iter threads ~f:Thread.join )
