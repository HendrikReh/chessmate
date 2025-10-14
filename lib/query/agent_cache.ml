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

(** Cache GPT-5 agent evaluations behind in-memory LRU or Redis backends so
    repeat queries reuse previous scoring work. *)

let ( let* ) t f = Or_error.bind t ~f

module Evaluation = Agent_evaluator
module Effort = Agents_gpt5_client.Effort
module Usage = Agents_gpt5_client.Usage
module Util = Yojson.Safe.Util

module Key = struct
  type t = string

  let of_plan ~plan ~summary ~pgn =
    let digest_source =
      String.concat ~sep:"\n"
        [
          plan.Query_intent.cleaned_text;
          String.concat ~sep:"," plan.Query_intent.keywords;
          Int.to_string plan.Query_intent.limit;
          Option.value plan.Query_intent.rating.white_min ~default:(-1)
          |> Int.to_string;
          Option.value plan.Query_intent.rating.black_min ~default:(-1)
          |> Int.to_string;
          Option.value plan.Query_intent.rating.max_rating_delta ~default:(-1)
          |> Int.to_string;
          Option.value summary.Repo_postgres.opening_slug ~default:"";
          Option.value summary.Repo_postgres.result ~default:"";
          pgn;
        ]
    in
    Stdlib.Digest.string digest_source |> Stdlib.Digest.to_hex
end

type key = Key.t
type entry = Evaluation.evaluation

type memory_cache = {
  capacity : int;
  table : entry Hashtbl.M(String).t;
  order : key Queue.t;
}

type redis_cache = {
  host : string;
  port : int;
  password : string option;
  db : int option;
  namespace : string;
  ttl_seconds : int option;
}

type backend = Memory of memory_cache | Redis of redis_cache
type t = backend

let default_namespace = "chessmate:agent:"

let ensure_namespace namespace =
  let trimmed = String.strip namespace in
  if String.is_empty trimmed then default_namespace
  else if String.is_suffix trimmed ~suffix:":" then trimmed
  else trimmed ^ ":"

let sanitize_ttl = function Some ttl when ttl > 0 -> Some ttl | _ -> None

let create_memory_cache capacity =
  let capacity = Int.max 1 capacity in
  Memory
    {
      capacity;
      table = Hashtbl.create (module String);
      order = Queue.create ();
    }

let create ~capacity = create_memory_cache capacity

let parse_password userinfo =
  match String.lsplit2 userinfo ~on:':' with
  | None -> if String.is_empty userinfo then None else Some userinfo
  | Some (_, password) ->
      let password = String.strip password in
      if String.is_empty password then None else Some password

let parse_db path =
  let cleaned = String.strip path ~drop:(Char.equal '/') in
  if String.is_empty cleaned then None
  else
    match Int.of_string_opt cleaned with
    | Some db when db >= 0 -> Some db
    | _ ->
        eprintf
          "[agent-cache] ignoring redis database path %S (expected \
           non-negative integer)\n\
           %!"
          cleaned;
        None

let parse_redis_url ~namespace ~ttl_seconds url =
  match Or_error.try_with (fun () -> Uri.of_string url) with
  | Error err ->
      Or_error.errorf "invalid redis url %s (%s)" url (Error.to_string_hum err)
  | Ok uri -> (
      match Uri.scheme uri with
      | Some scheme when String.equal (String.lowercase scheme) "redis" -> (
          match Uri.host uri with
          | None -> Or_error.errorf "redis url %s missing host" url
          | Some host ->
              let port = Option.value (Uri.port uri) ~default:6379 in
              let password = Option.bind (Uri.userinfo uri) ~f:parse_password in
              let db = parse_db (Uri.path uri) in
              Or_error.return
                {
                  host;
                  port;
                  password;
                  db;
                  namespace = ensure_namespace namespace;
                  ttl_seconds = sanitize_ttl ttl_seconds;
                })
      | Some other ->
          Or_error.errorf "redis url %s must use redis:// scheme (got %s)" url
            other
      | None -> Or_error.errorf "redis url %s missing scheme" url)

let create_redis ?namespace ?ttl_seconds url =
  let namespace_value = Option.value namespace ~default:default_namespace in
  let ttl_value = ttl_seconds in
  parse_redis_url ~namespace:namespace_value ~ttl_seconds:ttl_value url
  |> Or_error.map ~f:(fun config -> Redis config)

let namespace_key cache key = cache.namespace ^ key

let encode_resp parts =
  let header = Printf.sprintf "*%d\r\n" (List.length parts) in
  let body =
    parts
    |> List.map ~f:(fun part ->
           Printf.sprintf "$%d\r\n%s\r\n" (String.length part) part)
    |> String.concat ~sep:""
  in
  header ^ body

type reply =
  | Simple of string
  | Error_reply of string
  | Integer of int
  | Bulk of string option
  | Array of reply list

