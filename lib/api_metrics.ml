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

type sample_buffer = {
  data : float array;
  mutable next : int;
  mutable length : int;
}

let buffer_capacity = 512

let create_buffer () =
  { data = Array.create ~len:buffer_capacity 0.0; next = 0; length = 0 }

let add_sample buffer value =
  buffer.data.(buffer.next) <- value;
  buffer.next <- Int.rem (buffer.next + 1) buffer_capacity;
  if buffer.length < buffer_capacity then buffer.length <- buffer.length + 1

let copy_samples buffer =
  let result = Array.create ~len:buffer.length 0.0 in
  for i = 0 to buffer.length - 1 do
    let idx =
      Int.rem
        (buffer.next - buffer.length + i + buffer_capacity)
        buffer_capacity
    in
    result.(i) <- buffer.data.(idx)
  done;
  result

let percentile samples p =
  let len = Array.length samples in
  if len = 0 then 0.0
  else
    let sorted = Array.copy samples in
    Array.sort sorted ~compare:Float.compare;
    let rank = p *. Float.of_int (len - 1) in
    let lower = Float.iround_towards_zero_exn (Float.round_down rank) in
    let upper = Float.iround_towards_zero_exn (Float.round_up rank) in
    if lower = upper then sorted.(lower)
    else
      let weight = rank -. Float.of_int lower in
      sorted.(lower) +. (weight *. (sorted.(upper) -. sorted.(lower)))

type request_stat = {
  mutex : Stdlib.Mutex.t;
  mutable count : int;
  mutable error_count : int;
  latencies : sample_buffer;
}

let create_request_stat () =
  {
    mutex = Stdlib.Mutex.create ();
    count = 0;
    error_count = 0;
    latencies = create_buffer ();
  }

let request_mutex = Stdlib.Mutex.create ()

let request_stats : (string, request_stat) Hashtbl.t =
  Hashtbl.create (module String)

let with_request_stat route f =
  Stdlib.Mutex.lock request_mutex;
  let stat =
    Hashtbl.find_or_add request_stats route ~default:create_request_stat
  in
  Stdlib.Mutex.unlock request_mutex;
  Stdlib.Mutex.lock stat.mutex;
  let result =
    try f stat
    with exn ->
      Stdlib.Mutex.unlock stat.mutex;
      raise exn
  in
  Stdlib.Mutex.unlock stat.mutex;
  result

let record_request ~route ~latency_ms ~status =
  with_request_stat route (fun stat ->
      stat.count <- stat.count + 1;
      if status >= 400 then stat.error_count <- stat.error_count + 1;
      add_sample stat.latencies latency_ms)

let snapshot_request_stat route stat =
  Stdlib.Mutex.lock stat.mutex;
  let count = stat.count in
  let error_count = stat.error_count in
  let samples = copy_samples stat.latencies in
  Stdlib.Mutex.unlock stat.mutex;
  (route, count, error_count, samples)

let escape_label_value value =
  let buffer = Stdlib.Buffer.create (String.length value) in
  String.iter value ~f:(fun ch ->
      match ch with
      | '\\' -> Stdlib.Buffer.add_string buffer "\\\\"
      | '\"' -> Stdlib.Buffer.add_string buffer "\\\""
      | '\n' -> Stdlib.Buffer.add_string buffer "\\n"
      | '\r' -> Stdlib.Buffer.add_string buffer "\\r"
      | '\t' -> Stdlib.Buffer.add_string buffer "\\t"
      | ch when Char.is_print ch -> Stdlib.Buffer.add_char buffer ch
      | _ -> Stdlib.Buffer.add_char buffer '_');
  Stdlib.Buffer.contents buffer

let render_request_metrics () =
  Hashtbl.fold request_stats ~init:[] ~f:(fun ~key ~data acc ->
      let route, count, error_count, samples = snapshot_request_stat key data in
      let label = Printf.sprintf "{route=\"%s\"}" (escape_label_value route) in
      let p50 = percentile samples 0.50 in
      let p95 = percentile samples 0.95 in
      let p99 = percentile samples 0.99 in
      let metrics =
        [
          Printf.sprintf "api_request_total%s %d" label count;
          Printf.sprintf "api_request_errors_total%s %d" label error_count;
          Printf.sprintf "api_request_latency_ms_p50%s %.3f" label p50;
          Printf.sprintf "api_request_latency_ms_p95%s %.3f" label p95;
          Printf.sprintf "api_request_latency_ms_p99%s %.3f" label p99;
        ]
      in
      metrics @ acc)

let agent_mutex = Stdlib.Mutex.create ()
let agent_cache_hits = ref 0
let agent_cache_misses = ref 0
let agent_eval_total = ref 0
let agent_eval_errors = ref 0
let agent_eval_latency_sum = ref 0.0
let agent_circuit_open = ref false

let record_agent_cache_hit () =
  Stdlib.Mutex.lock agent_mutex;
  Int.incr agent_cache_hits;
  Stdlib.Mutex.unlock agent_mutex

let record_agent_cache_miss () =
  Stdlib.Mutex.lock agent_mutex;
  Int.incr agent_cache_misses;
  Stdlib.Mutex.unlock agent_mutex

let record_agent_evaluation ~success ~latency_ms =
  Stdlib.Mutex.lock agent_mutex;
  Int.incr agent_eval_total;
  agent_eval_latency_sum := !agent_eval_latency_sum +. latency_ms;
  if not success then Int.incr agent_eval_errors;
  Stdlib.Mutex.unlock agent_mutex

let set_agent_circuit_state ~open_ =
  Stdlib.Mutex.lock agent_mutex;
  agent_circuit_open := open_;
  Stdlib.Mutex.unlock agent_mutex

let render_agent_metrics () =
  Stdlib.Mutex.lock agent_mutex;
  let hits = !agent_cache_hits in
  let misses = !agent_cache_misses in
  let evals = !agent_eval_total in
  let eval_errors = !agent_eval_errors in
  let latency_sum = !agent_eval_latency_sum in
  let circuit_open = if !agent_circuit_open then 1 else 0 in
  Stdlib.Mutex.unlock agent_mutex;
  [
    Printf.sprintf "agent_cache_hits_total %d" hits;
    Printf.sprintf "agent_cache_misses_total %d" misses;
    Printf.sprintf "agent_evaluations_total %d" evals;
    Printf.sprintf "agent_evaluation_errors_total %d" eval_errors;
    Printf.sprintf "agent_evaluation_latency_ms_sum %.3f" latency_sum;
    Printf.sprintf "agent_circuit_breaker_state %d" circuit_open;
  ]

let render () = render_request_metrics () @ render_agent_metrics ()

let reset_for_tests () =
  Stdlib.Mutex.lock request_mutex;
  Hashtbl.clear request_stats;
  Stdlib.Mutex.unlock request_mutex;
  Stdlib.Mutex.lock agent_mutex;
  agent_cache_hits := 0;
  agent_cache_misses := 0;
  agent_eval_total := 0;
  agent_eval_errors := 0;
  agent_eval_latency_sum := 0.0;
  agent_circuit_open := false;
  Stdlib.Mutex.unlock agent_mutex
