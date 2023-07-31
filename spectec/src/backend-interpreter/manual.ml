open Al.Ast

let exec_expr_const =
  Algo ("exec_expr_const", [IterE (NameE (N "instr"), [N "instr"], List)], [ReturnI (Some (ConstructE ("CONST", dummy_note, [ConstructE ("I32", dummy_note, []); Reference_interpreter.I32.of_int_s 42 |> Reference_interpreter.I32.to_bits |> Int64.of_int32 |> Int64.logand 0x0000_0000_ffff_ffffL |> Expr.num])))])

let manual_algos =
  [exec_expr_const] |> List.map Transpile.app_remover
