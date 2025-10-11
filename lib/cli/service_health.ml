(*  Chessmate - Hybrid chess tutor combining Postgres metadata with Qdrant
    vector search *)

open! Base
open Stdio

module Http = struct
  let get url =
    let open Lwt.Syntax in
    let request =
      Lwt.catch
        (fun () ->
          let uri = Uri.of_string url in
          let* response, body = Cohttp_lwt_unix.Client.get uri in
          let status = Cohttp.Response.status response |> Cohttp.Code.code_of_status in
          let* body_text = Cohttp_lwt.Body.to_string body in
          Lwt.return (Ok (status, body_text)))
        (fun exn -> Lwt.return (Error (Exn.to_string exn)))
    in
    try Lwt_main.run request with
    | exn -> Error (Exn.to_string exn)
end

type availability =
  | Available of string option
  | Skipped of string
  | Unavailable of string

type status = {
  name : string;
  availability : availability;
  fatal : bool;
}

let sanitize = Sanitizer.sanitize_string

let status_line status =
  let label, detail =
    match status.availability with
    | Available None -> "ok", ""
    | Available (Some info) -> "ok", Printf.sprintf " (%s)" info
    | Skipped reason -> "skipped", Printf.sprintf " (%s)" reason
    | Unavailable reason -> "error", Printf.sprintf " (%s)" reason
  in
  Printf.sprintf "[health] %-13s %s%s" status.name label detail

let print_status status = eprintf "%s\n%!" (status_line status)

let trim_env name =
  Stdlib.Sys.getenv_opt name
  |> Option.map ~f:String.strip
  |> Option.filter ~f:(fun value -> not (String.is_empty value))

let normalize_base url = String.rstrip (String.strip url) ~drop:(Char.equal '/')

let check_postgres () =
  let name = "postgres" in
  match trim_env "DATABASE_URL" with
  | None -> { name; availability = Skipped "DATABASE_URL not set"; fatal = false }
  | Some url ->
      (match Repo_postgres.create url with
      | Error err -> { name; availability = Unavailable (Sanitizer.sanitize_error err); fatal = true }
      | Ok repo -> (match Repo_postgres.pending_embedding_job_count repo with
          | Ok pending ->
              {
                name;
                availability = Available (Some (Printf.sprintf "pending_jobs=%d" pending));
                fatal = true;
              }
          | Error err -> { name; availability = Unavailable (Sanitizer.sanitize_error err); fatal = true }))

let check_qdrant () =
  let name = "qdrant" in
  match trim_env "QDRANT_URL" with
  | None -> { name; availability = Skipped "QDRANT_URL not set"; fatal = false }
  | Some base ->
      let base = normalize_base base in
      let endpoints = [ "/healthz"; "/health"; "/collections" ] in
      let rec attempt last_error = function
        | [] ->
            let reason = Option.value last_error ~default:"no reachable endpoint" in
            { name; availability = Unavailable (sanitize reason); fatal = true }
        | path :: rest -> (
            match Http.get (base ^ path) with
            | Ok (200, _) ->
                { name; availability = Available (Some (Printf.sprintf "200 %s" path)); fatal = true }
            | Ok (status, body) ->
                let snippet = String.prefix (sanitize body) 120 in
                let message = Printf.sprintf "%s returned %d %s" path status snippet in
                attempt (Some message) rest
            | Error err -> attempt (Some (sanitize err)) rest)
      in
      attempt None endpoints

let parse_ttl () =
  match trim_env "AGENT_CACHE_TTL_SECONDS" with
  | None -> Or_error.return None
  | Some raw -> (
      match Config.Helpers.parse_positive_int "AGENT_CACHE_TTL_SECONDS" raw with
      | Ok value -> Or_error.return (Some value)
      | Error err -> Error err)

let check_redis () =
  let name = "redis" in
  match trim_env "AGENT_CACHE_REDIS_URL" with
  | None -> { name; availability = Skipped "AGENT_CACHE_REDIS_URL not set"; fatal = false }
  | Some url ->
      (match parse_ttl () with
      | Error err -> { name; availability = Unavailable (Sanitizer.sanitize_error err); fatal = true }
      | Ok ttl_seconds ->
          let namespace = trim_env "AGENT_CACHE_REDIS_NAMESPACE" in
          (match Agent_cache.create_redis ?namespace ?ttl_seconds url with
          | Error err -> { name; availability = Unavailable (Sanitizer.sanitize_error err); fatal = true }
          | Ok cache ->
              (match Or_error.try_with (fun () ->
                         ignore (Agent_cache.find cache "__chessmate_health__");
                         ())
              with
              | Ok () -> { name; availability = Available None; fatal = true }
              | Error err -> { name; availability = Unavailable (Sanitizer.sanitize_error err); fatal = true })))

let check_api () =
  let name = "chessmate-api" in
  let base = normalize_base (Config.Cli.api_base_url ()) in
  let url = base ^ "/health" in
  match Http.get url with
  | Ok (200, _) -> { name; availability = Available None; fatal = true }
  | Ok (status, body) ->
      let snippet = String.prefix (sanitize body) 120 in
      { name; availability = Unavailable (Printf.sprintf "%d %s" status snippet); fatal = true }
  | Error err -> { name; availability = Unavailable (sanitize err); fatal = true }

let check_all () = [ check_postgres (); check_qdrant (); check_redis (); check_api () ]

let report statuses = List.iter statuses ~f:print_status

let ensure_all () =
  let statuses = check_all () in
  report statuses;
  match
    List.find statuses ~f:(function
        | { availability = Unavailable _; fatal = true; _ } -> true
        | _ -> false)
  with
  | None -> Or_error.return ()
  | Some { name; availability = Unavailable reason; _ } ->
      Or_error.errorf "%s unavailable: %s" name reason
  | Some _ -> Or_error.return ()
