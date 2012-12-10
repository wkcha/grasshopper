
type ident = Form.ident
let mk_ident = Form.mk_ident
module IdMap = Form.IdMap
module IdSet = Form.IdSet

(* the next pointer *)
let pts = mk_ident "sl_pts"

(*
type term =
  | Const of ident
  | Next of ident * ident
*)

type form =
  | Emp
  | Eq of ident * ident
  | PtsTo of ident * ident
  | List of ident * ident
  | SepConj of form list
  | BoolConst of bool
  | Not of form
  | And of form list
  | Or of form list

(* TODO translation to lolli:
 * tricky part is the scope of the quantifier -> looli does not have this explicitely,
 * (1) maybe we can have an intermediate step with a new AST
 * (2) interprete the comments as scope for the quantified variable (ugly hack)
 *)

let exists = "exists"
let forall = "forall"

let mk_exists f = Form.Comment (exists, f)
let mk_forall f = Form.Comment (forall, f)

let cst = Form.mk_const
let reachWoT a b c = Axioms.reach pts a b c
let reachWo a b c = reachWoT (cst a) (cst b) (cst c)
let reach a b = reachWo a b b
let mk_domain d v = Form.mk_pred d [v]

let one_and_rest lst =
  let rec process acc1 acc2 lst = match lst with
    | x :: xs -> process ((x, acc2 @ xs) :: acc1) (x :: acc2) xs
    | [] -> acc1
  in
    process [] [] lst

let to_lolli domain_name f =
  let v = Axioms.var1 in
  let rec process domain f = match f with
    | BoolConst b -> Form.mk_and [Form.BoolConst(b); process domain Emp]
    | Eq (id1, id2) -> Form.mk_and [Form.mk_eq (cst id1) (cst id2); process domain Emp]
    | Emp -> mk_forall (Form.mk_not (mk_domain domain v))
    | PtsTo (id1, id2) ->
      Form.mk_and [
        Form.mk_eq (Form.mk_app pts [cst id1]) (cst id2) ;
        mk_forall (Form.mk_equiv (Form.mk_eq (cst id1) (cst id2)) (mk_domain domain v))
      ]
    | List (id1, id2) ->
      Form.mk_and [
        reach id1 id2;
        mk_forall (
          Form.mk_equiv (
            Form.mk_and [
              reachWoT (cst id1) v (cst id2);
              Form.mk_not (Form.mk_eq v (cst id2))
            ]; )
          (mk_domain domain v) )
      ]
    | SepConj forms ->
      let ds = List.map (fun _ -> Form.fresh_ident (fst domain)) forms in
      let dsP = List.map (fun d -> mk_domain d v) ds in
      let translated = List.map2 process ds forms in
      let d = mk_domain domain v in
      let sepration =
        mk_forall (
          Form.mk_and (
            (Form.mk_implies d (Form.mk_or dsP))
            :: (List.map (fun (x, xs) -> Form.mk_implies x (Form.mk_and (d :: (List.map Form.mk_not xs)))) (one_and_rest dsP))
          )
        )
      in
        Form.mk_and (sepration :: translated)
    | Not form -> Form.mk_not (process domain form)
    | And forms -> Form.mk_and (List.map (process domain) forms)
    | Or forms -> Form.mk_or (List.map (process domain) forms)
  in
    process (Form.fresh_ident domain_name) f

let nnf f =
  let rec process negate f = match f with
    | Form.BoolConst b -> Form.BoolConst (negate <> b)
    | Form.Pred _ as p -> if negate then Form.mk_not p else p
    | Form.Eq _ as eq -> if negate then Form.mk_not eq else eq
    | Form.Not form -> process (not negate) form
    | Form.And forms ->
      let forms2 = List.map (process negate) forms in
        if negate then Form.mk_or forms2
        else Form.mk_and forms2
    | Form.Or forms -> 
      let forms2 = List.map (process negate) forms in
        if negate then Form.mk_and forms2
        else Form.mk_or forms2
    | Form.Comment (c, form) ->
      let form2 = process negate form in
      let c2 =
        if negate && c = exists then forall
        else if negate && c = forall then exists
        else c
      in
        Form.mk_comment c2 form2
  in
    process false f

(* assumes no quantifier alternation *)
let skolemize f =
  let fresh () = cst (Form.fresh_ident "SkolemCst") in
  let rec process subst f = match f with
    | Form.BoolConst _ as b -> b
    | Form.Eq _ | Form.Pred _ -> Form.subst subst f
    | Form.Not form -> Form.mk_not (process subst form)
    | Form.And forms -> Form.mk_and (List.map (process subst) forms) 
    | Form.Or forms -> Form.mk_or (List.map (process subst) forms)
    | Form.Comment (c, form) ->
        if c = exists then
          let subst2 =
            IdSet.fold
              (fun v acc -> IdMap.add v (fresh ()) acc) 
              (Form.fv form)
              subst
          in
            process subst2 form
        else if c = forall then 
          let vs = Form.fv form in
          let subst2 = IdSet.fold IdMap.remove vs subst in
            Form.mk_comment c (process subst2 form)
        else 
          Form.mk_comment c (process subst form)
  in
    process IdMap.empty f

(* pull the axioms at the top level.
 * assumes: nnf, skolemized
 *)
let equisat_with_topLvl_axioms f =
  let fresh () = Form.mk_pred (Form.fresh_ident "equisat") [] in
  let rec process f = match f with
    | Form.BoolConst _ | Form.Eq _ | Form.Pred _ -> (f, [])
    | Form.Not f2 -> 
      let (f3, acc) = process f2 in
        (Form.mk_not f3, acc)
    | Form.And forms -> 
      let forms2, accs = List.split (List.map process forms) in
        (Form.mk_and forms2, List.flatten accs)
    | Form.Or forms ->
      let forms2, accs = List.split (List.map process forms) in
        (Form.mk_or forms2, List.flatten accs)
    | Form.Comment (c, form) ->
        if c = exists then
          failwith "f has not been skolemized"
        else if c = forall then 
          let p = fresh () in
          let part1 = Form.mk_or [Form.mk_not p; form] in
          let part2 = Form.mk_or [skolemize (nnf (Form.mk_not f)); p] in
            (p, [part1; part2])
        else 
          let (f2, acc) = process form in
            (Form.mk_comment c f2, acc)
  in
    let (f2, acc) = process f in
      Form.mk_and (f2 :: acc)