let rec read_reply ic =
  match In_channel.input_char ic with
  | None -> Or_error.error_string "redis: unexpected EOF"
  | Some '+' -> (
      match In_channel.input_line ic with
      | Some line -> Or_error.return (Simple line)
      | None -> Or_error.error_string "redis: unexpected EOF (simple string)")
  | Some '-' -> (
      match In_channel.input_line ic with
      | Some line -> Or_error.return (Error_reply line)
      | None -> Or_error.error_string "redis: unexpected EOF (error string)")
  | Some ':' -> (
      match In_channel.input_line ic with
      | Some line -> (
          match Int.of_string_opt line with
          | Some value -> Or_error.return (Integer value)
          | None -> Or_error.errorf "redis: invalid integer response %S" line)
      | None -> Or_error.error_string "redis: unexpected EOF (integer)")
  | Some '$' -> (
      match In_channel.input_line ic with
      | Some "-1" -> Or_error.return (Bulk None)
      | Some len_text -> (
          match Int.of_string_opt len_text with
          | None -> Or_error.errorf "redis: invalid bulk length %S" len_text
          | Some len ->
              let buffer = Bytes.create len in
              In_channel.really_input_exn ic ~buf:buffer ~pos:0 ~len;
              (* consume CRLF *)
              ignore (In_channel.input_char ic);
              ignore (In_channel.input_char ic);
              Or_error.return (Bulk (Some (Bytes.to_string buffer))))
      | None -> Or_error.error_string "redis: unexpected EOF (bulk length)")
  | Some '*' -> (
      match In_channel.input_line ic with
      | Some len_text -> (
          match Int.of_string_opt len_text with
          | Some -1 -> Or_error.return (Array [])
          | Some len ->
              let rec gather acc remaining =
                if remaining = 0 then Or_error.return (Array (List.rev acc))
                else
                  let* reply = read_reply ic in
                  gather (reply :: acc) (remaining - 1)
              in
              gather [] len
          | None -> Or_error.errorf "redis: invalid array length %S" len_text)
      | None -> Or_error.error_string "redis: unexpected EOF (array length)")
  | Some prefix -> Or_error.errorf "redis: unexpected prefix %C" prefix

let send_command ic oc parts =
  Out_channel.output_string oc (encode_resp parts);
  Out_channel.flush oc;
  read_reply ic

let handshake cache ic oc =
  let* () =
    match cache.password with
    | None -> Or_error.return ()
    | Some password -> (
        let* reply = send_command ic oc [ "AUTH"; password ] in
        match reply with
        | Simple "OK" -> Or_error.return ()
        | Error_reply msg -> Or_error.errorf "redis AUTH failed: %s" msg
        | _ -> Or_error.error_string "redis AUTH returned unexpected reply")
  in
  match cache.db with
  | None -> Or_error.return ()
  | Some db -> (
      let* reply = send_command ic oc [ "SELECT"; Int.to_string db ] in
      match reply with
      | Simple "OK" -> Or_error.return ()
      | Error_reply msg -> Or_error.errorf "redis SELECT failed: %s" msg
      | _ -> Or_error.error_string "redis SELECT returned unexpected reply")

let with_connection cache ~f =
  let addr_result =
    Or_error.try_with (fun () ->
        Unix.getaddrinfo cache.host (Int.to_string cache.port)
          [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ])
  in
  let* addr_info =
    addr_result
    |> Or_error.bind ~f:(function
         | [] ->
             Or_error.errorf "redis host %s could not be resolved" cache.host
         | info :: _ -> Or_error.return info)
  in
  let socket =
    Unix.socket addr_info.Unix.ai_family addr_info.Unix.ai_socktype
      addr_info.Unix.ai_protocol
  in
  match
    Or_error.try_with (fun () -> Unix.connect socket addr_info.Unix.ai_addr)
  with
  | Error err ->
      (try Unix.close socket with _ -> ());
      Error err
  | Ok () ->
      let fd_in = Unix.dup socket in
      let ic = Unix.in_channel_of_descr fd_in in
      let oc = Unix.out_channel_of_descr socket in
      Exn.protect
        ~f:(fun () ->
          let run () =
            let* () = handshake cache ic oc in
            f ic oc
          in
          run ())
        ~finally:(fun () ->
          In_channel.close ic;
          Out_channel.close oc;
          try Unix.close socket with _ -> ())

let ping cache =
  match cache with
  | Memory _ -> Or_error.return ()
  | Redis redis -> (
      match
        with_connection redis ~f:(fun ic oc ->
            let* reply = send_command ic oc [ "PING" ] in
            match reply with
            | Simple "PONG" -> Or_error.return ()
            | Integer _ -> Or_error.return ()
            | Bulk (Some _) -> Or_error.return ()
            | _ -> Or_error.error_string "redis PING returned unexpected reply")
      with
      | Ok () -> Or_error.return ()
      | Error err -> Error err)

