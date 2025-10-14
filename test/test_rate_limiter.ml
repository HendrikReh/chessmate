open! Base
open Alcotest
open Chessmate

let check_allowed () =
  let limiter = Rate_limiter.create ~tokens_per_minute:30 ~bucket_size:5 () in
  match Rate_limiter.check limiter ~remote_addr:"192.168.0.1" () with
  | Rate_limiter.Allowed { remaining } ->
      check bool "remaining non-negative" true Float.(remaining >= 0.)
  | Rate_limiter.Limited _ -> fail "expected request to be allowed"

let check_limited_and_metrics () =
  let limiter = Rate_limiter.create ~tokens_per_minute:60 ~bucket_size:1 () in
  (* First request consumes the only token. *)
  ignore (Rate_limiter.check limiter ~remote_addr:"10.0.0.5" ());
  (* Second request should be limited. *)
  (match Rate_limiter.check limiter ~remote_addr:"10.0.0.5" () with
  | Rate_limiter.Limited { retry_after; remaining } ->
      check bool "retry-after positive" true Float.(retry_after >= 0.);
      check bool "remaining non-negative" true Float.(remaining >= 0.)
  | Rate_limiter.Allowed _ -> fail "expected limiter to trigger");
  let metrics = Rate_limiter.metrics limiter in
  let total_line =
    List.find metrics ~f:(fun line ->
        String.is_prefix line ~prefix:"api_rate_limited_total ")
  in
  (match total_line with
  | Some line -> check string "total limited" "api_rate_limited_total 1" line
  | None -> fail "expected total metric line");
  let ip_line =
    List.find metrics ~f:(fun line ->
        String.is_substring line ~substring:"ip=\"10.0.0.5\"")
  in
  match ip_line with
  | Some line ->
      check bool "ip metric count" true (String.is_suffix line ~suffix:" 1")
  | None -> fail "expected per-ip metric line"

let prunes_idle_buckets () =
  let now = ref 0.0 in
  let time_source () = !now in
  let advance seconds = now := !now +. seconds in
  let limiter =
    Rate_limiter.create ~tokens_per_minute:10 ~bucket_size:1 ~idle_timeout:1.5
      ~prune_interval:0.5 ~time_source ()
  in
  ignore (Rate_limiter.check limiter ~remote_addr:"1.1.1.1" ());
  ignore (Rate_limiter.check limiter ~remote_addr:"2.2.2.2" ());
  check int "initial buckets tracked" 2
    (Rate_limiter.active_bucket_count limiter);
  advance 2.0;
  ignore (Rate_limiter.check limiter ~remote_addr:"3.3.3.3" ());
  check int "stale buckets pruned" 1 (Rate_limiter.active_bucket_count limiter);
  match Rate_limiter.check limiter ~remote_addr:"1.1.1.1" () with
  | Rate_limiter.Allowed _ -> ()
  | Rate_limiter.Limited _ -> fail "expected refreshed bucket after pruning"

let body_quota_enforced () =
  let limiter =
    Rate_limiter.create ~tokens_per_minute:100 ~bucket_size:100
      ~body_bytes_per_minute:1_000_000 ~body_bucket_size:1_000_000 ()
  in
  let () =
    match
      Rate_limiter.check limiter ~remote_addr:"8.8.8.8" ~body_bytes:600_000 ()
    with
    | Rate_limiter.Allowed _ -> ()
    | Rate_limiter.Limited _ -> fail "expected request under body quota"
  in
  match
    Rate_limiter.check limiter ~remote_addr:"8.8.8.8" ~body_bytes:600_000 ()
  with
  | Rate_limiter.Limited { retry_after; _ } ->
      check bool "retry-after positive" true Float.(retry_after > 0.);
      let metrics = Rate_limiter.metrics limiter in
      let body_metric_present =
        List.exists metrics ~f:(fun line ->
            String.is_prefix line ~prefix:"api_rate_limited_body_total 1")
      in
      check bool "body metric recorded" true body_metric_present
  | Rate_limiter.Allowed _ -> fail "expected body quota limiter to trigger"

let suite =
  [
    ("allows request under budget", `Quick, check_allowed);
    ("limits when tokens exhausted", `Quick, check_limited_and_metrics);
    ("prunes stale buckets", `Quick, prunes_idle_buckets);
    ("limits when body budget exceeded", `Quick, body_quota_enforced);
  ]
