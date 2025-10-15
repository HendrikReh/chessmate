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

module Registry : sig
  type t = Prometheus.CollectorRegistry.t

  val current : unit -> t
  (** Active registry used for newly created metrics. *)

  val use : t -> unit
  (** Switch the active registry. Existing metric handles become invalid and
      should be recreated by callers. *)

  val use_default : unit -> unit
  (** Reset the active registry to the library default. *)

  val create : unit -> t
  (** Allocate a fresh registry, useful for tests. *)

  val collect : ?registry:t -> unit -> string Lwt.t
  (** Collect all registered metrics from [registry] (defaults to {!current})
      and render them in Prometheus text exposition format. *)
end

module Counter : sig
  type t

  val create :
    ?registry:Registry.t ->
    ?namespace:string ->
    ?subsystem:string ->
    ?label_names:string list ->
    help:string ->
    string ->
    t Or_error.t

  val inc : ?label_values:string list -> ?amount:float -> t -> unit Or_error.t
  val inc_one : ?label_values:string list -> t -> unit Or_error.t
end

module Gauge : sig
  type t

  val create :
    ?registry:Registry.t ->
    ?namespace:string ->
    ?subsystem:string ->
    ?label_names:string list ->
    help:string ->
    string ->
    t Or_error.t

  val set : ?label_values:string list -> float -> t -> unit Or_error.t
  val inc : ?label_values:string list -> ?amount:float -> t -> unit Or_error.t
  val dec : ?label_values:string list -> ?amount:float -> t -> unit Or_error.t
end

module Summary : sig
  type t

  val create :
    ?registry:Registry.t ->
    ?namespace:string ->
    ?subsystem:string ->
    ?label_names:string list ->
    help:string ->
    string ->
    t Or_error.t

  val observe : ?label_values:string list -> float -> t -> unit Or_error.t
end

module Histogram : sig
  type t

  val create :
    ?registry:Registry.t ->
    ?namespace:string ->
    ?subsystem:string ->
    ?label_names:string list ->
    help:string ->
    string ->
    t Or_error.t

  val observe : ?label_values:string list -> float -> t -> unit Or_error.t
end
