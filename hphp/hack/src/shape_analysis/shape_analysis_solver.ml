(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
open Shape_analysis_types

type constraints = {
  exists: entity_ list;
  static_accesses: (entity_ * shape_key * Typing_defs.locl_ty) list;
  dynamic_accesses: entity_ list;
  points_tos: (entity_ * entity_) list;
}

let constraints_init =
  { exists = []; static_accesses = []; dynamic_accesses = []; points_tos = [] }

let rec transitive_closure (set : PointsToSet.t) : PointsToSet.t =
  let immediate_consequence (x, y) set =
    let add (y', z) set =
      if equal_entity_ y y' then
        PointsToSet.add (x, z) set
      else
        set
    in
    PointsToSet.fold add set set
  in
  let new_set = PointsToSet.fold immediate_consequence set set in
  if PointsToSet.cardinal new_set = PointsToSet.cardinal set then
    set
  else
    transitive_closure new_set

let partition_constraint constraints = function
  | Exists entity -> { constraints with exists = entity :: constraints.exists }
  | Has_static_key (entity, key, ty) ->
    {
      constraints with
      static_accesses = (entity, key, ty) :: constraints.static_accesses;
    }
  | Has_dynamic_key entity ->
    {
      constraints with
      dynamic_accesses = entity :: constraints.dynamic_accesses;
    }
  | Points_to (pointer_entity, pointed_entity) ->
    {
      constraints with
      points_tos = (pointer_entity, pointed_entity) :: constraints.points_tos;
    }

let simplify (env : Typing_env_types.env) (constraints : constraint_ list) :
    shape_result list =
  let { exists; static_accesses; dynamic_accesses; points_tos } =
    List.fold ~init:constraints_init ~f:partition_constraint constraints
  in

  let variable_to_literal_map =
    let add_pointer_to_literal points_to map =
      match points_to with
      | (Variable pointer, Literal pointed) ->
        IMap.add pointer (Pos.Set.singleton pointed) map ~combine:Pos.Set.union
      | _ -> map
    in
    PointsToSet.of_list points_tos |> transitive_closure |> fun points_to_set ->
    PointsToSet.fold add_pointer_to_literal points_to_set IMap.empty
  in

  let poss_of_entity = function
    | Literal pos -> [pos]
    | Variable var ->
      begin
        match IMap.find_opt var variable_to_literal_map with
        | Some poss -> Pos.Set.elements poss
        | None ->
          failwith
            (Format.sprintf "Could not find which entity %d points to" var)
      end
  in
  let static_accesses =
    List.concat_map
      ~f:(fun (entity, key, ty) ->
        poss_of_entity entity |> List.map ~f:(fun pos -> (pos, key, ty)))
      static_accesses
  in

  (* Start collecting shape results starting with empty shapes of candidates *)
  let static_shape_results : Typing_defs.locl_ty ShapeKeyMap.t Pos.Map.t =
    exists
    |> List.concat_map ~f:poss_of_entity
    |> List.fold
         ~f:(fun map pos -> Pos.Map.add pos ShapeKeyMap.empty map)
         ~init:Pos.Map.empty
  in

  (* Invalidate candidates that are observed to experience dynamic access *)
  let dynamic_accesses =
    dynamic_accesses |> List.concat_map ~f:poss_of_entity |> Pos.Set.of_list
  in
  let static_shape_results : Typing_defs.locl_ty ShapeKeyMap.t Pos.Map.t =
    static_shape_results
    |> Pos.Map.filter (fun pos _ -> not @@ Pos.Set.mem pos dynamic_accesses)
  in

  (* Add known keys *)
  let static_shape_results : Typing_defs.locl_ty ShapeKeyMap.t Pos.Map.t =
    let update_shape_key ty = function
      | None -> Some ty
      | Some ty' ->
        let (_env, ty) = Typing_union.union env ty ty' in
        Some ty
    in
    let update_entity key ty = function
      | None -> None
      | Some shape_key_map ->
        Some (ShapeKeyMap.update key (update_shape_key ty) shape_key_map)
    in
    static_accesses
    |> List.fold ~init:static_shape_results ~f:(fun pos_map (pos, key, ty) ->
           Pos.Map.update pos (update_entity key ty) pos_map)
  in

  (* Convert to individual statically accessed dict results *)
  let static_shape_results : shape_result list =
    static_shape_results
    |> Pos.Map.bindings
    |> List.map ~f:(fun (pos, keys_and_types) ->
           Shape_like_dict (pos, ShapeKeyMap.bindings keys_and_types))
  in

  let dynamic_shape_results =
    Pos.Set.elements dynamic_accesses
    |> List.map ~f:(fun entity_ -> Dynamically_accessed_dict (Literal entity_))
  in

  static_shape_results @ dynamic_shape_results
