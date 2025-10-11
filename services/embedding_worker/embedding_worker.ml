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

(** Long-running worker that drains pending embedding jobs, batches OpenAI
    calls, upserts Qdrant vectors, and updates job status with retries and
    telemetry. *)

open! Base
open Stdio
open Chessmate

let prefix_for = function
  | None -> "[worker]"
  | Some label -> Printf.sprintf "[worker:%s]" label

let log ?label msg = printf "%s %s\n%!" (prefix_for label) msg
let warn ?label msg = eprintf "%s %s\n%!" (prefix_for label) msg
let error ?label msg = eprintf "%s %s\n%!" (prefix_for label) msg

type stats = { mutable processed : int; mutable failed : int }

let stats_lock = Stdlib.Mutex.create ()

let record_result stats ~failed =
  Stdlib.Mutex.lock stats_lock;
  stats.processed <- stats.processed + 1;
  if failed then stats.failed <- stats.failed + 1;
  Stdlib.Mutex.unlock stats_lock

type exit_condition = {
  limit : int option;
  mutable empty_streak : int;
  mutable triggered : bool;
  mutable announced : bool;
  mutex : Stdlib.Mutex.t;
}

let make_exit_condition limit =
  {
    limit;
    empty_streak = 0;
    triggered = false;
    announced = false;
    mutex = Stdlib.Mutex.create ();
  }

let should_stop exit_condition =
  Stdlib.Mutex.lock exit_condition.mutex;
  let triggered = exit_condition.triggered in
  Stdlib.Mutex.unlock exit_condition.mutex;
  triggered

let note_jobs exit_condition =
  match exit_condition.limit with
  | None -> ()
  | Some _ ->
      Stdlib.Mutex.lock exit_condition.mutex;
      exit_condition.empty_streak <- 0;
      Stdlib.Mutex.unlock exit_condition.mutex

