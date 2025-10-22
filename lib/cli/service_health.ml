open! Base
open Stdio

let ( let* ) t f = Or_error.bind t ~f

module Http = struct
  let get ?(timeout = 5.) url =
    let open Lwt.Syntax in
    let request =
      Lwt.catch
        (fun () ->
          let uri = Uri.of_string url in
          let* response, body = Cohttp_lwt_unix.Client.get uri in
          let status =
            Cohttp.Response.status response |> Cohttp.Code.code_of_status
          in
          let* body_text = Cohttp_lwt.Body.to_string body in
          Lwt.return (Ok (status, body_text)))
        (fun exn -> Lwt.return (Error (Exn.to_string exn)))
    in
    let timeout_promise =
      let* () = Lwt_unix.sleep timeout in
      Lwt.return
        (Error
           (Printf.sprintf "request timed out after %.1fs when calling %s"
              timeout url))
    in
    try Lwt_main.run (Lwt.pick [ request; timeout_promise ])
    with exn -> Error (Exn.to_string exn)
end

type availability =
  | Available of string option
  | Skipped of string
  | Unavailable of string

type status = { name : string; availability : availability; fatal : bool }

type summary = {
  statuses : status list;
  fatal : status option;
  warnings : status list;
}

let sanitize = Sanitizer.sanitize_string

let status_line status =
  let label, detail =
    match status.availability with
    | Available None -> ("ok", "")
    | Available (Some info) -> ("ok", Printf.sprintf " (%s)" info)
    | Skipped reason -> ("skipped", Printf.sprintf " (%s)" reason)
    | Unavailable reason -> ("error", Printf.sprintf " (%s)" reason)
  in
  Printf.sprintf "[health] %-13s %s%s" status.name label detail

let print_status status = eprintf "%s\n%!" (status_line status)
let normalize_base url = String.rstrip (String.strip url) ~drop:(Char.equal '/')

let check_postgres () =
  let name = "postgres" in
  match Config.Helpers.optional "DATABASE_URL" with
  | None ->
      { name; availability = Skipped "DATABASE_URL not set"; fatal = false }
  | Some url -> (
      match Repo_postgres.create url with
      | Error err ->
          {
            name;
            availability = Unavailable (Sanitizer.sanitize_error err);
            fatal = true;
          }
      | Ok repo -> (
          match Repo_postgres.pending_embedding_job_count repo with
          | Ok pending ->
              {
                name;
                availability =
                  Available (Some (Printf.sprintf "pending_jobs=%d" pending));
                fatal = true;
              }
          | Error err ->
              {
                name;
                availability = Unavailable (Sanitizer.sanitize_error err);
                fatal = true;
              }))

let check_qdrant ~timeout =
  let name = "qdrant" in
  match Config.Helpers.optional "QDRANT_URL" with
  | None -> { name; availability = Skipped "QDRANT_URL not set"; fatal = false }
  | Some base ->
      let base = normalize_base base in
      let endpoints = [ "/healthz"; "/health"; "/collections" ] in
      let rec attempt last_error = function
        | [] ->
            let reason =
              Option.value last_error ~default:"no reachable endpoint"
            in
            { name; availability = Unavailable (sanitize reason); fatal = true }
        | path :: rest -> (
            match Http.get ~timeout (base ^ path) with
            | Ok (200, _) ->
                {
                  name;
                  availability = Available (Some (Printf.sprintf "200 %s" path));
                  fatal = true;
                }
            | Ok (status, body) ->
                let snippet = String.prefix (sanitize body) 120 in
                let message =
                  Printf.sprintf "%s returned %d %s" path status snippet
                in
                attempt (Some message) rest
            | Error err -> attempt (Some (sanitize err)) rest)
      in
      attempt None endpoints

let parse_ttl () =
  match Config.Helpers.optional "AGENT_CACHE_TTL_SECONDS" with
  | None -> Or_error.return None
  | Some raw -> (
      match Config.Helpers.parse_positive_int "AGENT_CACHE_TTL_SECONDS" raw with
      | Ok value -> Or_error.return (Some value)
      | Error err -> Error err)

let check_redis () =
  let name = "redis" in
  match Config.Helpers.optional "AGENT_CACHE_REDIS_URL" with
  | None ->
      {
        name;
        availability = Skipped "AGENT_CACHE_REDIS_URL not set";
        fatal = false;
      }
  | Some url -> (
      match parse_ttl () with
      | Error err ->
          {
            name;
            availability = Unavailable (Sanitizer.sanitize_error err);
            fatal = true;
          }
      | Ok ttl_seconds -> (
          let namespace =
            Config.Helpers.optional "AGENT_CACHE_REDIS_NAMESPACE"
          in
          match Agent_cache.create_redis ?namespace ?ttl_seconds url with
          | Error err ->
              {
                name;
                availability = Unavailable (Sanitizer.sanitize_error err);
                fatal = true;
              }
          | Ok cache -> (
              match
                Or_error.try_with (fun () ->
                    ignore (Agent_cache.find cache "__chessmate_health__");
                    ())
              with
              | Ok () -> { name; availability = Available None; fatal = true }
              | Error err ->
                  {
                    name;
                    availability = Unavailable (Sanitizer.sanitize_error err);
                    fatal = true;
                  })))

let check_api ~timeout =
  let name = "chessmate-api" in
  let base = normalize_base (Config.Cli.api_base_url ()) in
  let url = base ^ "/health" in
  match Http.get ~timeout url with
  | Ok (200, _) -> { name; availability = Available None; fatal = true }
  | Ok (status, body) ->
      let snippet = String.prefix (sanitize body) 120 in
      {
        name;
        availability = Unavailable (Printf.sprintf "%d %s" status snippet);
        fatal = true;
      }
  | Error err ->
      { name; availability = Unavailable (sanitize err); fatal = true }

let check_openai_retry () =
  let name = "openai-retry" in
  match Openai_common.load_retry_config () with
  | Ok _ -> { name; availability = Available None; fatal = true }
  | Error err ->
      {
        name;
        availability = Unavailable (Sanitizer.sanitize_error err);
        fatal = true;
      }

let check_all ~timeout =
  [
    check_postgres ();
    check_qdrant ~timeout;
    check_redis ();
    check_api ~timeout;
    check_openai_retry ();
  ]

let summarize statuses =
  let fatal =
    List.find statuses ~f:(function
      | { availability = Unavailable _; fatal = true; _ } -> true
      | _ -> false)
  in
  let warnings =
    List.filter statuses ~f:(function
      | { availability = Skipped _; fatal = false; _ } -> true
      | _ -> false)
  in
  { statuses; fatal; warnings }

let check () =
  let* timeout =
    Cli_common.positive_float_from_env ~name:"CHESSMATE_HEALTH_TIMEOUT_SECONDS"
      ~default:5.0
  in
  let statuses = check_all ~timeout in
  Or_error.return (summarize statuses)

let report statuses = List.iter statuses ~f:print_status

let ensure_all () : unit Or_error.t =
  let* summary = check () in
  report summary.statuses;
  match summary.fatal with
  | Some { name; availability = Unavailable reason; _ } ->
      Or_error.errorf "%s unavailable: %s" name reason
  | Some { name; _ } -> Or_error.errorf "%s unavailable" name
  | None -> Or_error.return ()
