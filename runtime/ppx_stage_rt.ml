open Migrate_parsetree
open Ast_405

open Asttypes
open Parsetree
open Ast_helper

type ident = string
module IdentMap = Map.Make (struct type t = ident let compare = compare end)

type _ tag = ..
module type T = sig 
  type a
  type _ tag += Tag : a tag
  val name : string
end
type 'a variable = (module T with type a = 'a)

let fresh_variable (type aa) name : aa variable =
  (module struct 
     type a = aa
     type _ tag += Tag : a tag
     let name = name
   end)

let variable_name (type a) (v : a variable) =
  let module V = (val v) in
  V.name

type (_, _) cmp_result = Eq : ('a, 'a) cmp_result | NotEq : ('a, 'b) cmp_result
let cmp_variable (type a) (type b) : a variable -> b variable -> (a, b) cmp_result =
  fun (module A) (module B) ->
  match A.Tag with B.Tag -> Eq | _ -> NotEq

let eq_variable (type a) (type b) : a variable -> b variable -> bool =
  fun v1 v2 -> match cmp_variable v1 v2 with Eq -> true | NotEq -> false

module VarMap (C : sig type 'a t end) : sig
  type t
  val empty : t
  val add : t -> 'a variable -> 'a C.t -> t
  val lookup : t -> 'a variable -> 'a C.t option
end = struct
  type entry = Entry : 'b variable * 'b C.t -> entry
  type t = entry list
  let empty = []
  let add m v x = (Entry (v, x) :: m)
  let rec lookup : type a . t -> a variable -> a C.t option =
    fun m v ->
    match m with
    | [] -> None
    | (Entry (v', x')) :: m ->
       match cmp_variable v v' with
       | Eq -> Some x'
       | NotEq -> lookup m v
end

module Environ = VarMap (struct type 'a t = 'a end)

module Renaming = struct

  type entry = Entry : {
      var : 'a variable;
      mutable aliases : ident list
    } -> entry
  type t = entry list IdentMap.t


  let empty = IdentMap.empty

  let with_renaming
        (var : 'a variable)
        (f : t -> expression)
        (ren : t) : expression =
    let entry = Entry { var ; aliases = [] } in
    let vname = variable_name var in
    let shadowed = try IdentMap.find vname ren with Not_found -> [] in
    let result = f (IdentMap.add vname (entry :: shadowed) ren) in
    match entry with
    | Entry { var; aliases = []} -> result
    | Entry { var; aliases } ->
       Exp.let_ Nonrecursive
         (aliases |> List.map (fun alias ->
           Vb.mk
             (Pat.var (Location.mknoloc alias))
             (Exp.ident (Location.mknoloc (Longident.Lident vname)))
         ))
         result

  let lookup (var : 'a variable) (ren : t) =
    let vname = variable_name var in
    let fail () =
      failwith ("Variable " ^ vname ^ " used out of scope") in

    let rec create_alias n =
      let alias = vname ^ "''" ^ string_of_int n in
      if IdentMap.mem alias ren then
        create_alias (n+1)
      else
        alias in

    let rec find_or_create_alias = function
      | [] -> fail ()
      | (Entry ({var = var'; aliases} as entry)) :: _ when eq_variable var var' ->
         (* Even though it was unbound when created, an alias may be shadowed here *)
         begin match List.find (fun v -> not (IdentMap.mem v ren)) aliases with
         | alias ->
            alias
         | exception Not_found ->
            let alias = create_alias 1 in
            entry.aliases <- alias :: aliases;
            alias
         end
      | _ :: rest -> find_or_create_alias rest in

    let bound_name =
      match IdentMap.find vname ren with
      | exception Not_found -> fail ()
      | [] -> assert false
      | (Entry { var = var' ; _ }) :: _ when eq_variable var var' ->
         (* present, not shadowed *)
         vname
      | _ :: shadowed ->
         find_or_create_alias shadowed in
    Exp.ident (Location.mknoloc (Longident.Lident bound_name))
end

type 'a t = Ppx_stage_internal of (Environ.t -> 'a) * (Renaming.t -> expression)

let mangle id n =
  id ^ "''" ^ string_of_int n


let compute_variable v =
  (fun env ->
      match Environ.lookup env v with
      | Some x -> x
      | None ->
         failwith ("Variable " ^ variable_name v ^ " used out of scope"))

let source_variable = Renaming.lookup

let of_variable v =
  Ppx_stage_internal
    (compute_variable v,
     source_variable v)

let compute (Ppx_stage_internal (c, s)) = c
let source (Ppx_stage_internal (c, s)) = s

let run f = compute f Environ.empty

let print ppf f =
  Pprintast.expression ppf (Versions.((migrate ocaml_405 ocaml_current).copy_expression (source f Renaming.empty)))








type binding_site = Binder of int | Context of int

type scope = binding_site IdentMap.t

type hole = int

type analysis_env = {
  bindings : scope;
  fresh_binder : unit -> binding_site;
  fresh_hole : unit -> hole;
  hole_table : (hole, scope * expression) Hashtbl.t
}

let rec analyse_exp env { pexp_desc; pexp_loc; pexp_attributes } =
  analyse_attributes pexp_attributes;
  { pexp_desc = analyse_exp_desc env pexp_loc pexp_desc;
    pexp_loc;
    pexp_attributes }

and analyse_exp_desc env loc = function
  | Pexp_extension ({txt = "e"; loc}, code) ->
     let code =
       match code with
       | PStr [ {pstr_desc=Pstr_eval (e, _); _} ] ->
          e
       | _ ->
          raise (Location.(Error (error ~loc ("[%e] expects an expression")))) in
     let h = env.fresh_hole () in
     Hashtbl.add env.hole_table h (env.bindings, code);
     Pexp_ident { txt = Lident ("," ^ string_of_int h); loc }
  | Pexp_ident { txt = Lident id; loc } as e ->
     begin match IdentMap.find id env.bindings with
     | Context c ->
        Pexp_ident { txt = Lident (";" ^ string_of_int c); loc }
     | Binder _ -> e
     | exception Not_found -> e
     end
  | Pexp_ident { txt = (Ldot _ | Lapply _); _ } as e -> e
  | Pexp_constant _ as e -> e
  | Pexp_let (isrec, vbs, body) ->
     let env' = List.fold_left (fun env {pvb_pat; _} ->
       analyse_pat env pvb_pat) env vbs in
     let bindings_env =
       match isrec with Recursive -> env' | Nonrecursive -> env in
     Pexp_let
       (isrec,
        vbs |> List.map (fun vb ->
          analyse_attributes vb.pvb_attributes;
          { vb with pvb_expr = analyse_exp bindings_env vb.pvb_expr }),
        analyse_exp env' body)
  | Pexp_function cases ->
     Pexp_function (List.map (analyse_case env) cases)
  | Pexp_fun (lbl, opt, pat, body) ->
     let env' = analyse_pat env pat in
     Pexp_fun (lbl, analyse_exp_opt env opt, pat, analyse_exp env' body)
  | Pexp_apply (fn, args) ->
     Pexp_apply
       (analyse_exp env fn,
        args |> List.map (fun (lbl, e) -> lbl, analyse_exp env e))
  | Pexp_match (exp, cases) ->
     Pexp_match
       (analyse_exp env exp,
        List.map (analyse_case env) cases)
  | Pexp_try (exp, cases) ->
     Pexp_try
       (analyse_exp env exp,
        List.map (analyse_case env) cases)
  | Pexp_tuple exps ->
     Pexp_tuple (List.map (analyse_exp env) exps)
  | Pexp_construct (ctor, exp) ->
     Pexp_construct (ctor, analyse_exp_opt env exp)
  | Pexp_variant (lbl, exp) ->
     Pexp_variant (lbl, analyse_exp_opt env exp)
  | Pexp_record (fields, base) ->
     Pexp_record (List.map (fun (l, e) -> l, analyse_exp env e) fields, analyse_exp_opt env base)
  | Pexp_field (e, field) ->
     Pexp_field (analyse_exp env e, field)
  | Pexp_setfield (e, field, v) ->
     Pexp_setfield (analyse_exp env e, field, analyse_exp env v)
  | Pexp_array exps ->
     Pexp_array (List.map (analyse_exp env) exps)
  | Pexp_ifthenelse (cond, ift, iff) ->
     Pexp_ifthenelse (analyse_exp env cond, analyse_exp env ift, analyse_exp_opt env iff)
  | Pexp_sequence (e1, e2) ->
     Pexp_sequence (analyse_exp env e1, analyse_exp env e2)
  | Pexp_while (cond, body) ->
     Pexp_while (analyse_exp env cond, analyse_exp env body)
  | Pexp_for (pat, e1, e2, dir, body) ->
     let env' = analyse_pat env pat in
     Pexp_for (pat, analyse_exp env e1, analyse_exp env e2, dir, analyse_exp env' body)
  (* several missing... *)
       

  | _ -> raise (Location.(Error (error ~loc ("expression not supported in staged code"))))

and analyse_exp_opt env = function
  | None -> None
  | Some e -> Some (analyse_exp env e)

and analyse_pat env { ppat_desc; ppat_loc; ppat_attributes } =
  analyse_attributes ppat_attributes;
  analyse_pat_desc env ppat_loc ppat_desc

and analyse_pat_desc env loc = function
  | Ppat_any -> env
  | Ppat_var v -> analyse_pat_desc env loc (Ppat_alias (Pat.any (), v))
  | Ppat_alias (pat, v) ->
     let env = analyse_pat env pat in
     { env with bindings = IdentMap.add v.txt (env.fresh_binder ()) env.bindings }
  | Ppat_constant _ -> env
  | Ppat_interval _ -> env
  | Ppat_tuple pats -> List.fold_left analyse_pat env pats
  | Ppat_construct (loc, None) -> env
  | Ppat_construct (loc, Some pat) -> analyse_pat env pat
  | _ -> raise (Location.(Error (error ~loc ("pattern not supported in staged code"))))

and analyse_case env {pc_lhs; pc_guard; pc_rhs} =
  let env' = analyse_pat env pc_lhs in
  { pc_lhs;
    pc_guard = analyse_exp_opt env' pc_guard;
    pc_rhs = analyse_exp env' pc_rhs }

and analyse_attributes = function
| [] -> ()
| ({ loc; txt }, PStr []) :: rest ->
   analyse_attributes rest
| ({ loc; txt }, _) :: _ ->
   raise (Location.(Error (error ~loc ("attribute " ^ txt ^ " not supported in staged code"))))


let analyse_binders (context : int IdentMap.t) (e : expression) :
    expression * (hole, scope * expression) Hashtbl.t =
  let hole_table = Hashtbl.create 20 in
  let next_hole = ref 0 in
  let fresh_hole () =
    incr next_hole;
    !next_hole in
  let next_binder = ref 0 in
  let fresh_binder () =
    incr next_binder;
    Binder (!next_binder) in
  let bindings = IdentMap.map (fun c -> Context c) context in
  let e' = analyse_exp { bindings; fresh_binder; fresh_hole; hole_table } e in
  e', hole_table


let is_hole = function
  | { txt = Longident.Lident v; _ } -> v.[0] == ','
  | _ -> false

let hole_id v : hole =
  assert (is_hole v);
  match v with
  | { txt = Longident.Lident v; _ } ->
     int_of_string (String.sub v 1 (String.length v - 1))
  | _ -> assert false

open Ast_mapper
type substitutable =
| SubstContext of int
| SubstHole of hole

let substitute_holes (e : expression) (f : substitutable -> expression) =
  let expr mapper pexp =
    match pexp.pexp_desc with
    | Pexp_ident { txt = Lident v; loc } ->
       let id () = int_of_string (String.sub v 1 (String.length v - 1)) in
       (match v.[0] with
       | ',' -> f (SubstHole (id ()))
       | ';' -> f (SubstContext (id ()))
       | _ -> pexp)
    | _ -> default_mapper.expr mapper pexp in
  let mapper = { default_mapper with expr } in
  mapper.expr mapper e
