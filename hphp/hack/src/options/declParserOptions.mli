(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

type t = {
  auto_namespace_map: (string * string) list;
  disable_xhp_element_mangling: bool;
  interpret_soft_types_as_like_types: bool;
  allow_new_attribute_syntax: bool;
  enable_xhp_class_modifier: bool;
  everything_sdt: bool;
  global_inference: bool;
  gi_reinfer_types: string list;
}
[@@deriving show]

val default : t

val from_parser_options : ParserOptions.t -> t
