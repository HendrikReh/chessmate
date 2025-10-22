open! Base
open Alcotest
open Chessmate
open Opium_kernel

let make_rate_limited_app limiter =
  let limiter_middleware =
    Rock.Middleware.create ~name:"test-rate-limiter" ~filter:(fun handler req ->
        match Rate_limiter.check limiter ~remote_addr:"127.0.0.1" () with
        | Rate_limiter.Allowed _ -> handler req
        | Rate_limiter.Limited { retry_after; _ } ->
            let retry_after_seconds =
              retry_after |> Float.max 0. |> Float.round_up |> Int.of_float
            in
            let headers =
              Cohttp.Header.init () |> fun h ->
              Cohttp.Header.add h "Retry-After"
                (Int.to_string retry_after_seconds)
            in
            Opium.App.respond' ~code:`Too_many_requests ~headers
              (`String "rate limited"))
  in
  Opium.App.empty
  |> Opium.App.get "/ping" (fun _ -> Opium.App.respond' (`String "pong"))
  |> Opium.App.middleware limiter_middleware

let run_request handler =
  let open Cohttp in
  let uri = Uri.of_string "/ping" in
  let headers = Header.init_with "x-forwarded-for" "127.0.0.1" in
  let cohttp_req = Request.make ~meth:`GET ~headers uri in
  let rock_req =
    Opium_kernel.Rock.Request.create cohttp_req ~body:Cohttp_lwt.Body.empty
  in
  Lwt_main.run (handler rock_req)

let test_http_rate_limiting () =
  let limiter = Rate_limiter.create ~tokens_per_minute:1 ~bucket_size:1 () in
  let rock_app = Opium.App.to_rock (make_rate_limited_app limiter) in
  let handler = Rock.App.handler rock_app in
  let middlewares =
    Rock.App.middlewares rock_app |> List.map ~f:Rock.Middleware.filter
  in
  let handler = Rock.Filter.apply_all middlewares handler in
  let first = run_request handler in
  check int "200 OK" 200 (Cohttp.Code.code_of_status first.code);
  let second = run_request handler in
  check int "429 Too Many Requests" 429 (Cohttp.Code.code_of_status second.code);
  let retry_after =
    Cohttp.Header.get second.headers "Retry-After" |> Option.value ~default:"0"
  in
  check bool "retry-after positive" true (Int.of_string retry_after >= 1)

let suite =
  [
    ( "rate limiter rejects second burst request",
      `Quick,
      test_http_rate_limiting );
  ]