let usage_to_json = function
  | None -> `Null
  | Some usage ->
      let fields =
        [
          ("input_tokens", usage.Usage.input_tokens);
          ("output_tokens", usage.Usage.output_tokens);
          ("reasoning_tokens", usage.Usage.reasoning_tokens);
        ]
      in
      `Assoc
        (fields
        |> List.filter_map ~f:(fun (label, value) ->
               Option.map value ~f:(fun v -> (label, `Int v))))

let usage_of_json json =
  match json with
  | `Null -> None
  | _ ->
      let parse field =
        match Util.member field json with
        | `Null -> None
        | value -> Util.to_int_option value
      in
      let input_tokens = parse "input_tokens" in
      let output_tokens = parse "output_tokens" in
      let reasoning_tokens = parse "reasoning_tokens" in
      if
        Option.is_none input_tokens
        && Option.is_none output_tokens
        && Option.is_none reasoning_tokens
      then None
      else Some { Usage.input_tokens; output_tokens; reasoning_tokens }

let entry_to_json (entry : entry) =
  `Assoc
    [
      ("game_id", `Int entry.game_id);
      ("score", `Float entry.score);
      (match entry.explanation with
      | None -> ("explanation", `Null)
      | Some text -> ("explanation", `String text));
      ("themes", `List (List.map entry.themes ~f:(fun theme -> `String theme)));
      ("reasoning_effort", `String (Effort.to_string entry.reasoning_effort));
      ("usage", usage_to_json entry.usage);
    ]

let entry_of_json json =
  let game_id = Util.member "game_id" json |> Util.to_int_option in
  let score = Util.member "score" json |> Util.to_float_option in
  match (game_id, score) with
  | Some game_id, Some score ->
      let explanation =
        Util.member "explanation" json |> Util.to_string_option
      in
      let themes =
        match Util.member "themes" json with
        | `Null -> []
        | value ->
            value |> Util.to_list |> List.filter_map ~f:Util.to_string_option
      in
      let effort =
        match Util.member "reasoning_effort" json |> Util.to_string_option with
        | None -> Effort.Medium
        | Some value -> (
            match Effort.of_string value with
            | Ok effort -> effort
            | Error _ -> Effort.Medium)
      in
      let usage = usage_of_json (Util.member "usage" json) in
      Or_error.return
        {
          Evaluation.game_id;
          score;
          explanation;
          themes;
          reasoning_effort = effort;
          usage;
        }
  | _ -> Or_error.error_string "cached entry missing required fields"

let entry_of_string raw =
  match Or_error.try_with (fun () -> Yojson.Safe.from_string raw) with
  | Error err ->
      Or_error.errorf "failed to parse cached agent evaluation: %s"
        (Error.to_string_hum err)
  | Ok json -> entry_of_json json

let entry_to_string entry = Yojson.Safe.to_string (entry_to_json entry)

let log_redis_failure action key err =
  eprintf "[agent-cache] redis %s for key %s failed: %s\n%!" action key
    (Error.to_string_hum err)

let redis_find cache key =
  let namespaced = namespace_key cache key in
  match
    with_connection cache ~f:(fun ic oc ->
        let* reply = send_command ic oc [ "GET"; namespaced ] in
        match reply with
        | Bulk None -> Or_error.return None
        | Bulk (Some raw) -> Or_error.return (Some raw)
        | Simple "nil" -> Or_error.return None
        | Simple raw -> Or_error.return (Some raw)
        | Error_reply msg -> Or_error.error_string msg
        | _ -> Or_error.error_string "redis GET returned unexpected reply")
  with
  | Ok None -> None
  | Ok (Some raw) -> (
      match entry_of_string raw with
      | Ok entry -> Some entry
      | Error err ->
          log_redis_failure "decode" key err;
          None)
  | Error err ->
      log_redis_failure "get" key err;
      None

let redis_store cache key entry =
  let namespaced = namespace_key cache key in
  let value = entry_to_string entry in
  let command =
    match cache.ttl_seconds with
    | Some ttl -> [ "SET"; namespaced; value; "EX"; Int.to_string ttl ]
    | None -> [ "SET"; namespaced; value ]
  in
  match
    with_connection cache ~f:(fun ic oc ->
        let* reply = send_command ic oc command in
        match reply with
        | Simple "OK" -> Or_error.return ()
        | Error_reply msg -> Or_error.error_string msg
        | _ -> Or_error.error_string "redis SET returned unexpected reply")
  with
  | Ok () -> ()
  | Error err -> log_redis_failure "set" key err

let memory_find cache key = Hashtbl.find cache.table key

let memory_store cache key value =
  if not (Hashtbl.mem cache.table key) then Queue.enqueue cache.order key;
  Hashtbl.set cache.table ~key ~data:value;
  let rec evict () =
    if Hashtbl.length cache.table <= cache.capacity then ()
    else
      match Queue.dequeue cache.order with
      | None -> ()
      | Some old_key ->
          Hashtbl.remove cache.table old_key;
          evict ()
  in
  evict ()

let find cache key =
  match cache with
  | Memory memory -> memory_find memory key
  | Redis redis -> redis_find redis key

let store cache key entry =
  match cache with
  | Memory memory -> memory_store memory key entry
  | Redis redis -> redis_store redis key entry

let key_of_plan = Key.of_plan
