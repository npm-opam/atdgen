open Printf
open Atd_ast
open Ag_error
open Ag_mapping

type o = Ag_ocaml.atd_ocaml_repr
type v = Ag_validate.validate_repr

type ov_mapping =
    (Ag_ocaml.atd_ocaml_repr, Ag_validate.validate_repr) Ag_mapping.mapping

type ob_def =
    (Ag_ocaml.atd_ocaml_repr, Ag_validate.validate_repr) Ag_mapping.def

(*
  Determine whether a type expression does not need validation.

  1. Flatten.
     For each type expression of interest, produce the list
     of all type expressions on which it depends.

  2. Read annotations.
     If any of the type expressions has a validator annotation or if
     on the type expressions is abstract, then the result is false.
*)

let ploc x =
  eprintf "%s\n" (string_of_loc (loc_of_type_expr x))

let print s =
  eprintf "%s\n%!" s

let get_def defs name : type_expr option =
  try Some (Hashtbl.find defs name)
  with Not_found -> None

let noval x =
  let an = Atd_ast.annot_of_type_expr x in
  Ag_validate.get_validator an = None

module H = Hashtbl.Make (
  struct
    type t = type_expr
    let equal = ( == )
    let hash = Hashtbl.hash
  end
)

let for_all_children f x0 =
  let is_root = ref true in
  try
    Atd_ast.fold (
      fun x () ->
        if !is_root then (
          is_root := false;
          assert (x == x0);
        )
        else
          if not (f x) then
            raise Exit
    ) x0 ();
    true
  with Exit ->
    false

(*
  Return if an expression is shallow, i.e. it does not require to call
  a validation function other than the one possibly given
  by an annotation <ocaml validator="..."> on this node.

  Shallow:
    int
    int <ocaml validator="foo">
    { x : int } <ocaml validator="foo">
    t   (* where t is defined as: type t = int *)

  Not shallow:
    t   (* where t is defined as: type t = int <ocaml validator="foo"> *)
    { x : int <ocaml validator="foo"> }
    'a t
    t   (* where t is defined as: type t = abstract *)
*)
let rec scan_expr
    (defs : (string, type_expr) Hashtbl.t)
    (visited : unit H.t)
    (results : bool H.t)
    (x : type_expr) : bool =

  if not (H.mem visited x) then (
    H.add visited x ();
    try H.find results x
    with Not_found ->
      name_is_shallow defs visited results x
      && for_all_children (
        fun x ->
          noval x
          && scan_expr defs visited results x
      ) x
  )
  else
    (* neutral for the && operator *)
    true

and name_is_shallow defs visited results x =
  match x with
      `Name (loc, (loc2, name, _), _) ->
        (match get_def defs name with
             None ->
               (match name with
                    "unit"
                  | "bool"
                  | "int"
                  | "float"
                  | "string" -> true
                  | _ -> false
               )
           | Some x -> noval x && scan_expr defs visited results x
        )

    | `Tvar (loc, _) -> false
    | _ -> (* already verified in the call to scan_expr above *) true


let iter f x =
  Atd_ast.fold (fun x () -> f x) x ()

let scan_top_expr
    (defs : (string, type_expr) Hashtbl.t)
    (results : bool H.t)
    (x : type_expr) : unit =

  (* Force-scan all sub-expressions *)
  iter (
    fun x ->
      if not (H.mem results x) then (
        let b = scan_expr defs (H.create 10) results x in
        (try
           let b0 = H.find results x in
           assert (b0 = b);
         with Not_found -> ());
        H.replace results x b
      )
  ) x

let make_is_shallow defs =
  let results = H.create 100 in
  Hashtbl.iter (
    fun name x -> scan_top_expr defs results x
  ) defs;
  fun x ->
    try
      H.find results x
    with Not_found -> assert false

(*
  Translation of the types into the ocaml/validate mapping.
*)

