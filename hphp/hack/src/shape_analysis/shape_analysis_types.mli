(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

module LMap = Local_id.Map
module KMap = Typing_continuations.Map

type mode =
  | FlagTargets
      (** Flag all possible targets, e.g., `dict['k1' => 42, 'k2' =>
          'meaning']` without performing any analysis *)
  | DumpConstraints  (** Dump constraints generated by analysing the program *)
  | SimplifyConstraints
      (** Partially solve key constraints within functions and methods and
          report back summaries about which `dict`s might be `shape`s and which
          functions/methods they depend on. *)
  | SolveConstraints
      (** Globally solve the key constraints and report back `dict`s that can
          be `shape`s along with the `shape` keys *)

type options = { mode: mode }

type entity_ =
  | Literal of Pos.t
  | Variable of int
[@@deriving eq, ord]

type entity = entity_ option

type shape_key = SK_string of string [@@deriving eq, ord]

type constraint_ =
  | Exists of entity_  (** Records existence of a dict *)
  | Has_static_key of entity_ * shape_key * Typing_defs.locl_ty
      (** Records the static key an entity is accessed with along with the Hack
          type of the key *)
  | Has_dynamic_key of entity_
      (** Records that an entity is accessed with a dynamic key *)
  | Points_to of entity_ * entity_
      (** Records that the first entity points to the second one *)

type shape_result =
  | Shape_like_dict of Pos.t * (shape_key * Typing_defs.locl_ty) list
      (** A dict that acts like a shape along with its keys and types the keys
          point to *)
  | Dynamically_accessed_dict of entity_
      (** A dict that is accessed or used dynamically. This is important
          in inter-procedural setting where a locally static dict calls a
          function where the parameter is accessed dynamically. In that case,
          the original result on static access should be invalidated. *)

(** Local variable environment. Its values are `entity`, i.e., `entity_
    option`, so that we can avoid pattern matching in constraint extraction. *)
type lenv = entity LMap.t KMap.t

type env = {
  constraints: constraint_ list;  (** Append-only set of constraints *)
  lenv: lenv;  (** Local variable information *)
  saved_env: Tast.saved_env;
      (** Environment stored in the TAST used to expand types *)
}

module PointsToSet : Set.S with type elt = entity_ * entity_

module ShapeKeyMap : Map.S with type key = shape_key
