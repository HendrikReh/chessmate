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

let log msg = printf "[worker] %s\n%!" msg
let warn msg = eprintf "[worker][warn] %s\n%!" msg
let error msg = eprintf "[worker][error] %s\n%!" msg

let fetch_env name =
  match Stdlib.Sys.getenv_opt name with
  | Some value when not (String.is_empty (String.strip value)) -> Or_error.return value
  | _ -> Or_error.errorf "%s not set" name

let process_job repo embedding_client job =
  match Repo_postgres.mark_job_started repo ~job_id:job.Embedding_job.id with
  | Error err -> error (Error.to_string_hum err)
  | Ok () ->
      (match Embedding_client.embed_fens embedding_client [ job.fen ] with
      | Error err ->
          let _ = Repo_postgres.mark_job_failed repo ~job_id:job.id ~error:(Error.to_string_hum err) in
          error (Printf.sprintf "job %d failed: %s" job.id (Error.to_string_hum err))
      | Ok vectors ->
          let vector_id = Stdlib.Digest.string job.fen |> Stdlib.Digest.to_hex in
          let () = ignore vectors in
          (match Repo_postgres.mark_job_completed repo ~job_id:job.id ~vector_id with
          | Ok () -> log (Printf.sprintf "job %d completed" job.id)
          | Error err -> error (Printf.sprintf "job %d completion update failed: %s" job.id (Error.to_string_hum err))))

let rec work_loop repo embedding_client ~poll_sleep =
  match Repo_postgres.fetch_pending_jobs repo ~limit:16 with
  | Error err ->
      warn (Printf.sprintf "failed to fetch jobs: %s" (Error.to_string_hum err));
      Unix.sleepf poll_sleep;
      work_loop repo embedding_client ~poll_sleep
  | Ok [] ->
      Unix.sleepf poll_sleep;
      work_loop repo embedding_client ~poll_sleep
  | Ok jobs ->
      List.iter jobs ~f:(process_job repo embedding_client);
      work_loop repo embedding_client ~poll_sleep

let () =
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
      log "starting polling loop";
      work_loop repo embedding_client ~poll_sleep:2.0
