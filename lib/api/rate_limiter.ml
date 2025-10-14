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

type bucket = {
  mutable tokens : float;
  mutable last_refill : float;
  mutable last_seen : float;
  mutable limited_count : int;
  mutable body_tokens : float;
  mutable body_limited_count : int;
}

type t = {
  buckets : (string, bucket) Hashtbl.t;
  mutex : Stdlib.Mutex.t;
  tokens_per_second : float;
  bucket_size : float;
  total_limited : int ref;
  body_tokens_per_second : float option;
  body_bucket_size : float option;
  total_body_limited : int ref;
  idle_timeout : float;
  prune_interval : float;
  mutable last_prune : float;
  now : unit -> float;
}

type decision =
  | Allowed of { remaining : float }
  | Limited of { retry_after : float; remaining : float }

let with_lock t f =
  Stdlib.Mutex.lock t.mutex;
  match f () with
  | result ->
      Stdlib.Mutex.unlock t.mutex;
      result
  | exception ex ->
      Stdlib.Mutex.unlock t.mutex;
      raise ex

let sanitize_identifier value =
  String.map value ~f:(fun ch ->
      if
        Char.is_alphanum ch || Char.equal ch '.' || Char.equal ch ':'
        || Char.equal ch '_'
      then ch
      else '_')

let normalize_remote_addr addr =
  let cleaned = String.strip addr in
  if String.is_empty cleaned then "unknown" else String.lowercase cleaned

let validate_positive name value =
  if Float.(value <= 0.) then
    invalid_arg (Printf.sprintf "Rate_limiter.create: %s must be positive" name)

let create ?idle_timeout ?prune_interval ?time_source ?body_bytes_per_minute
    ?body_bucket_size ~tokens_per_minute ~bucket_size () =
  if tokens_per_minute <= 0 then
    invalid_arg "Rate_limiter.create: tokens_per_minute must be positive";
  if bucket_size <= 0 then
    invalid_arg "Rate_limiter.create: bucket_size must be positive";
  let idle_timeout = Option.value idle_timeout ~default:600. in
  let prune_interval = Option.value prune_interval ~default:60. in
  let time_source = Option.value time_source ~default:Unix.gettimeofday in
  validate_positive "idle_timeout" idle_timeout;
  validate_positive "prune_interval" prune_interval;
  let tokens_per_second = Float.of_int tokens_per_minute /. 60.0 in
  let body_tokens_per_second, body_bucket_size =
    match body_bytes_per_minute with
    | None ->
        if Option.is_some body_bucket_size then
          invalid_arg
            "Rate_limiter.create: body_bucket_size requires \
             body_bytes_per_minute";
        (None, None)
    | Some bytes_per_minute ->
        if bytes_per_minute <= 0 then
          invalid_arg
            "Rate_limiter.create: body_bytes_per_minute must be positive";
        let bucket_float =
          match body_bucket_size with
          | None -> Float.of_int bytes_per_minute
          | Some burst when burst > 0 -> Float.of_int burst
          | Some _ ->
              invalid_arg
                "Rate_limiter.create: body_bucket_size must be positive"
        in
        let per_second = Float.of_int bytes_per_minute /. 60.0 in
        (Some per_second, Some bucket_float)
  in
  let initial_now = time_source () in
  {
    buckets = Hashtbl.create (module String);
    mutex = Stdlib.Mutex.create ();
    tokens_per_second;
    bucket_size = Float.of_int bucket_size;
    total_limited = ref 0;
    body_tokens_per_second;
    body_bucket_size;
    total_body_limited = ref 0;
    idle_timeout;
    prune_interval;
    last_prune = initial_now;
    now = time_source;
  }

let refill_bucket t bucket now =
  let elapsed = now -. bucket.last_refill in
  if Float.(elapsed > 0.) then (
    let added = elapsed *. t.tokens_per_second in
    bucket.tokens <- Float.min t.bucket_size (bucket.tokens +. added);
    (match (t.body_tokens_per_second, t.body_bucket_size) with
    | Some body_per_second, Some body_bucket_size ->
        let added_body = elapsed *. body_per_second in
        bucket.body_tokens <-
          Float.min body_bucket_size (bucket.body_tokens +. added_body)
    | _ -> ());
    bucket.last_refill <- now)

