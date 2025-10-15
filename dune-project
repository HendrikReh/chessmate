(lang dune 3.20)

(name chessmate)

(generate_opam_files true)

(source
 (github HendrikReh/chessmate))

(authors "Hendrik Reh <hendrik.reh@blacksmith-consulting.ai>")

(maintainers "Hendrik Reh <hendrik.reh@blacksmith-consulting.ai>")

(license "GPL-3.0-or-later")

(documentation https://github.com/HendrikReh/chessmate)

(package
 (name chessmate)
(version "0.7.0")
 (synopsis "Self-hosted chess tutor with hybrid retrieval combining Postgres, Qdrant vector search, and OCaml services")
 (description "Hybrid chess tutor combining Postgres metadata with Qdrant vector search and OCaml-powered ingestion/query services.")
 (depends
  ocaml
  base
  stdio
  yojson
 uri
 lwt
 cohttp-lwt-unix
 prometheus
 prometheus-app
 opium
 caqti
 caqti-driver-postgresql
 (alcotest :with-test))
 (tags
  ("chess" "ocaml" "vector-search" "postgres" "qdrant")))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
