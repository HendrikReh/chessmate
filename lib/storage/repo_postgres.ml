(** High-level Postgres repository that wraps Caqti queries to store games,
    positions, and embedding jobs for the ingestion and query pipelines. *)

open! Base
module Caqti_repo = Repo_postgres_caqti

type game_summary = Caqti_repo.game_summary = {
  id : int;
  white : string;
  black : string;
  result : string option;
  event : string option;
  opening_slug : string option;
  opening_name : string option;
  eco_code : string option;
  white_rating : int option;
  black_rating : int option;
  played_on : string option;
}

type t = { caqti : Caqti_repo.t }

type pool_stats = {
  capacity : int;
  in_use : int;
  available : int;
  waiting : int;
}

let create conninfo =
  if String.is_empty (String.strip conninfo) then
    Or_error.error_string "Postgres connection string cannot be empty"
  else Caqti_repo.create conninfo |> Or_error.map ~f:(fun caqti -> { caqti })

let pool_stats t =
  let stats = Caqti_repo.stats t.caqti in
  {
    capacity = stats.capacity;
    in_use = stats.in_use;
    available = Int.max 0 (stats.capacity - stats.in_use);
    waiting = stats.waiting;
  }

type vector_payload = Caqti_repo.vector_payload = {
  position_id : int;
  game_id : int;
  json : Yojson.Safe.t;
}

let insert_game repo ~metadata ~pgn ~moves =
  Caqti_repo.insert_game repo.caqti ~metadata ~pgn ~moves

type search_page = Caqti_repo.search_page = {
  games : game_summary list;
  total : int;
}

let search_games repo ~filters ~rating ~limit ~offset =
  Caqti_repo.search_games repo.caqti ~filters ~rating ~limit ~offset

let fetch_games_with_pgn repo ~ids =
  Caqti_repo.fetch_games_with_pgn repo.caqti ~ids

let pending_embedding_job_count repo =
  Caqti_repo.pending_embedding_job_count repo.caqti

let claim_pending_jobs repo ~limit =
  Caqti_repo.claim_pending_jobs repo.caqti ~limit

let mark_job_completed repo ~job_id ~vector_id =
  Caqti_repo.mark_job_completed repo.caqti ~job_id ~vector_id

let mark_job_failed repo ~job_id ~error =
  Caqti_repo.mark_job_failed repo.caqti ~job_id ~error

let vector_payload_for_job repo ~job_id =
  Caqti_repo.vector_payload_for_job repo.caqti ~job_id

module Private = Caqti_repo.Private
