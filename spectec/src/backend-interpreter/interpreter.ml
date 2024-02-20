open Reference_interpreter
open Ds
open Al
open Ast
open Al_util
open Construct
open Print
open Util
open Source
open Printf

let fail_on_instr msg instr =
  (sprintf "%s: %s @%s" msg
    (structured_string_of_instr instr) (string_of_region instr.at))
  |> failwith

let fail_on_expr msg expr =
  (sprintf "%s: %s @%s" msg
    (structured_string_of_expr expr) (string_of_region expr.at))
  |> failwith

let fail_on_path msg path =
  (sprintf "%s: %s @%s" msg
    (structured_string_of_path path) (string_of_region path.at))
  |> failwith

let check_i32_const = function
  | CaseV ("CONST", [ CaseV ("I32", []); NumV (n) ]) ->
    let n' = Z.logand (Z.of_int64 0xFFFF_FFFFL) n in
    CaseV ("CONST", [ CaseV ("I32", []); NumV (n') ])
  | v -> v
let rec is_true = function
  | BoolV true -> true
  | ListV a -> Array.for_all is_true !a
  | _ -> false

let is_matrix matrix =
  match matrix with
  | [] -> true  (* Empty matrix is considered a valid matrix *)
  | row :: rows -> List.for_all (fun r -> List.length row = List.length r) rows

let transpose matrix =
  assert (is_matrix matrix);
  let rec transpose' = function
    | [] -> []
    | [] :: _ -> []
    | (x :: xs) :: xss ->
      let new_row = (x :: List.map List.hd xss) in
      let new_rows = transpose' (xs :: List.map List.tl xss) in
      new_row :: new_rows in
  transpose' matrix

(* helper functions for recursive type *)

(* null *)
let null = caseV ("NULL", [ optV (Some (listV [||])) ])
let nonull = caseV ("NULL", [ optV None ])
(* abstract heap types for null *)
let none = nullary "NONE"
let nofunc = nullary "NOFUNC"
let noextern = nullary "NOEXTERN"


let match_ref_type v1 v2 =
  let rt1 = Construct.al_to_ref_type v1 in
  let rt2 = Construct.al_to_ref_type v2 in
  Match.match_ref_type [] rt1 rt2

let match_heap_type v1 v2 =
  let ht1 = Construct.al_to_heap_type v1 in
  let ht2 = Construct.al_to_heap_type v2 in
  Match.match_ref_type [] (Types.Null, ht1) (Types.Null, ht2)

(* Expression *)

let rec create_sub_al_context names iter env =
  let option_name_to_list name = lookup_env name env |> unwrap_optv |> Option.to_list in
  let name_to_list name = lookup_env name env |> unwrap_listv_to_list in
  let length_to_list l = List.init l al_of_int in

  let name_to_values name =
    match iter with
    | Opt -> option_name_to_list name
    | ListN (e_n, Some n') when name = n' ->
      eval_expr env e_n
      |> al_to_int
      |> length_to_list
    | _ -> name_to_list name
  in

  names
  |> List.map name_to_values
  |> transpose
  |> List.map (fun vs -> List.fold_right2 Env.add names vs env)

and access_path env base path =
  match path.it with
  | IdxP e' ->
    let a = base |> unwrap_listv_to_array in
    let i = eval_expr env e' |> al_to_int in
    begin try Array.get a i with
    | Invalid_argument _ ->
      fail_on_path
        (sprintf "Failed Array.get on base %s and index %s"
          (string_of_value base) (string_of_int i))
        path
    end
  | SliceP (e1, e2) ->
    let a = base |> unwrap_listv_to_array in
    let i1 = eval_expr env e1 |> al_to_int in
    let i2 = eval_expr env e2 |> al_to_int in
    Array.sub a i1 i2 |> listV
  | DotP (str, _) -> (
    match base with
    | FrameV (_, StrV r) -> Record.find str r
    | StoreV s -> Record.find str !s
    | StrV r -> Record.find str r
    | v ->
      fail_on_path
        (sprintf "Base %s is not a record" (string_of_value v))
        path)

and replace_path env base path v_new =
  match path.it with
  | IdxP e' ->
    let a = unwrap_listv_to_array base |> Array.copy in
    let i = eval_expr env e' |> al_to_int in
    Array.set a i v_new;
    listV a
  | SliceP (e1, e2) ->
    let a = unwrap_listv_to_array base |> Array.copy in
    let i1 = eval_expr env e1 |> al_to_int in
    let i2 = eval_expr env e2 |> al_to_int in
    Array.blit (unwrap_listv_to_array v_new) 0 a i1 i2;
    listV a
  | DotP (str, _) ->
    let r =
      match base with
      | FrameV (_, StrV r) -> r
      | StoreV s -> !s
      | StrV r -> r
      | v ->
        fail_on_path
          (sprintf "Base %s is not a record" (string_of_value v))
          path
    in
    let r_new = Record.clone r in
    Record.replace str v_new r_new;
    strV r_new

and eval_expr env expr =
  match expr.it with
  (* Value *)
  | NumE i -> numV i
  (* Numeric Operation *)
  | UnE (MinusOp, inner_e) -> eval_expr env inner_e |> al_to_z |> Z.neg |> numV
  | UnE (NotOp, e) -> eval_expr env e |> al_to_bool |> not |> boolV
  | BinE (op, e1, e2) ->
    (match op, eval_expr env e1, eval_expr env e2 with
    | AddOp, NumV i1, NumV i2 -> Z.add i1 i2 |> numV
    | SubOp, NumV i1, NumV i2 -> Z.sub i1 i2 |> numV
    | MulOp, NumV i1, NumV i2 -> Z.mul i1 i2 |> numV
    | DivOp, NumV i1, NumV i2 -> Z.div i1 i2 |> numV
    | ExpOp, NumV i1, NumV i2 -> Z.pow i1 (Z.to_int i2) |> numV
    | AndOp, BoolV b1, BoolV b2 -> boolV (b1 && b2)
    | OrOp, BoolV b1, BoolV b2 -> boolV (b1 || b2)
    | ImplOp, BoolV b1, BoolV b2 -> boolV (not b1 || b2)
    | EquivOp, BoolV b1, BoolV b2 -> boolV (b1 = b2)
    | EqOp, v1, v2 -> boolV (v1 = v2)
    | NeOp, v1, v2 -> boolV (v1 <> v2)
    | LtOp, v1, v2 -> boolV (v1 < v2)
    | GtOp, v1, v2 -> boolV (v1 > v2)
    | LeOp, v1, v2 -> boolV (v1 <= v2)
    | GeOp, v1, v2 -> boolV (v1 >= v2)
    | _ -> fail_on_expr "Invalid BinE" expr)
  (* Function Call *)
  | CallE (fname, el) ->
    (match dsl_function_call fname (List.map (eval_expr env) el) with
    | Some v -> v
    | _ -> raise Exception.MissingReturnValue
    )
  (* Data Structure *)
  | ListE el -> List.map (eval_expr env) el |> listV_of_list
  | CatE (e1, e2) ->
    let a1 = eval_expr env e1 |> unwrap_listv_to_array in
    let a2 = eval_expr env e2 |> unwrap_listv_to_array in
    Array.append a1 a2 |> listV
  | LenE e ->
    eval_expr env e |> unwrap_listv_to_array |> Array.length |> Z.of_int |> numV
  | StrE r ->
    r |> Record.map string_of_kwd (eval_expr env) |> strV
  | AccE (e, p) ->
    let base = eval_expr env e in
    access_path env base p
  | ExtE (e1, ps, e2, dir) ->
    let rec extend ps base =
      match ps with
      | path :: rest -> access_path env base path |> extend rest |> replace_path env base path
      | [] ->
        let v = eval_expr env e2 |> unwrap_listv_to_array in
        let a_copy = base |> unwrap_listv_to_array |> Array.copy in
        let a_new =
          match dir with
          | Front -> Array.append v a_copy
          | Back -> Array.append a_copy v
        in
        listV a_new
    in
    eval_expr env e1 |> extend ps
  | UpdE (e1, ps, e2) ->
    let rec replace ps base =
      match ps with
      | path :: rest -> access_path env base path |> replace rest |> replace_path env base path
      | [] -> eval_expr env e2 in
    eval_expr env e1 |> replace ps
  | CaseE ((tag, _), el) -> caseV (tag, List.map (eval_expr env) el) |> check_i32_const
  | OptE opt -> Option.map (eval_expr env) opt |> optV
  | TupE el -> List.map (eval_expr env) el |> tupV
  (* Context *)
  | ArityE e ->
    (match eval_expr env e with
    | LabelV (v, _) -> v
    | FrameV (Some v, _) -> v
    | FrameV _ -> numV Z.zero
    | _ -> fail_on_expr "Not a context" expr (* Due to AL validation, unreachable *))
  | FrameE (e1, e2) ->
    let v1 = Option.map (eval_expr env) e1 in
    let v2 = eval_expr env e2 in
    (match v1, v2 with
    | (Some (NumV _)|None), StrV _ -> FrameV (v1, v2)
    (* Due to AL validation unreachable *)
    | _ -> fail_on_expr "Invalid frame" expr)
  | GetCurFrameE -> WasmContext.get_current_frame ()
  | LabelE (e1, e2) ->
    let v1 = eval_expr env e1 in
    let v2 = eval_expr env e2 in
    LabelV (v1, v2)
  | GetCurLabelE -> WasmContext.get_current_label ()
  | GetCurContextE -> WasmContext.get_current_context ()
  | ContE e ->
    (match eval_expr env e with
    | LabelV (_, vs) -> vs
    | _ -> fail_on_expr "Not a label" expr)
  | VarE name -> lookup_env name env
  (* Optimized getter for simple IterE(VarE, ...) *)
  | IterE ({ it = VarE name; _ }, [name'], _) when name = name' ->
    lookup_env name env
  (* Optimized getter for list init *)
  | IterE (e1, [], ListN (e2, None)) ->
    let v = eval_expr env e1 in
    let i = eval_expr env e2 |> al_to_int in
    if i > 1024 * 64 * 1024 (* 1024 pages *) then
      (* TODO: pop context? *)
      raise Exception.OutOfMemory
    else
      Array.make i v |> listV
  | IterE (inner_e, ids, iter) ->
    let vs =
      env
      |> create_sub_al_context ids iter
      |> List.map (fun env' -> eval_expr env' inner_e)
    in

    (match vs, iter with
    | [], Opt -> optV None
    | [v], Opt -> Option.some v |> optV
    | l, _ -> listV_of_list l)
  | InfixE (e1, _, e2) -> TupV [ eval_expr env e1; eval_expr env e2 ]
  (* condition *)
  | ContextKindE ((kind, _), e) ->
    (match kind, eval_expr env e with
    | "frame", FrameV _ -> boolV true
    | "label", LabelV _ -> boolV true
    | _ -> boolV false)
  | IsDefinedE e ->
    (match eval_expr env e with
    | OptV (Some _) -> boolV true
    | OptV _ -> boolV false
    | _ -> fail_on_expr "Not an option" expr)
  | IsCaseOfE (e, (expected_tag, _)) ->
    (match eval_expr env e with
    | CaseV (tag, _) -> boolV (expected_tag = tag)
    | _ -> boolV false)
  (* TODO : This sohuld be replaced with executing the validation algorithm *)
  | IsValidE e ->
    let valid_lim k = function
      | TupV [ NumV n; NumV m ] -> n <= m && m <= k
      | _ -> false in
    (match eval_expr env e with
    (* valid_tabletype *)
    | TupV [ lim; _ ] -> valid_lim (Z.of_int 0xffffffff) lim |> boolV
    (* valid_memtype *)
    | CaseV ("I8", [ lim ]) -> valid_lim (Z.of_int 0x10000) lim |> boolV
    (* valid_other *)
    | _ -> fail_on_expr "TODO: Currently, we are already validating tabletype and memtype" expr)
  | HasTypeE (e, s) ->

    (* type definition *)

    let addr_refs = [
      "REF.I31_NUM"; "REF.STRUCT_ADDR"; "REF.ARRAY_ADDR";
      "REF.FUNC_ADDR"; "REF.HOST_ADDR"; "REF.EXTERN";
    ] in
    let packed_types = [ "I8"; "I16" ] in
    let num_types = [ "I32"; "I64"; "F32"; "F64" ] in
    let vec_types = [ "V128"; ] in
    let abs_heap_types = [
      "ANY"; "EQ"; "I31"; "STRUCT"; "ARRAY"; "NONE"; "FUNC";
      "NOFUNC"; "EXTERN"; "NOEXTERN"
    ] in

    (* check type *)

    (match eval_expr env e with
    (* addrref *)
    | CaseV (ar, _) when List.mem ar addr_refs->
      boolV (s = "addrref" || s = "ref" || s = "val")
    (* nul *)
    | CaseV ("REF.NULL", _) ->
      boolV (s = "nul" || s = "ref" || s = "val")
    (* numtype *)
    | CaseV (nt, []) when List.mem nt num_types ->
      boolV (s = "numtype" || s = "valtype")
    | CaseV (vt, []) when List.mem vt vec_types ->
      boolV (s = "vectype" || s = "valtype")
    (* valtype *)
    | CaseV ("REF", _) ->
      boolV (s = "reftype" || s = "valtype")
    (* absheaptype *)
    | CaseV (aht, []) when List.mem aht abs_heap_types ->
      boolV (s = "absheaptype" || s = "heaptype")
    (* deftype *)
    | CaseV ("DEF", [ _; _ ]) ->
      boolV (s = "deftype" || s = "heaptype")
    (* typevar *)
    | CaseV ("_IDX", [ _ ]) ->
      boolV (s = "heaptype" || s = "typevar")
    (* heaptype *)
    | CaseV ("REC", [ _ ]) ->
      boolV (s = "heaptype" || s = "typevar")
    (* packedtype *)
    | CaseV (pt, []) when List.mem pt packed_types ->
      boolV (s = "packedtype" || s = "storagetype")
    | v ->
      fail_on_expr
        (sprintf "%s doesn't have type %s" (string_of_value v) s)
        expr)
  | MatchE (e1, e2) ->
    let v1 = eval_expr env e1 in
    let v2 = eval_expr env e2 in
    match_ref_type v1 v2 |> boolV
  | _ -> fail_on_expr "No interpreter for" expr

(* Assignment *)

and has_same_keys re rv =
  let k1 = Record.keys re |> List.map string_of_kwd |> List.sort String.compare in
  let k2 = Record.keys rv |> List.sort String.compare in
  k1 = k2

and merge_envs_with_grouping default_env envs =
  let merge env acc =
    let f _ v1 = function
      | ListV arr ->
          Array.append [| v1 |] !arr |> listV |> Option.some
      | OptV None -> Option.some v1 |> optV |> Option.some
      | _ -> failwith "Unreachable merge"
    in
    Env.union f env acc
  in
  List.fold_right merge envs default_env

and assign lhs rhs env =
  match lhs.it, rhs with
  | VarE name, v -> Env.add name v env
  | IterE ({ it = VarE n; _ }, _, List), ListV _ -> (* Optimized assign for simple IterE(VarE, ...) *)
    Env.add n rhs env
  | IterE (e, _, iter), _ ->
    let new_env, default_rhs, rhs_list =
      match iter, rhs with
      | (List | List1), ListV arr -> env, listV [||], Array.to_list !arr
      | ListN (expr, None), ListV arr ->
        let length = Array.length !arr |> Z.of_int |> numV in
        assign expr length env, listV [||], Array.to_list !arr
      | Opt, OptV opt -> env, optV None, Option.to_list opt
      | ListN (_, Some _), ListV _ ->
        sprintf "Invalid iter %s with rhs %s"
          (string_of_iter iter)
          (string_of_value rhs)
        |> failwith
      | _, _ ->
        fail_on_expr
          (sprintf "Invalid assignment on value %s" (string_of_value rhs))
          lhs
    in

    let default_env =
      Al.Free.free_expr e
      |> List.map (fun n -> n, default_rhs)
      |> List.to_seq
      |> Env.of_seq
    in

    List.map (fun v -> assign e v Env.empty) rhs_list
      |> merge_envs_with_grouping default_env
      |> Env.union (fun _ _ v -> Some v) new_env
  | InfixE (lhs1, _, lhs2), TupV [rhs1; rhs2] ->
    env |> assign lhs1 rhs1 |> assign lhs2 rhs2
  | TupE lhs_s, TupV rhs_s
    when List.length lhs_s = List.length rhs_s ->
    List.fold_right2 assign lhs_s rhs_s env
  | ListE lhs_s, ListV rhs_s
    when List.length lhs_s = Array.length !rhs_s ->
    List.fold_right2 assign lhs_s (Array.to_list !rhs_s) env
  | CaseE ((lhs_tag, _), lhs_s), CaseV (rhs_tag, rhs_s)
    when lhs_tag = rhs_tag && List.length lhs_s = List.length rhs_s ->
    List.fold_right2 assign lhs_s rhs_s env
  | OptE (Some lhs), OptV (Some rhs) -> assign lhs rhs env
  (* Assumption: e1 is the assign target *)
  | BinE (binop, e1, e2), NumV m ->
    let invop =
      match binop with
      | AddOp -> Z.sub
      | SubOp -> Z.add
      | MulOp -> Z.div
      | DivOp -> Z.mul
      | _ -> failwith "Invalid binop for lhs of assignment" in
    let v = eval_expr env e2 |> al_to_z |> invop m |> numV in
    assign e1 v env
  | CatE (e1, e2), ListV vs -> assign_split e1 e2 !vs env
  | StrE r1, StrV r2 when has_same_keys r1 r2 ->
    Record.fold (fun k v acc -> (Record.find (string_of_kwd k) r2 |> assign v) acc) r1 env
  | _, v ->
    fail_on_expr
      (sprintf "Invalid assignment on value %s" (string_of_value v))
      lhs

and assign_split ep es vs env =
  let len = Array.length vs in
  let prefix_len, suffix_len =
    let get_length e = match e.it with
    | ListE es -> List.length es |> Option.some
    | IterE (_, _, ListN (e, None)) -> eval_expr env e |> al_to_int |> Option.some
    | _ -> None in
    match get_length ep, get_length es with
    | None, None -> failwith "Unreachable: nondeterministic list split"
    | Some l, None -> l, len - l
    | None, Some l -> len - l, l
    | Some l1, Some l2 -> l1, l2 in
  assert (prefix_len >= 0 && suffix_len >= 0 && prefix_len + suffix_len = len);
  let prefix = Array.sub vs 0 prefix_len |> listV in
  let suffix = Array.sub vs prefix_len suffix_len |> listV in
  env |> assign ep prefix |> assign es suffix


(* Instruction *)


and create_context (name: string) (args: value list) : AlContext.ctx =

  let algo = lookup_algo name in
  let params = get_param algo in
  let body = get_body algo in

  if List.length args <> List.length params then
    failwith ("Argument number mismatch for algorithm " ^ name);

  let env =
    Env.empty
    |> add_store
    |> List.fold_right2 assign params args
  in

  AlContext.Al (name, body, env, None, 0)

and dsl_function_call (fname: string) (args: value list): value option =
  (* Module & Runtime *)
  if bound_func fname then
    call_algo fname args
  (* Numerics *)
  else if Numerics.mem fname then
    Some (Numerics.call_numerics fname args)
  (* HARDCODE: hardcoded validation rule *)
  else if fname = "ref_type_of" then (
    assert (List.length args = 1);

    let rt =
      match List.hd args with
      (* null *)
      | CaseV ("REF.NULL", [ ht ]) ->
        if match_heap_type none ht then
          CaseV ("REF", [ null; none])
        else if match_heap_type nofunc ht then
          CaseV ("REF", [ null; nofunc])
        else if match_heap_type noextern ht then
          CaseV ("REF", [ null; noextern])
        else
          List.hd args
          |> string_of_value
          |> sprintf "Invalid null reference: %s"
          |> failwith
      (* i31 *)
      | CaseV ("REF.I31_NUM", [ _ ]) ->
        CaseV ("REF", [ nonull; nullary "I31"])
      (* struct *)
      | CaseV ("REF.STRUCT_ADDR", [ NumV i ]) ->
        let e =
          accE (
            accE (
              accE (
                varE "s",
                dotP ("STRUCT", "struct")
              ),
              idxP (numE i)
            ),
            dotP ("TYPE", "type")
          )
        in
        (* TODO: remove hack *)
        let dt = eval_expr (add_store Env.empty) e in
        CaseV ("REF", [ nonull; dt])
      (* array *)
      | CaseV ("REF.ARRAY_ADDR", [ NumV i ]) ->
        let e =
          accE (
            accE (
              accE (
                varE "s",
                dotP ("ARRAY", "array")
              ),
              idxP (numE i)
            ),
            dotP ("TYPE", "type")
          )
        in
        (* TODO: remove hack *)
        let dt = eval_expr (add_store Env.empty) e in
        CaseV ("REF", [ nonull; dt])
      (* func *)
      | CaseV ("REF.FUNC_ADDR", [ NumV i ]) ->
        let e =
          accE (
            accE (
              accE (
                varE "s",
                dotP ("FUNC", "func")
              ),
              idxP (numE i)
            ),
            dotP ("TYPE", "type")
          )
        in
        (* TODO: remove hack *)
        let dt = eval_expr (add_store Env.empty) e in
        CaseV ("REF", [ nonull; dt])
      (* host *)
      | CaseV ("REF.HOST_ADDR", [ _ ]) ->
        CaseV ("REF", [ nonull; nullary "ANY"])
      (* extern *)
      (* TODO: check null *)
      | CaseV ("REF.EXTERN", [ _ ]) ->
        CaseV ("REF", [ nonull; nullary "EXTERN"])
      | _ -> failwith "Invalid arguments for $ref_type_of"
    in
    Some rt
  ) else
    sprintf "Invalid DSL function call: %s" fname |> failwith

and is_builtin = function
  | "PRINT" | "PRINT_I32" | "PRINT_I64" | "PRINT_F32" | "PRINT_F64" | "PRINT_I32_F32" | "PRINT_F64_F64" -> true
  | _ -> false

and call_builtin name =
  let local x =
    match call_algo "local" [ numV (Z.of_int x) ] with
    | Some v -> v
    | _ -> failwith "Builtin doesn't return a value"
  in
  let as_const ty = function
  | CaseV ("CONST", [ CaseV (ty', []) ; n ])
  | OptV (Some (CaseV ("CONST", [ CaseV (ty', []) ; n ]))) when ty = ty' -> n
  | v -> failwith ("Not " ^ ty ^ ".CONST: " ^ string_of_value v) in
  match name with
  | "PRINT" -> print_endline "- print: ()"
  | "PRINT_I32" ->
    local 0
    |> as_const "I32"
    |> al_to_int32
    |> I32.to_string_s
    |> sprintf "- print_i32: %s"
    |> print_endline
  | "PRINT_I64" ->
    local 0
    |> as_const "I64"
    |> al_to_int64
    |> I64.to_string_s
    |> sprintf "- print_i64: %s"
    |> print_endline
  | "PRINT_F32" ->
    local 0
    |> as_const "F32"
    |> al_to_float32
    |> F32.to_string
    |> sprintf "- print_f32: %s"
    |> print_endline
  | "PRINT_F64" ->
    local 0
    |> as_const "F64"
    |> al_to_float64
    |> F64.to_string
    |> sprintf "- print_f64: %s"
    |> print_endline
  | "PRINT_I32_F32" ->
    let i32 = local 0 |> as_const "I32" |> al_to_int32 |> I32.to_string_s in
    let f32 = local 1 |> as_const "F32" |> al_to_float32 |> F32.to_string in
    sprintf "- print_i32_f32: %s %s" i32 f32 |> print_endline
  | "PRINT_F64_F64" ->
    let f64 = local 0 |> as_const "F64" |> al_to_float64 |> F64.to_string in
    let f64' = local 1 |> as_const "F64" |> al_to_float64 |> F64.to_string in
    sprintf "- print_f64_f64: %s %s" f64 f64' |> print_endline
  | name ->
    ("Invalid builtin function: " ^ name) |> failwith

and execute (ctx: AlContext.t) (wasm_instr: value) : AlContext.t =
  match wasm_instr with
  | CaseV ("REF.NULL", [ ht ]) when !version = 3 ->
    (* TODO: remove hack *)
    let mm = call_algo "moduleinst" [] |> Option.get in
    let dummy_rt = CaseV ("REF", [ null; ht ]) in

    (* substitute heap type *)
    (match call_algo "inst_reftype" [ mm; dummy_rt ] with
    | Some (CaseV ("REF", [ n; ht' ])) when n = null ->
      CaseV ("REF.NULL", [ ht' ]) |> WasmContext.push_value
    | _ -> raise Exception.MissingReturnValue);
    ctx
  | CaseV ("REF.NULL", _)
  | CaseV ("CONST", _)
  | CaseV ("VVCONST", _) -> WasmContext.push_value wasm_instr; ctx
  | CaseV (name, []) when is_builtin name -> call_builtin name; ctx
  | CaseV (fname, args) -> create_context fname args :: ctx
  | v ->
    string_of_value v
    |> sprintf "Executing invalid value: %s"
    |> failwith


and step_instr (ctx: AlContext.t) (env: value Env.t) (instr: instr) : AlContext.t =
  (*
  AL_Context.get_name () |> print_endline;
  string_of_instr instr |> sprintf "[INSTR]: %s" |> prerr_endline;
  WasmContext.string_of_context_stack () |> print_endline;
  AlContext.string_of_context_stack () |> print_endline;
  print_endline "";
  *)

  (Info.find instr.note).covered <- true;

  match instr.it with
  (* Block instruction *)
  | IfI (e, il1, il2) ->
    if eval_expr env e |> is_true then
      AlContext.add_instrs il1 ctx
    else
      AlContext.add_instrs il2 ctx
  | EitherI (il1, il2) ->
    (try
      let ctx' = AlContext.add_instrs il1 ctx in
      run ctx'
    with
    | Exception.MissingReturnValue
    | Exception.OutOfMemory ->
      AlContext.add_instrs il2 ctx
    )
  | AssertI _ -> ctx (*assert (eval_cond env c);*)
  | PushI e ->
    (match eval_expr env e with
    | FrameV _ as v -> WasmContext.push_context (v, [], [])
    | ListV vs -> Array.iter WasmContext.push_value !vs
    | v -> WasmContext.push_value v
    );
    ctx
  | PopI ({ it = FrameE _; _ }) ->
    WasmContext.pop_context () |> ignore;
    ctx
  | PopI ({ it = IterE ({ it = VarE name; _ }, [name'], ListN (e', None)); _ }) when name = name' ->
    let i = eval_expr env e' |> al_to_int in
    let v =
      List.init i (fun _ -> WasmContext.pop_value ())
      |> List.rev
      |> listV_of_list
    in
    AlContext.update_env name v ctx
  | PopI e ->
    (match e.it, WasmContext.pop_value () with
    | CaseE (("CONST", _), [{ it = VarE nt; _ }; { it = VarE name; _ }]), CaseV ("CONST", [ ty; v ]) ->
      ctx
      |> AlContext.update_env nt ty
      |> AlContext.update_env name v
    | CaseE (("CONST", _), [tyE; { it = VarE name; _ }]), CaseV ("CONST", [ ty; v ]) ->
      assert (eval_expr env tyE = ty);
      AlContext.update_env name v ctx
    | VarE name, v -> AlContext.update_env name v ctx
    | CaseE (("VVCONST", _), [tyE; { it = VarE name; _ }]), CaseV ("VVCONST", [ ty; v ]) ->
      assert (eval_expr env tyE = ty);
      AlContext.update_env name v ctx
    (* TODO remove this *)
    | FrameE _, FrameV _ -> ctx
    | (_, h) ->
      fail_on_instr
        (sprintf "Invalid pop for value %s: " (structured_string_of_value h))
        instr
    )
  | PopAllI ({ it = IterE ({ it = VarE name; _ }, [name'], List); _ }) when name = name' ->
    let rec pop_all acc =
      if WasmContext.get_value_stack () |> List.length > 0 then
        WasmContext.pop_value () :: acc |> pop_all
      else
        acc
    in
    let v = pop_all [] |> listV_of_list in
    AlContext.update_env name v ctx
  | PopAllI _ -> fail_on_instr "Invalid pop" instr
  | LetI (e1, e2) ->
    let new_env =
      ctx
      |> AlContext.get_env
      |> assign e1 (eval_expr env e2)
    in
    AlContext.set_env new_env ctx
  | PerformI (f, el) ->
    dsl_function_call f (List.map (eval_expr env) el) |> ignore;
    ctx
  | TrapI -> raise Exception.Trap
  | NopI -> ctx
  | ReturnI None -> AlContext.pop_context ctx
  | ReturnI (Some e) ->
    AlContext.set_return_value (eval_expr env e) (AlContext.pop_context ctx)
  | ExecuteI e -> AlContext.Execute (eval_expr env e) :: ctx
  | ExecuteSeqI e ->
    let ctx' =
      e
      |> eval_expr env
      |> unwrap_listv_to_list
      |> List.map (fun v -> AlContext.Execute v)
    in
    ctx'@ctx
  | EnterI (e1, e2, il) ->
    let v1 = eval_expr env e1 in
    let v2 = eval_expr env e2 in
    WasmContext.push_context (v1, [], unwrap_listv_to_list v2);
    ctx
    |> AlContext.increase_depth
    |> AlContext.add_instrs il
  | ExitI ->
    WasmContext.pop_context () |> ignore;
    AlContext.decrease_depth ctx
  | ReplaceI (e1, { it = IdxP e2; _ }, e3) ->
    let a = eval_expr env e1 |> unwrap_listv_to_array in
    let i = eval_expr env e2 |> al_to_int in
    let v = eval_expr env e3 in
    Array.set a i v;
    ctx
  | ReplaceI (e1, { it = SliceP (e2, e3); _ }, e4) ->
    let a1 = eval_expr env e1 |> unwrap_listv_to_array in (* dest *)
    let i1 = eval_expr env e2 |> al_to_int in   (* start index *)
    let i2 = eval_expr env e3 |> al_to_int in   (* length *)
    let a2 = eval_expr env e4 |> unwrap_listv_to_array in (* src *)
    assert (Array.length a2 = i2);
    Array.blit a2 0 a1 i1 i2;
    ctx
  | ReplaceI (e1, { it = DotP (s, _); _ }, e2) ->
    (match eval_expr env e1 with
    | StrV r ->
      let v = eval_expr env e2 in
      Record.replace s v r
    | _ -> fail_on_expr "Not a Record" e1
    );
    ctx
  | AppendI (e1, e2) ->
    let a = eval_expr env e1 |> unwrap_listv in
    let v = eval_expr env e2 in
    a := Array.append !a [|v|];
    ctx
  | _ -> fail_on_instr "No interpreter for" instr


and step_wasm (ctx: AlContext.t) : AlContext.t =
  let open WasmContext in
  execute ctx (pop_instr ())


and step : AlContext.t -> AlContext.t = function
  | AlContext.Al (_, [], _, _, 0) :: ctx -> ctx
  | AlContext.Al (_, [], _, _, n) :: ctx -> AlContext.Wasm n :: ctx
  | AlContext.Al (name, h :: t, env, rv, n) :: ctx ->
    let new_ctx = AlContext.Al (name, t, env, rv, n) :: ctx in
    step_instr new_ctx env h
  | AlContext.Wasm 0 :: ctx -> ctx
  | AlContext.Execute v :: ctx -> execute ctx v
  | ctx -> step_wasm ctx
  

and run (ctx: AlContext.t) : AlContext.t =
  if not (AlContext.is_empty ctx) then
    run (step ctx)
  else ctx

(* Algorithm *)

and call_algo (name: string) (args: value list) : value option =
  let ctx = create_context name args :: AlContext.empty in
  AlContext.get_return_value (run ctx)

(* Entry *)

let instantiate (args: value list) : value =
  WasmContext.init_context ();
  match call_algo "instantiate" args with
  | Some module_inst -> module_inst
  | None -> failwith "Instantiation doesn't return module instance"
let invoke (args: value list) : value =
  WasmContext.init_context ();
  match call_algo "invoke" args with
  | Some v -> v
  | None -> failwith "Invocation doesn't return any values"
