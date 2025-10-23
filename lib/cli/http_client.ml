open! Base

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
         (Printf.sprintf "request timed out after %.1fs when calling %s" timeout
            url))
  in
  try Lwt_main.run (Lwt.pick [ request; timeout_promise ])
  with exn -> Error (Exn.to_string exn)
