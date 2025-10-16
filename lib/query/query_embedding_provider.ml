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
module Helpers = Config.Helpers

type source = Embedding_service | Deterministic_fallback

type fetch_result = {
  vector : float list;
  source : source;
  warnings : string list;
}

type backend =
  | Disabled of { reason : string }
  | Enabled of { embed : string -> float array list Or_error.t }

type t = { backend : backend }

let default_endpoint = "https://api.openai.com/v1/embeddings"
let fallback_dimension = 1536
let clamp_float value ~min ~max = Float.min max (Float.max min value)

let hash_component token index =
  let hashed = Hashtbl.hash (token, index) |> Int.abs in
  let bucket = Int.rem hashed 10_000 in
  Float.of_int bucket /. 10_000.0

let deterministic_vector plan =
  let tokens =
    if List.is_empty plan.Query_intent.keywords then [ plan.cleaned_text ]
    else plan.Query_intent.keywords
  in
  List.init fallback_dimension ~f:(fun index ->
      match tokens with
      | [] -> 0.0
      | _ ->
          let total =
            List.fold tokens ~init:0.0 ~f:(fun acc token ->
                acc +. hash_component token index)
          in
          clamp_float
            (total /. Float.of_int (List.length tokens))
            ~min:0.0 ~max:1.0)

let sanitize reason = Sanitizer.sanitize_string reason
let disabled reason = { backend = Disabled { reason } }
let enabled embed = { backend = Enabled { embed } }

let query_text plan =
  let keyword_section =
    if List.is_empty plan.Query_intent.keywords then ""
    else String.concat ~sep:" " plan.Query_intent.keywords
  in
  let parts =
    [ plan.cleaned_text; keyword_section ]
    |> List.filter ~f:(fun part -> not (String.is_empty (String.strip part)))
  in
  String.concat ~sep:" " parts

let fallback_result plan ~reason =
  let message =
    if String.is_empty reason then "unknown reason" else sanitize reason
  in
  {
    vector = deterministic_vector plan;
    source = Deterministic_fallback;
    warnings = [ Printf.sprintf "Query embeddings fallback (%s)" message ];
  }

let fetch t plan =
  match t.backend with
  | Disabled { reason } -> fallback_result plan ~reason
  | Enabled { embed } -> (
      let text = query_text plan in
      match embed text with
      | Error err -> fallback_result plan ~reason:(Error.to_string_hum err)
      | Ok [] ->
          fallback_result plan ~reason:"embedding service returned no vectors"
      | Ok (vector :: _) ->
          let vector = Array.to_list vector in
          { vector; source = Embedding_service; warnings = [] })

let provider_ref : t option ref = ref None

let resolved_endpoint () =
  Helpers.optional "QUERY_EMBEDDING_ENDPOINT"
  |> Option.value
       ~default:
         (Option.value
            (Helpers.optional "OPENAI_EMBEDDING_ENDPOINT")
            ~default:default_endpoint)

let resolved_api_key () =
  match Helpers.optional "QUERY_EMBEDDING_API_KEY" with
  | Some key -> Some key
  | None -> Helpers.optional "OPENAI_API_KEY"

let initialise () =
  match resolved_api_key () with
  | None ->
      disabled
        "missing QUERY_EMBEDDING_API_KEY or OPENAI_API_KEY for query embeddings"
  | Some api_key -> (
      let endpoint = resolved_endpoint () in
      match Embedding_client.create ~api_key ~endpoint with
      | Error err -> disabled (Error.to_string_hum err)
      | Ok client ->
          let embed text = Embedding_client.embed_fens client [ text ] in
          enabled embed)

let current () =
  match !provider_ref with
  | Some provider -> provider
  | None ->
      let provider = initialise () in
      provider_ref := Some provider;
      provider

let reset () = provider_ref := None

module For_tests = struct
  let make_disabled ~reason = disabled reason
  let make_enabled ~embed = enabled embed

  let with_provider provider f =
    let previous = !provider_ref in
    provider_ref := Some provider;
    Exn.protect ~f ~finally:(fun () -> provider_ref := previous)
end
