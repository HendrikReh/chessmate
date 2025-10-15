# Profiling Notes

Performance snapshots for recent tuning efforts. Record the workload, tooling, and deltas so future regressions are easy to spot.

---

## GH-040 – Hybrid Executor Hotspots

- **Date**: 2025-10-15
- **Objective**: Validate the single-pass tokenizer and cached `rating_matches` predicate introduced in `lib/query/hybrid_executor.ml`.
- **Workload**: Canonical WCC summary (players, event, ECO slug) repeated over 200 000 iterations — representative of the top-N game scoring hot path.

### Results

| Implementation | Duration (200k iters) | Notes |
| --- | --- | --- |
| Legacy multi-pass tokenizer | 1.830 s | Lowercase → map → split → filter (pre-change behaviour) |
| Single-pass tokenizer | 1.585 s | Shared buffer, single traversal, fewer allocations |

The buffer-based implementation delivers a **13.4 % speed-up** for keyword tokenization, which dominates scoring time when vector hits are absent. Instrumentation also confirmed that `rating_matches` is now evaluated once per candidate, removing redundant option-pattern work in fallback scoring paths.

### Reproduction

```sh
eval "$(opam env --set-switch)"
ocaml <<'EOF'
#load "unix.cma";;
let is_alphanum c =
  (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');;

let old_tokenize text =
  let lower = String.lowercase_ascii text in
  let sanitized = String.map (fun ch -> if is_alphanum ch then ch else ' ') lower in
  let parts = String.split_on_char ' ' sanitized in
  List.filter (fun token -> String.length token >= 3) parts;;

let old_summary_keyword_tokens sources =
  let tokens = List.concat_map old_tokenize sources in
  List.sort_uniq String.compare tokens;;

let new_tokenize_sources sources =
  let buffer = Buffer.create 32 in
  let flush acc =
    if Buffer.length buffer >= 3 then (
      let token = Buffer.contents buffer in
      Buffer.clear buffer;
      token :: acc)
    else (
      Buffer.clear buffer;
      acc)
  in
  let push_char acc ch =
    let lower = Char.lowercase_ascii ch in
    if is_alphanum lower then (
      Buffer.add_char buffer lower;
      acc)
    else flush acc
  in
  let rec process acc = function
    | [] -> flush acc
    | source :: rest ->
        let acc = String.fold_left push_char acc source in
        let acc = flush acc in
        process acc rest
  in
  List.sort_uniq String.compare (process [] sources);;

let sources =
  [
    "Magnus Carlsen";
    "Viswanathan Anand";
    "World Championship";
    "King's Indian Defense";
    "kings_indian_defense";
    "Oslo 2014";
  ];;

let iterations = 200_000;;

let time label f =
  let start = Unix.gettimeofday () in
  let total = f () in
  let finish = Unix.gettimeofday () in
  Printf.printf "%s\t%.6fs\t(acc=%d)\n" label (finish -. start) total;;

let () =
  time "legacy" (fun () ->
      let rec loop i acc =
        if i = iterations then acc
        else
          let tokens = old_summary_keyword_tokens sources in
          loop (i + 1) (acc + List.length tokens)
      in
      loop 0 0);
  time "single_pass" (fun () ->
      let rec loop i acc =
        if i = iterations then acc
        else
          let tokens = new_tokenize_sources sources in
          loop (i + 1) (acc + List.length tokens)
      in
      loop 0 0);;
EOF
```

Sample output:

```
legacy      1.830547s  (acc=2400000)
single_pass 1.584699s  (acc=2400000)
```