let prune_if_needed t now =
  if Float.(now -. t.last_prune >= t.prune_interval) then (
    t.last_prune <- now;
    let stale_keys =
      Hashtbl.fold t.buckets ~init:[] ~f:(fun ~key ~data:bucket acc ->
          if Float.(now -. bucket.last_seen >= t.idle_timeout) then key :: acc
          else acc)
    in
    List.iter stale_keys ~f:(fun key -> Hashtbl.remove t.buckets key))

let ensure_bucket t ip now =
  Hashtbl.find_or_add t.buckets ip ~default:(fun () ->
      {
        tokens = t.bucket_size;
        last_refill = now;
        last_seen = now;
        limited_count = 0;
        body_tokens = Option.value t.body_bucket_size ~default:0.;
        body_limited_count = 0;
      })

let check t ~remote_addr ?body_bytes () =
  let key = remote_addr |> normalize_remote_addr |> sanitize_identifier in
  let now = t.now () in
  with_lock t (fun () ->
      prune_if_needed t now;
      let bucket = ensure_bucket t key now in
      refill_bucket t bucket now;
      bucket.last_seen <- now;
      let body_cost =
        match (body_bytes, t.body_tokens_per_second) with
        | Some bytes, Some _ when bytes > 0 -> Some (Float.of_int bytes)
        | Some _, Some _ -> Some 0.
        | _ -> None
      in
      let has_request_token = Float.(bucket.tokens >= 1.) in
      let has_body_tokens =
        match body_cost with
        | None -> true
        | Some cost -> Float.(bucket.body_tokens >= cost)
      in
      if has_request_token && has_body_tokens then (
        bucket.tokens <- bucket.tokens -. 1.;
        (match body_cost with
        | Some cost when Float.(cost > 0.) ->
            bucket.body_tokens <- Float.max 0. (bucket.body_tokens -. cost)
        | _ -> ());
        Allowed { remaining = bucket.tokens })
      else
        let request_retry_after =
          if has_request_token then None
          else
            let deficit = 1.0 -. bucket.tokens in
            let retry_after =
              if Float.(t.tokens_per_second = 0.) then Float.infinity
              else deficit /. t.tokens_per_second
            in
            Some retry_after
        in
        let body_retry_after =
          match (body_cost, t.body_tokens_per_second) with
          | Some cost, Some per_second when Float.(bucket.body_tokens < cost) ->
              let deficit = cost -. bucket.body_tokens in
              let retry_after =
                if Float.(per_second = 0.) then Float.infinity
                else deficit /. per_second
              in
              Some retry_after
          | _ -> None
        in
        bucket.limited_count <- bucket.limited_count + 1;
        t.total_limited := !(t.total_limited) + 1;
        (match body_retry_after with
        | Some _ ->
            bucket.body_limited_count <- bucket.body_limited_count + 1;
            t.total_body_limited := !(t.total_body_limited) + 1
        | None -> ());
        let retry_after =
          match (request_retry_after, body_retry_after) with
          | None, None -> 0.
          | Some value, None -> value
          | None, Some value -> value
          | Some r1, Some r2 -> Float.max r1 r2
        in
        Limited { retry_after; remaining = bucket.tokens })

let metrics t =
  let now = t.now () in
  with_lock t (fun () ->
      prune_if_needed t now;
      let per_ip_lines =
        Hashtbl.fold t.buckets ~init:[] ~f:(fun ~key ~data acc ->
            if data.limited_count = 0 then acc
            else
              let line =
                Printf.sprintf "api_rate_limited_total{ip=\"%s\"} %d" key
                  data.limited_count
              in
              line :: acc)
      in
      let per_ip_lines = List.sort per_ip_lines ~compare:String.compare in
      let body_lines =
        match t.body_tokens_per_second with
        | None -> []
        | Some _ ->
            let per_ip_body =
              Hashtbl.fold t.buckets ~init:[] ~f:(fun ~key ~data acc ->
                  if data.body_limited_count = 0 then acc
                  else
                    let line =
                      Printf.sprintf "api_rate_limited_body_total{ip=\"%s\"} %d"
                        key data.body_limited_count
                    in
                    line :: acc)
            in
            let per_ip_body = List.sort per_ip_body ~compare:String.compare in
            let total_body_line =
              Printf.sprintf "api_rate_limited_body_total %d"
                !(t.total_body_limited)
            in
            total_body_line :: per_ip_body
      in
      let total_line =
        Printf.sprintf "api_rate_limited_total %d" !(t.total_limited)
      in
      (total_line :: per_ip_lines) @ body_lines)

let active_bucket_count t =
  let now = t.now () in
  with_lock t (fun () ->
      prune_if_needed t now;
      Hashtbl.length t.buckets)
