open! Base
open Alcotest
open Chessmate

let test_disabled_breaker () =
  Agent_circuit_breaker.configure ~threshold:0 ~cooloff_seconds:30.;
  check bool "allows when disabled" true (Agent_circuit_breaker.should_allow ());
  Agent_circuit_breaker.record_failure ();
  check bool "still allows after failure" true
    (Agent_circuit_breaker.should_allow ());
  check string "status disabled" "disabled"
    (Agent_circuit_breaker.status_to_string
       (Agent_circuit_breaker.current_status ()))

let test_open_half_open_cycle () =
  Agent_circuit_breaker.configure ~threshold:2 ~cooloff_seconds:0.05;
  check bool "initial allow" true (Agent_circuit_breaker.should_allow ());
  Agent_circuit_breaker.record_failure ();
  check bool "still allow after first failure" true
    (Agent_circuit_breaker.should_allow ());
  Agent_circuit_breaker.record_failure ();
  check bool "blocked when threshold reached" false
    (Agent_circuit_breaker.should_allow ());
  check string "status open" "open"
    (Agent_circuit_breaker.status_to_string
       (Agent_circuit_breaker.current_status ()));
  Unix.sleepf 0.06;
  check bool "half-open allows attempt" true
    (Agent_circuit_breaker.should_allow ());
  check string "status half-open" "half_open"
    (Agent_circuit_breaker.status_to_string
       (Agent_circuit_breaker.current_status ()));
  Agent_circuit_breaker.record_success ();
  check string "status closed" "closed"
    (Agent_circuit_breaker.status_to_string
       (Agent_circuit_breaker.current_status ()))

let suite =
  [
    ("breaker disabled", `Quick, test_disabled_breaker);
    ("breaker open/half-open cycle", `Quick, test_open_half_open_cycle);
  ]
