open! Base
open Alcotest
open Chessmate
open Chessmate.Worker_health_server

let rec start_server ~summary ~metrics attempt =
  if attempt > 20 then
    Error (Error.of_string "unable to find free port for worker health server")
  else
    let port = 20080 + attempt in
    match start ~port ~summary ~metrics with
    | Ok stop -> Ok (port, stop)
    | Error _ -> start_server ~summary ~metrics (attempt + 1)

let http_get_body ~port path =
  let addr = Unix.ADDR_INET (Unix.inet_addr_loopback, port) in
  let in_chan, out_chan = Unix.open_connection addr in
  let request =
    Printf.sprintf
      "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" path
  in
  Stdlib.output_string out_chan request;
  Stdlib.flush out_chan;
  let response = In_channel.input_all in_chan in
  Stdlib.close_out_noerr out_chan;
  Stdlib.close_in_noerr in_chan;
  match String.substr_index response ~pattern:"\r\n\r\n" with
  | Some idx -> String.drop_prefix response (idx + 4)
  | None -> (
      match String.substr_index response ~pattern:"\n\n" with
      | Some idx -> String.drop_prefix response (idx + 2)
      | None -> response)

let test_endpoints () =
  let summary_fn () = { Health.status = `Ok; checks = [] } in
  let metrics_fn () =
    Ok
      Metrics.
        {
          processed = 7;
          failed = 1;
          jobs_per_min = 12.5;
          chars_per_sec = 3456.0;
          queue_depth = 3;
        }
  in
  match start_server ~summary:summary_fn ~metrics:metrics_fn 0 with
  | Error err ->
      Stdio.eprintf "[worker-health-test] skipping: %s\n%!"
        (Error.to_string_hum err);
      Alcotest.skip ()
  | Ok (port, stop) -> (
      try
        Unix.sleepf 0.1;
        let metrics_body = http_get_body ~port "/metrics" in
        check bool "metrics expose processed" true
          (String.is_substring metrics_body
             ~substring:"embedding_worker_processed_total 7");
        check bool "metrics expose queue depth" true
          (String.is_substring metrics_body
             ~substring:"embedding_worker_queue_depth 3");
        let health_body = http_get_body ~port "/health" in
        check bool "health responds with JSON" true
          (String.is_substring health_body ~substring:"\"status\":\"ok\"");
        stop ()
      with Unix.Unix_error (Unix.EPERM, _, _) ->
        stop ();
        Stdio.eprintf
          "[worker-health-test] skipping due to sandbox restrictions\n%!";
        Alcotest.skip ())

let suite = [ ("serves health and metrics", `Quick, test_endpoints) ]
