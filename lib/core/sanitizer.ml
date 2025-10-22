open! Base

let redaction = "[redacted]"

let sanitize_patterns =
  let patterns =
    [
      "sk-[A-Za-z0-9_-]{8,}";
      "gpt-[A-Za-z0-9_-]{8,}";
      "OPENAI_API_KEY=[^\\s]+";
      "DATABASE_URL=[^\\s]+";
      "postgres://[^\\s]+";
      "postgresql://[^\\s]+";
      "redis://[^\\s]+";
      "AGENT_API_KEY=[^\\s]+";
    ]
  in
  List.map patterns ~f:Re.Posix.compile_pat

let sanitize_string text =
  List.fold sanitize_patterns ~init:text ~f:(fun acc regex ->
      Re.replace ~all:true regex ~f:(fun _ -> redaction) acc)

let sanitize_error err = Error.to_string_hum err |> sanitize_string
