(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
open Decl_defs
open Aast
open Shallow_decl_defs
open Typing_defs
module Attrs = Naming_attributes
module SN = Naming_special_names

(** Helpers for checking initialization of class properties by looking at decls. *)

let parent_init_prop = "parent::" ^ SN.Members.__construct

(* If we need to call parent::__construct, we treat it as if it were
 * a class variable that needs to be initialized. It's a bit hacky
 * but it works. The idea here is that if the parent needs to be
 * initialized, we add a phony class variable. *)
let add_parent_construct ?class_cache decl_env c props parent_ty =
  match get_node parent_ty with
  | Tapply ((_, parent), _) ->
    begin
      match Decl_env.get_class_add_dep decl_env parent ?cache:class_cache with
      | Some class_ when class_.dc_need_init && Option.is_some c.sc_constructor
        ->
        SSet.add parent_init_prop props
      | _ -> props
    end
  | _ -> props

let parent ?class_cache decl_env c acc =
  if FileInfo.is_hhi c.sc_mode then
    acc
  else if Ast_defs.is_c_trait c.sc_kind then
    List.fold_left
      c.sc_req_extends
      ~f:(add_parent_construct ?class_cache decl_env c)
      ~init:acc
  else
    match c.sc_extends with
    | [] -> acc
    | parent_ty :: _ -> add_parent_construct decl_env c acc parent_ty

let is_lateinit cv =
  Attrs.mem SN.UserAttributes.uaLateInit cv.cv_user_attributes

let prop_may_need_init sp =
  if Option.is_some sp.sp_xhp_attr then
    false
  else if sp_lateinit sp then
    false
  else
    sp_needs_init sp

let own_props c props =
  List.fold_left
    c.sc_props
    ~f:
      begin
        fun acc sp ->
        if prop_may_need_init sp then
          SSet.add (snd sp.sp_name) acc
        else
          acc
      end
    ~init:props

let init_not_required_props c props =
  List.fold_left
    c.sc_props
    ~f:
      begin
        fun acc sp ->
        if prop_may_need_init sp then
          acc
        else
          SSet.add (snd sp.sp_name) acc
      end
    ~init:props

type class_cache = Decl_store.class_entries SMap.t

let parent_props ?(class_cache : class_cache option) decl_env c props =
  List.fold_left
    c.sc_extends
    ~f:
      begin
        fun acc parent ->
        match get_node parent with
        | Tapply ((_, parent), _) ->
          let tc =
            Decl_env.get_class_add_dep decl_env parent ?cache:class_cache
          in
          begin
            match tc with
            | None -> acc
            | Some { dc_deferred_init_members = members; _ } ->
              SSet.union members acc
          end
        | _ -> acc
      end
    ~init:props

let trait_props decl_env c props =
  List.fold_left
    c.sc_uses
    ~f:
      begin
        fun props_acc used_ty ->
        match get_node used_ty with
        | Tapply ((_, trait), _) ->
          let class_ = Decl_env.get_class_add_dep decl_env trait in
          (match class_ with
          | None -> props_acc
          | Some { dc_construct = cstr; dc_deferred_init_members = members; _ }
            ->
            (* If our current class defines its own constructor, completely ignore
             * the fact that the trait may have had one defined and merge in all of
             * its members.
             * If the curr. class does not have its own constructor, only fold in
             * the trait members if it would not have had its own constructor when
             * defining `dc_deferred_init_members`. See logic in `class_` for
             * Ast_defs.Cclass (Abstract) to see where this deviated for traits. *)
            begin
              match fst cstr with
              | None -> SSet.union members props_acc
              | Some cstr
                when String.( <> ) cstr.elt_origin trait
                     || get_elt_abstract cstr ->
                SSet.union members props_acc
              | _ when Option.is_some c.sc_constructor ->
                SSet.union members props_acc
              | _ -> props_acc
            end)
        | _ -> props_acc
      end
    ~init:props

(** return a tuple of the private init-requiring props of the class
    and all init-requiring props of the class and its ancestors *)
let get_deferred_init_props ?(class_cache : class_cache option) decl_env c =
  let (priv_props, props) =
    List.fold_left
      ~f:(fun (priv_props, props) sp ->
        let name = snd sp.sp_name in
        let visibility = sp.sp_visibility in
        if not (prop_may_need_init sp) then
          (priv_props, props)
        else if Aast.(equal_visibility visibility Private) then
          (SSet.add name priv_props, SSet.add name props)
        else
          (priv_props, SSet.add name props))
      ~init:(SSet.empty, SSet.empty)
      c.sc_props
  in
  let props = parent_props ?class_cache decl_env c props in
  let props = parent ?class_cache decl_env c props in
  (priv_props, props)

let class_ ~has_own_cstr ?(class_cache : class_cache option) decl_env c =
  match c.sc_kind with
  | Ast_defs.Cclass k when Ast_defs.is_abstract k && not has_own_cstr ->
    get_deferred_init_props ?class_cache decl_env c
  | Ast_defs.Ctrait -> get_deferred_init_props decl_env c
  | Ast_defs.(Cclass _ | Cinterface | Cenum | Cenum_class _) ->
    (SSet.empty, SSet.empty)

(**
 * [parent_initialized_members decl_env c] returns all members initialized in
 * the parents of [c], s.t. they should not be readable within [c]'s
 * [__construct] method until _after_ [parent::__construct] has been called.
 *)
let parent_initialized_members ?(class_cache : class_cache option) decl_env c =
  let parent_initialized_members_helper = function
    | None -> SSet.empty
    | Some { dc_props; _ } ->
      dc_props
      |> SMap.filter (fun _ p -> Decl_defs.get_elt_needs_init p)
      |> SMap.keys
      |> SSet.of_list
  in
  List.fold_left
    c.sc_extends
    ~f:
      begin
        fun acc parent ->
        match get_node parent with
        | Tapply ((_, parent), _) ->
          Decl_env.get_class_add_dep decl_env parent ?cache:class_cache
          |> parent_initialized_members_helper
          |> SSet.union acc
        | _ -> acc
      end
    ~init:SSet.empty