let rec mapping_of_expr
    (is_shallow : type_expr -> bool)
    (x0 : type_expr) : ov_mapping =

  let v an = Ag_validate.get_validator an in
  let v2 an x = (Ag_validate.get_validator an, is_shallow x) in
  match x0 with
      `Sum (loc, l, an) ->
        let ocaml_t = `Sum (Ag_ocaml.get_ocaml_sum an) in
        `Sum (loc, Array.of_list (List.map (mapping_of_variant is_shallow) l),
              ocaml_t, v2 an x0)

    | `Record (loc, l, an) ->
        let ocaml_t = `Record (Ag_ocaml.get_ocaml_record an) in
        let ocaml_field_prefix = Ag_ocaml.get_ocaml_field_prefix an in
        `Record (loc,
                 Array.of_list
                   (List.map
                      (mapping_of_field is_shallow ocaml_field_prefix) l),
                 ocaml_t, v2 an x0)

    | `Tuple (loc, l, an) ->
        let ocaml_t = `Tuple in
        `Tuple (loc, Array.of_list (List.map (mapping_of_cell is_shallow) l),
                ocaml_t, v2 an x0)

    | `List (loc, x, an) ->
        let ocaml_t = `List (Ag_ocaml.get_ocaml_list an) in
        `List (loc, mapping_of_expr is_shallow x, ocaml_t, v2 an x0)

    | `Option (loc, x, an) ->
        let ocaml_t = `Option in
        `Option (loc, mapping_of_expr is_shallow x, ocaml_t, v2 an x0)

    | `Nullable (loc, x, an) ->
        let ocaml_t = `Nullable in
        `Nullable (loc, mapping_of_expr is_shallow x, ocaml_t, v2 an x0)

    | `Shared (loc, x, an) ->
        failwith "Sharing is not supported"

    | `Wrap (loc, x, an) ->
        let w = Ag_ocaml.get_ocaml_wrap loc an in
        let ocaml_t = `Wrap w in
        let validator =
          match w with
              None -> v2 an x0
            | Some _ -> v an, true
        in
        `Wrap (loc, mapping_of_expr is_shallow x, ocaml_t, validator)

    | `Name (loc, (loc2, s, l), an) ->
        (match s with
             "unit" ->
               `Unit (loc, `Unit, (v an, true))
           | "bool" ->
               `Bool (loc, `Bool, (v an, true))
           | "int" ->
               let o = Ag_ocaml.get_ocaml_int an in
               `Int (loc, `Int o, (v an, true))
           | "float" ->
               `Float (loc, `Float, (v an, true))
           | "string" ->
               `String (loc, `String, (v an, true))
           | s ->
               let validator =
                 match v2 an x0 with
                     None, true -> None
                   | x -> Some x
               in
               `Name (loc, s, List.map (mapping_of_expr is_shallow) l,
                      None, validator)
        )
    | `Tvar (loc, s) ->
        `Tvar (loc, s)

and mapping_of_cell is_shallow (loc, x, an) =
  let default = Ag_ocaml.get_ocaml_default an in
  let doc = Ag_doc.get_doc loc an in
  let ocaml_t =
    `Cell {
      Ag_ocaml.ocaml_default = default;
      ocaml_fname = "";
      ocaml_mutable = false;
      ocaml_fdoc = doc;
    }
  in
  {
    cel_loc = loc;
    cel_value = mapping_of_expr is_shallow x;
    cel_arepr = ocaml_t;
    cel_brepr = (None, noval x && is_shallow x)
  }


and mapping_of_variant is_shallow = function
    `Variant (loc, (s, an), o) ->
      let ocaml_cons = Ag_ocaml.get_ocaml_cons s an in
      let doc = Ag_doc.get_doc loc an in
      let ocaml_t =
        `Variant {
          Ag_ocaml.ocaml_cons = ocaml_cons;
          ocaml_vdoc = doc;
        }
      in
      let arg, validate_t =
        match o with
            None ->
              None, (None, true)
          | Some x ->
              (Some (mapping_of_expr is_shallow x),
               (None, noval x && is_shallow x))
      in
      {
        var_loc = loc;
        var_cons = s;
        var_arg = arg;
        var_arepr = ocaml_t;
        var_brepr = validate_t;
      }

  | `Inherit _ -> assert false

and mapping_of_field is_shallow ocaml_field_prefix = function
    `Field (loc, (s, fk, an), x) ->
      let fvalue = mapping_of_expr is_shallow x in
      let ocaml_default =
        match fk, Ag_ocaml.get_ocaml_default an with
            `Required, None -> None
          | `Optional, None -> Some "None"
          | (`Required | `Optional), Some _ ->
              error loc "Superfluous default OCaml value"
          | `With_default, Some s -> Some s
          | `With_default, None ->
              (* will try to determine implicit default value later *)
              None
      in
      let ocaml_fname = Ag_ocaml.get_ocaml_fname (ocaml_field_prefix ^ s) an in
      let ocaml_mutable = Ag_ocaml.get_ocaml_mutable an in
      let doc = Ag_doc.get_doc loc an in
      { f_loc = loc;
        f_name = s;
        f_kind = fk;
        f_value = fvalue;

        f_arepr = `Field {
          Ag_ocaml.ocaml_default = ocaml_default;
          ocaml_fname = ocaml_fname;
          ocaml_mutable = ocaml_mutable;
          ocaml_fdoc = doc;
        };

        f_brepr = (None, noval x && is_shallow x);
      }

  | `Inherit _ -> assert false


let def_of_atd is_shallow (loc, (name, param, an), x) =
  let ocaml_predef = Ag_ocaml.get_ocaml_predef `Validate an in
  let doc = Ag_doc.get_doc loc an in
  let o =
    match as_abstract x with
        Some (loc2, an2) ->
          (match Ag_ocaml.get_ocaml_module_and_t `Validate name an with
               None -> None
             | Some (types_module, main_module, ext_name) ->
                 let args = List.map (fun s -> `Tvar (loc, s)) param in
                 Some (`External
                         (loc, name, args,
                          `External (types_module, main_module, ext_name),
                          (Ag_validate.get_validator an2, false))
                      )
          )
      | None -> Some (mapping_of_expr is_shallow x)
  in
  {
    def_loc = loc;
    def_name = name;
    def_param = param;
    def_value = o;
    def_arepr = `Def { Ag_ocaml.ocaml_predef = ocaml_predef;
                       ocaml_ddoc = doc; };
    def_brepr = (None, false);
  }

let fill_def_tbl defs l =
  List.iter (
    function `Type (loc, (name, param, an), x) -> Hashtbl.add defs name x
  ) l

let init_def_tbl () =
  Hashtbl.create 100

let make_def_tbl l =
  let defs = init_def_tbl () in
  fill_def_tbl defs l;
  defs

let make_def_tbl2 l =
  let defs = init_def_tbl () in
  List.iter (fun (is_rec, l) -> fill_def_tbl defs l) l;
  defs

let defs_of_atd_module_gen is_shallow l =
  List.map (function `Type def -> def_of_atd is_shallow def) l

let defs_of_atd_module l =
  let defs = make_def_tbl l in
  let is_shallow = make_is_shallow defs in
  defs_of_atd_module_gen is_shallow l

let defs_of_atd_modules l =
  let defs = make_def_tbl2 l in
  let is_shallow = make_is_shallow defs in
  List.map (fun (is_rec, l) -> (is_rec, defs_of_atd_module_gen is_shallow l)) l
