(* OCamlScript compiler
 * Copyright (C) 2015-2016 Bloomberg Finance L.P.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(* Author: Hongbo Zhang  *)





(* Assume that functions already calculated closure correctly 
   Maybe in the future, we should add a dirty flag, to mark the calcuated 
   closure is correct or not

   Note such shaking is done in the toplevel, so that it requires us to 
   flatten the statement first 
 *)
let free_variables used_idents defined_idents = 
  object (self)
    inherit Js_fold.fold as super
    val defined_idents = defined_idents
    val used_idents = used_idents 
    method! variable_declaration st = 
      match st with 
      | { ident; value = None}
        -> 
        {< defined_idents = Ident_set.add ident defined_idents >}
      | { ident; value = Some v}
        -> 
        {< defined_idents = Ident_set.add ident defined_idents >} # expression v
    method! ident id = 
      if Ident_set.mem id defined_idents then self
      else {<used_idents = Ident_set.add id used_idents >}
    method! expression exp = 

      match exp.expression_desc with
      | Fun(_,_, env)
      (** a optimization to avoid walking into funciton again
          if it's already comuted
      *)
        ->
        {< used_idents = Ident_set.union (Js_fun_env.get_bound env) used_idents  >}

      | _
        ->
        super#expression exp

    method get_depenencies = 
      Ident_set.diff used_idents defined_idents
    method get_used_idents = used_idents
    method get_defined_idents = defined_idents 
  end 

let free_variables_of_statement used_idents defined_idents st = 
  ((free_variables used_idents defined_idents)#statement st) # get_depenencies

let free_variables_of_expression used_idents defined_idents st = 
  ((free_variables used_idents defined_idents)#expression st) # get_depenencies

let rec no_side_effect (x : J.expression)  = 
  match x.expression_desc with 
  | Var _ -> true 
  | Access (a,b) -> no_side_effect a && no_side_effect b 
  | Str (b,_) -> b
  | Fun _ -> true
  | Number _ -> true (* Can be refined later *)
  | Array (xs,_mutable_flag)  
    ->
      (** create [immutable] block,
          does not really mean that this opreation itself is [pure].
          
          the block is mutable does not mean this operation is non-pure
       *)
      List.for_all no_side_effect  xs 
  | Seq (a,b) -> no_side_effect a && no_side_effect b 
  | _ -> false 

let no_side_effect_expression (x : J.expression) = no_side_effect x 

let no_side_effect init = 
  object (self)
    inherit Js_fold.fold as super
    val no_side_effect = init
    method get_no_side_effect = no_side_effect

    method! statement s = 
      if not no_side_effect then self else 
      match s.statement_desc with 
      | Throw _ ->  {< no_side_effect = false>}
      | _ -> super#statement s 
    method! list f x = 
      if not self#get_no_side_effect then self else super#list f x 
    method! expression s = 
      if not no_side_effect then self
      else  {< no_side_effect = no_side_effect_expression s >}

        (** only expression would cause side effec *)
  end
let no_side_effect_statement st = ((no_side_effect true)#statement st)#get_no_side_effect

(* TODO: generate [fold2] 
   This make sense, for example:
   {[
   let string_of_formatting_gen : type a b c d e f .
   (a, b, c, d, e, f) formatting_gen -> string =
   fun formatting_gen -> match formatting_gen with
   | Open_tag (Format (_, str)) -> str
   | Open_box (Format (_, str)) -> str

   ]}
 *)
let rec eq_expression (x : J.expression) (y : J.expression) = 
  match x.expression_desc, y.expression_desc with 
  | Number (Int i) , Number (Int j)   -> i = j 
  | Number (Float i), Number (Float j) -> false (* TODO *)
  | Math  (name00,args00), Math(name10,args10) -> 
    name00 = name10 && eq_expression_list args00 args10 
  | Access (a0,a1), Access(b0,b1) -> 
    eq_expression a0 b0 && eq_expression a1 b1
  | Call (a0,args00,_), Call(b0,args10,_) ->
    eq_expression a0 b0 &&  eq_expression_list args00 args10
  | Var (Id i), Var (Id j) ->
    Ident.same i j
  | Bin (op0, a0,b0) , Bin(op1,a1,b1) -> 
    op0 = op1 && eq_expression a0 a1 && eq_expression b0 b1
  | _, _ -> false 

and eq_expression_list xs ys =
  let rec aux xs ys =
    match xs,ys with
    | [], [] -> true
    | [], _  -> false 
    | _ , [] -> false
    | x::xs, y::ys -> eq_expression x y && aux xs ys 
  in
  aux xs ys

and eq_statement (x : J.statement) (y : J.statement) = 
  match x.statement_desc, y.statement_desc with 
  | Exp a, Exp b 
  | Return { return_value = a ; _} , Return { return_value = b; _} ->
    eq_expression a b
  | _, _ ->
    false 

let rev_flatten_seq (x : J.expression) = 
  let rec aux acc (x : J.expression) : J.block = 
    match x.expression_desc with
    | Seq(a,b) -> aux (aux acc a) b 
    | _ -> { statement_desc = Exp x; comment = None} :: acc in
  aux [] x 

(* TODO: optimization, 
    counter the number to know if needed do a loop gain instead of doing a diff 
 *)

let rev_toplevel_flatten block = 
  let rec aux  acc (xs : J.block) : J.block  = 
    match xs with 
    | [] -> acc
    | {statement_desc =
       Variable (
       {ident_info = {used_stats = Dead_pure } ; _} 
       | {ident_info = {used_stats = Dead_non_pure}; value = None })
     } :: xs -> aux acc xs 
    | {statement_desc = Block b; _ } ::xs -> aux (aux acc b ) xs 

    | x :: xs -> aux (x :: acc) xs  in
  aux [] block