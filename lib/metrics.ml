open! Base

module Registry = struct
  type t = Prometheus.CollectorRegistry.t

  let current_registry : t ref = ref Prometheus.CollectorRegistry.default
  let current () = !current_registry
  let use registry = current_registry := registry
  let use_default () = current_registry := Prometheus.CollectorRegistry.default
  let create () = Prometheus.CollectorRegistry.create ()

  let collect ?registry () =
    let registry = Option.value registry ~default:(current ()) in
    let open Lwt.Syntax in
    let* snapshot = Prometheus.CollectorRegistry.collect registry in
    let buffer = Stdlib.Buffer.create 512 in
    let formatter = Stdlib.Format.formatter_of_buffer buffer in
    Prometheus_app.TextFormat_0_0_4.output formatter snapshot;
    Stdlib.Format.pp_print_flush formatter ();
    Lwt.return (Stdlib.Buffer.contents buffer)
end

module Internal = struct
  let validate_label_count ~expected values =
    let actual = List.length values in
    if Int.equal expected actual then Or_error.return values
    else Or_error.errorf "expected %d label values, received %d" expected actual

  let ensure_non_negative amount =
    if Float.(amount < 0.) then
      Or_error.errorf "metric increments must be >= 0 (received %.3f)" amount
    else Or_error.return amount
end

module Counter = struct
  type t =
    | Unlabeled of Prometheus.Counter.t
    | Labeled of { family : Prometheus.Counter.family; label_count : int }

  let create ?registry ?namespace ?subsystem ?label_names ~help name =
    let registry = Option.value registry ~default:(Registry.current ()) in
    Or_error.try_with (fun () ->
        match label_names with
        | None ->
            Unlabeled
              (Prometheus.Counter.v ~registry ~help ?namespace ?subsystem name)
        | Some names ->
            let family =
              Prometheus.Counter.v_labels ~registry ~label_names:names ~help
                ?namespace ?subsystem name
            in
            Labeled { family; label_count = List.length names })

  let inc ?label_values ?amount t =
    let amount = Option.value amount ~default:1.0 in
    match Internal.ensure_non_negative amount with
    | Error _ as err -> err
    | Ok amount -> (
        match (t, label_values) with
        | Unlabeled metric, None ->
            Or_error.try_with (fun () -> Prometheus.Counter.inc metric amount)
        | Unlabeled _, Some _ ->
            Or_error.error_string
              "counter has no labels but label values supplied"
        | Labeled _, None ->
            Or_error.error_string "counter requires label values"
        | Labeled { family; label_count }, Some values -> (
            match
              Internal.validate_label_count ~expected:label_count values
            with
            | Error _ as err -> err
            | Ok values ->
                Or_error.try_with (fun () ->
                    let child = Prometheus.Counter.labels family values in
                    Prometheus.Counter.inc child amount)))

  let inc_one ?label_values t = inc ?label_values ~amount:1.0 t
end

module Gauge = struct
  type t =
    | Unlabeled of Prometheus.Gauge.t
    | Labeled of { family : Prometheus.Gauge.family; label_count : int }

  let create ?registry ?namespace ?subsystem ?label_names ~help name =
    let registry = Option.value registry ~default:(Registry.current ()) in
    Or_error.try_with (fun () ->
        match label_names with
        | None ->
            Unlabeled
              (Prometheus.Gauge.v ~registry ~help ?namespace ?subsystem name)
        | Some names ->
            let family =
              Prometheus.Gauge.v_labels ~registry ~label_names:names ~help
                ?namespace ?subsystem name
            in
            Labeled { family; label_count = List.length names })

  let with_metric t label_values f =
    match (t, label_values) with
    | Unlabeled metric, None -> Or_error.try_with (fun () -> f metric)
    | Unlabeled _, Some _ ->
        Or_error.error_string "gauge has no labels but label values supplied"
    | Labeled _, None -> Or_error.error_string "gauge requires label values"
    | Labeled { family; label_count }, Some values -> (
        match Internal.validate_label_count ~expected:label_count values with
        | Error _ as err -> err
        | Ok values ->
            Or_error.try_with (fun () ->
                let metric = Prometheus.Gauge.labels family values in
                f metric))

  let set ?label_values value t =
    with_metric t label_values (fun metric -> Prometheus.Gauge.set metric value)

  let inc ?label_values ?amount t =
    let amount = Option.value amount ~default:1.0 in
    with_metric t label_values (fun metric ->
        Prometheus.Gauge.inc metric amount)

  let dec ?label_values ?amount t =
    let amount = Option.value amount ~default:1.0 in
    with_metric t label_values (fun metric ->
        Prometheus.Gauge.dec metric amount)
end

module Summary = struct
  type t =
    | Unlabeled of Prometheus.Summary.t
    | Labeled of { family : Prometheus.Summary.family; label_count : int }

  let create ?registry ?namespace ?subsystem ?label_names ~help name =
    let registry = Option.value registry ~default:(Registry.current ()) in
    Or_error.try_with (fun () ->
        match label_names with
        | None ->
            Unlabeled
              (Prometheus.Summary.v ~registry ~help ?namespace ?subsystem name)
        | Some names ->
            let family =
              Prometheus.Summary.v_labels ~registry ~label_names:names ~help
                ?namespace ?subsystem name
            in
            Labeled { family; label_count = List.length names })

  let observe ?label_values value t =
    match (t, label_values) with
    | Unlabeled metric, None ->
        Or_error.try_with (fun () -> Prometheus.Summary.observe metric value)
    | Unlabeled _, Some _ ->
        Or_error.error_string "summary has no labels but label values supplied"
    | Labeled _, None -> Or_error.error_string "summary requires label values"
    | Labeled { family; label_count }, Some values -> (
        match Internal.validate_label_count ~expected:label_count values with
        | Error _ as err -> err
        | Ok values ->
            Or_error.try_with (fun () ->
                let metric = Prometheus.Summary.labels family values in
                Prometheus.Summary.observe metric value))
end

module Histogram = struct
  type t =
    | Unlabeled of Prometheus.DefaultHistogram.t
    | Labeled of {
        family : Prometheus.DefaultHistogram.family;
        label_count : int;
      }

  let create ?registry ?namespace ?subsystem ?label_names ~help name =
    let registry = Option.value registry ~default:(Registry.current ()) in
    Or_error.try_with (fun () ->
        match label_names with
        | None ->
            Unlabeled
              (Prometheus.DefaultHistogram.v ~registry ~help ?namespace
                 ?subsystem name)
        | Some names ->
            let family =
              Prometheus.DefaultHistogram.v_labels ~registry ~label_names:names
                ~help ?namespace ?subsystem name
            in
            Labeled { family; label_count = List.length names })

  let observe ?label_values value t =
    match (t, label_values) with
    | Unlabeled metric, None ->
        Or_error.try_with (fun () ->
            Prometheus.DefaultHistogram.observe metric value)
    | Unlabeled _, Some _ ->
        Or_error.error_string
          "histogram has no labels but label values supplied"
    | Labeled _, None -> Or_error.error_string "histogram requires label values"
    | Labeled { family; label_count }, Some values -> (
        match Internal.validate_label_count ~expected:label_count values with
        | Error _ as err -> err
        | Ok values ->
            Or_error.try_with (fun () ->
                let metric = Prometheus.DefaultHistogram.labels family values in
                Prometheus.DefaultHistogram.observe metric value))
end