let note_empty exit_condition =
  Stdlib.Mutex.lock exit_condition.mutex;
  let result =
    match exit_condition.limit with
    | None -> `Continue
    | Some limit ->
        if exit_condition.triggered then `Stop false
        else (
          exit_condition.empty_streak <- exit_condition.empty_streak + 1;
          if exit_condition.empty_streak >= limit then (
            exit_condition.triggered <- true;
            `Stop true)
          else `Continue)
  in
  Stdlib.Mutex.unlock exit_condition.mutex;
  result

let force_stop exit_condition =
  Stdlib.Mutex.lock exit_condition.mutex;
  exit_condition.triggered <- true;
  Stdlib.Mutex.unlock exit_condition.mutex

let install_signal_handlers exit_condition =
  let handler_for signal_name =
    Stdlib.Sys.Signal_handle
      (fun _ ->
        log (Printf.sprintf "%s received, requesting shutdown" signal_name);
        force_stop exit_condition)
  in
  Stdlib.Sys.set_signal Stdlib.Sys.sigint (handler_for "SIGINT");
  Stdlib.Sys.set_signal Stdlib.Sys.sigterm (handler_for "SIGTERM")

let qdrant_retry_max_attempts = 3
let qdrant_retry_initial_delay = 0.5
let qdrant_retry_multiplier = 2.0
let qdrant_retry_jitter = 0.2

let add_payload_field json ~key ~value =
  match json with
  | `Assoc fields -> `Assoc ((key, value) :: fields)
  | _ -> `Assoc [ (key, value) ]

let upsert_vector ?label point =
  Retry.with_backoff ~max_attempts:qdrant_retry_max_attempts
    ~initial_delay:qdrant_retry_initial_delay
    ~multiplier:qdrant_retry_multiplier ~jitter:qdrant_retry_jitter
    ~on_retry:(fun ~attempt ~delay err ->
      warn ?label
        (Printf.sprintf
           "[qdrant] upsert attempt %d/%d failed: %s (retrying in %.2fs)"
           attempt qdrant_retry_max_attempts (Error.to_string_hum err) delay))
    ~f:(fun ~attempt ->
      match Repo_qdrant.upsert_points [ point ] with
      | Ok () -> Retry.Resolved (Or_error.return ())
      | Error err ->
          if Int.(attempt >= qdrant_retry_max_attempts) then
            Retry.Resolved (Error err)
          else Retry.Retry err)
    ()

let mark_announced exit_condition =
  Stdlib.Mutex.lock exit_condition.mutex;
  let first = not exit_condition.announced in
  exit_condition.announced <- true;
  Stdlib.Mutex.unlock exit_condition.mutex;
  first

let process_job repo embedding_client ~label stats (job : Embedding_job.t) =
  match Embedding_client.embed_fens embedding_client [ job.fen ] with
  | Error err ->
      let message = Sanitizer.sanitize_error err in
      let _ =
        Repo_postgres.mark_job_failed repo ~job_id:job.id ~error:message
      in
      error ?label (Printf.sprintf "job %d failed: %s" job.id message);
      record_result stats ~failed:true
  | Ok [] ->
      let message = "embedding client returned no vectors" in
      let _ =
        Repo_postgres.mark_job_failed repo ~job_id:job.id ~error:message
      in
      error ?label (Printf.sprintf "job %d failed: %s" job.id message);
      record_result stats ~failed:true
  | Ok (vector :: _ as embeddings) -> (
      if List.length embeddings > 1 then
        warn ?label
          (Printf.sprintf
             "job %d returned multiple vectors; using the first entry" job.id);
      let vector_id = Stdlib.Digest.string job.fen |> Stdlib.Digest.to_hex in
      let vector_values = Array.to_list vector in
      match Repo_postgres.vector_payload_for_job repo ~job_id:job.id with
      | Error err ->
          let message = Sanitizer.sanitize_error err in
          let _ =
            Repo_postgres.mark_job_failed repo ~job_id:job.id ~error:message
          in
          error ?label (Printf.sprintf "job %d failed: %s" job.id message);
          record_result stats ~failed:true
      | Ok context -> (
          let payload =
            context.Repo_postgres.json
            |> add_payload_field ~key:"fen" ~value:(`String job.fen)
            |> add_payload_field ~key:"vector_id" ~value:(`String vector_id)
          in
          let point =
            { Repo_qdrant.id = vector_id; vector = vector_values; payload }
          in
          let upsert_result = upsert_vector ?label point in
          match upsert_result with
          | Ok () -> (
              match
                Repo_postgres.mark_job_completed repo ~job_id:job.id ~vector_id
              with
              | Ok () ->
                  log ?label (Printf.sprintf "job %d completed" job.id);
                  record_result stats ~failed:false
              | Error err ->
                  let message = Error.to_string_hum err in
                  let _ =
                    Repo_postgres.mark_job_failed repo ~job_id:job.id
                      ~error:message
                  in
                  error ?label
                    (Printf.sprintf "job %d failed: %s" job.id message);
                  record_result stats ~failed:true)
          | Error err ->
              let message = Error.to_string_hum err in
              let _ =
                Repo_postgres.mark_job_failed repo ~job_id:job.id ~error:message
              in
              error ?label (Printf.sprintf "job %d failed: %s" job.id message);
              record_result stats ~failed:true))

let rec work_loop repo embedding_client ~poll_sleep ~label stats exit_condition
    =
  if should_stop exit_condition then ()
  else
    match Repo_postgres.claim_pending_jobs repo ~limit:16 with
    | Error err ->
        warn ?label
          (Printf.sprintf "failed to fetch jobs: %s"
             (Sanitizer.sanitize_error err));
        Unix.sleepf poll_sleep;
        work_loop repo embedding_client ~poll_sleep ~label stats exit_condition
    | Ok [] -> (
        match note_empty exit_condition with
        | `Continue ->
            Unix.sleepf poll_sleep;
            work_loop repo embedding_client ~poll_sleep ~label stats
              exit_condition
        | `Stop first_trigger ->
            (if first_trigger then
               let first_global = mark_announced exit_condition in
               if first_global then
                 log ?label "exit-after-empty threshold reached"
               else ());
            ())
    | Ok jobs ->
        note_jobs exit_condition;
        List.iter jobs ~f:(process_job repo embedding_client ~label stats);
        work_loop repo embedding_client ~poll_sleep ~label stats exit_condition

let poll_sleep = ref 2.0
let concurrency = ref 1
let exit_after_empty = ref None

let usage_msg =
  "Usage: embedding_worker [--poll-sleep SECONDS] [--workers COUNT] \
   [--exit-after-empty N]"

let anon_args = ref []

let worker_config : Config.Worker.t =
  match Config.Worker.load () with
  | Ok config -> config
  | Error err ->
      eprintf "[worker][fatal] %s\n%!" (Sanitizer.sanitize_error err);
      Stdlib.exit 1

let () =
  match Config.Api.load () with
  | Ok api_config -> (
      match api_config.Config.Api.qdrant_collection with
      | None -> ()
      | Some { Config.Api.Qdrant.name; vector_size; distance } -> (
          match Repo_qdrant.ensure_collection ~name ~vector_size ~distance with
          | Ok () ->
              eprintf "[worker][config] qdrant collection ensured (name=%s)\n%!"
                name
          | Error err ->
              eprintf "[worker][fatal] qdrant collection ensure failed: %s\n%!"
                (Sanitizer.sanitize_error err);
              Stdlib.exit 1))
  | Error _ -> ()

let () =
  let speclist =
    [
      ( "--poll-sleep",
        Stdlib.Arg.Set_float poll_sleep,
        "Seconds between polling attempts (default: 2.0)" );
      ( "--workers",
        Stdlib.Arg.Set_int concurrency,
        "Number of worker loops to run concurrently (default: 1)" );
      ( "--exit-after-empty",
        Stdlib.Arg.Int (fun n -> exit_after_empty := Some (Int.max 1 n)),
        "Exit after N consecutive empty polls (default: run indefinitely)" );
      ("-w", Stdlib.Arg.Set_int concurrency, "Alias for --workers");
    ]
  in
  Stdlib.Arg.parse speclist
    (fun arg -> anon_args := arg :: !anon_args)
    usage_msg;
  (match !anon_args with
  | [] -> ()
  | _ ->
      eprintf "[worker][fatal] unexpected positional arguments: %s\n%!"
        (String.concat ~sep:" " (List.rev !anon_args));
      Stdlib.exit 1);
  let sleep_interval = Float.max 0.1 !poll_sleep in
  let env_result =
    Repo_postgres.create worker_config.Config.Worker.database_url
    |> Or_error.bind ~f:(fun repo ->
           Embedding_client.create
             ~api_key:worker_config.Config.Worker.openai_api_key
             ~endpoint:worker_config.Config.Worker.openai_endpoint
           |> Or_error.map ~f:(fun embedding_client -> (repo, embedding_client)))
  in
  match env_result with
  | Error err ->
      eprintf "[worker][fatal] %s\n%!" (Sanitizer.sanitize_error err);
      Stdlib.exit 1
  | Ok (repo, embedding_client) ->
      let start_time = Unix.gettimeofday () in
      let stats = { processed = 0; failed = 0 } in
      let exit_condition = make_exit_condition !exit_after_empty in
      install_signal_handlers exit_condition;
      let worker_count = Int.max 1 !concurrency in
      let exit_after_summary =
        match !exit_after_empty with
        | None -> "disabled"
        | Some n -> Printf.sprintf "after-%d-empty-polls" n
      in
      log
        (Printf.sprintf
           "configuration: database=present openai_key=present workers=%d \
            poll_sleep=%.2fs exit_after_empty=%s"
           worker_count sleep_interval exit_after_summary);
      if Int.equal worker_count 1 then (
        log "starting polling loop";
        Stdlib.Sys.catch_break false;
        let run () =
          work_loop repo embedding_client ~poll_sleep:sleep_interval ~label:None
            stats exit_condition
        in
        (try run () with
        | Stdlib.Sys.Break ->
            log "interrupt received, shutting down";
            force_stop exit_condition
        | exn ->
            warn "unexpected exception, shutting down";
            warn (Exn.to_string exn);
            force_stop exit_condition);
        let elapsed = Unix.gettimeofday () -. start_time in
        log
          (Printf.sprintf "summary: processed=%d failures=%d duration=%.2fs"
             stats.processed stats.failed elapsed))
      else (
        log
          (Printf.sprintf "starting %d worker loops (poll_sleep=%.2fs)"
             worker_count sleep_interval);
        Stdlib.Sys.catch_break false;
        let labels =
          List.init worker_count ~f:(fun idx -> Some (Int.to_string (idx + 1)))
        in
        let threads =
          List.map labels ~f:(fun label ->
              Thread.create
                (fun label ->
                  log ?label "starting polling loop";
                  work_loop repo embedding_client ~poll_sleep:sleep_interval
                    ~label stats exit_condition)
                label)
        in
        let rec join_all () =
          try List.iter threads ~f:Thread.join
          with Stdlib.Sys.Break ->
            log "interrupt received, cancelling workers";
            force_stop exit_condition;
            join_all ()
        in
        (try join_all ()
         with exn ->
           warn "unexpected exception, cancelling workers";
           warn (Exn.to_string exn);
           force_stop exit_condition;
           List.iter threads ~f:(fun thread ->
               try Thread.join thread with _ -> ()));
        let elapsed = Unix.gettimeofday () -. start_time in
        log
          (Printf.sprintf "summary: processed=%d failures=%d duration=%.2fs"
             stats.processed stats.failed elapsed))
