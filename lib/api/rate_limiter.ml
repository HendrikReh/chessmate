open! Base

type bucket = {
  mutable tokens : float;
  mutable last_refill : float;
  mutable last_seen : float;
  mutable limited_count : int;
}

type t = {
  buckets : (string, bucket) Hashtbl.t;
  mutex : Stdlib.Mutex.t;
  tokens_per_second : float;
  bucket_size : float;
  total_limited : int ref;
  idle_timeout : float;
  prune_interval : float;
  mutable last_prune : float;
  now : unit -> float;
}

type decision =
  | Allowed of { remaining : float }
  | Limited of { retry_after : float; remaining : float }

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

let create ?idle_timeout ?prune_interval ?time_source ~tokens_per_minute
    ~bucket_size () =
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
  let initial_now = time_source () in
  {
    buckets = Hashtbl.create (module String);
    mutex = Stdlib.Mutex.create ();
    tokens_per_second;
    bucket_size = Float.of_int bucket_size;
    total_limited = ref 0;
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
    bucket.last_refill <- now)

let prune_if_needed t now =
  if Float.(now -. t.last_prune >= t.prune_interval) then (
    t.last_prune <- now;
    Hashtbl.filteri_inplace t.buckets ~f:(fun ~key:_ ~data:bucket ->
        Float.(now -. bucket.last_seen < t.idle_timeout)))

let ensure_bucket t ip now =
  Hashtbl.find_or_add t.buckets ip ~default:(fun () ->
      {
        tokens = t.bucket_size;
        last_refill = now;
        last_seen = now;
        limited_count = 0;
      })

let check t ~remote_addr =
  let key = remote_addr |> normalize_remote_addr |> sanitize_identifier in
  let now = t.now () in
  Stdlib.Mutex.lock t.mutex;
  prune_if_needed t now;
  let bucket = ensure_bucket t key now in
  refill_bucket t bucket now;
  bucket.last_seen <- now;
  let decision =
    if Float.(bucket.tokens >= 1.) then (
      bucket.tokens <- bucket.tokens -. 1.;
      Allowed { remaining = bucket.tokens })
    else
      let deficit = 1.0 -. bucket.tokens in
      let retry_after =
        if Float.(t.tokens_per_second = 0.) then Float.infinity
        else deficit /. t.tokens_per_second
      in
      bucket.limited_count <- bucket.limited_count + 1;
      t.total_limited := !(t.total_limited) + 1;
      Limited { retry_after; remaining = bucket.tokens }
  in
  Stdlib.Mutex.unlock t.mutex;
  decision

let metrics t =
  let now = t.now () in
  Stdlib.Mutex.lock t.mutex;
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
  let total_line =
    Printf.sprintf "api_rate_limited_total %d" !(t.total_limited)
  in
  Stdlib.Mutex.unlock t.mutex;
  total_line :: per_ip_lines

let active_bucket_count t =
  let now = t.now () in
  Stdlib.Mutex.lock t.mutex;
  prune_if_needed t now;
  let count = Hashtbl.length t.buckets in
  Stdlib.Mutex.unlock t.mutex;
  count
