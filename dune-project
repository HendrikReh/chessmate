(lang dune 3.20)

(name chessmate)

(generate_opam_files true)

(source
 (github HendrikReh/chessmate))

(authors "Hendrik Reh <blacksmith-consulting.ai>")

(maintainers "Hendrik Reh <blacksmith-consulting.ai>")

(license LICENSE)

(documentation https://github.com/HendrikReh/chessmate)

(package
 (name chessmate)
 (synopsis "A short synopsis")
 (description "Hybrid chess tutor combining Postgres metadata with Qdrant vector search and OCaml-powered ingestion/query services.")
 (depends
  ocaml
  base
  stdio
  (alcotest :with-test))
 (tags
  ("chess" "ocaml" "vector-search" "postgres" "qdrant")))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
