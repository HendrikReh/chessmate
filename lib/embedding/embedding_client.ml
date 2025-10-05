open! Base

type t = {
  api_key : string;
  endpoint : string;
}

let create ~api_key ~endpoint =
  if String.is_empty api_key then Or_error.error_string "OPENAI_API_KEY missing"
  else if String.is_empty endpoint then Or_error.error_string "OpenAI endpoint missing"
  else Ok { api_key; endpoint }

let embed_fens t fens =
  let { api_key; endpoint } = t in
  ignore (api_key, endpoint, fens);
  Or_error.error_string "Embedding client not implemented yet"
