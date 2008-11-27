(* Copyright (c) 2008, Adam Chlipala
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * - The names of contributors may not be used to endorse or promote products
 *   derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *)

structure ESpecialize :> ESPECIALIZE = struct

open Core

structure E = CoreEnv
structure U = CoreUtil

type skey = exp

structure K = struct
type ord_key = exp list
val compare = Order.joinL U.Exp.compare
end

structure KM = BinaryMapFn(K)
structure IM = IntBinaryMap
structure IS = IntBinarySet

val freeVars = U.Exp.foldB {kind = fn (_, xs) => xs,
                            con = fn (_, _, xs) => xs,
                            exp = fn (bound, e, xs) =>
                                     case e of
                                         ERel x =>
                                         if x >= bound then
                                             IS.add (xs, x - bound)
                                         else
                                             xs
                                       | _ => xs,
                            bind = fn (bound, b) =>
                                      case b of
                                          U.Exp.RelE _ => bound + 1
                                        | _ => bound}
                           0 IS.empty

val isPoly = U.Decl.exists {kind = fn _ => false,
                            con = fn _ => false,
                            exp = fn ECAbs _ => true
                                   | _ => false,
                            decl = fn _ => false}

fun positionOf (v : int, ls) =
    let
        fun pof (pos, ls) =
            case ls of
                [] => raise Fail "Defunc.positionOf"
              | v' :: ls' =>
                if v = v' then
                    pos
                else
                    pof (pos + 1, ls')
    in
        pof (0, ls)
    end

fun squish fvs =
    U.Exp.mapB {kind = fn k => k,
                con = fn _ => fn c => c,
                exp = fn bound => fn e =>
                                     case e of
                                         ERel x =>
                                         if x >= bound then
                                             ERel (positionOf (x - bound, fvs) + bound)
                                         else
                                             e
                                       | _ => e,
                bind = fn (bound, b) =>
                          case b of
                              U.Exp.RelE _ => bound + 1
                            | _ => bound}
               0

type func = {
     name : string,
     args : int KM.map,
     body : exp,
     typ : con,
     tag : string
}

type state = {
     maxName : int,
     funcs : func IM.map,
     decls : (string * int * con * exp * string) list
}

fun id x = x
fun default (_, x, st) = (x, st)

fun specialize' file =
    let
        fun default' (_, fs) = fs

        fun actionableExp (e, fs) =
            case e of
                ERecord xes =>
                foldl (fn (((CName s, _), e, _), fs) =>
                          if s = "Action" orelse s = "Link" then
                              let
                                  fun findHead (e, _) =
                                      case e of
                                          ENamed n => IS.add (fs, n)
                                        | EApp (e, _) => findHead e
                                        | _ => fs
                              in
                                  findHead e
                              end
                          else
                              fs
                        | (_, fs) => fs)
                fs xes
              | _ => fs

        val actionable =
            U.File.fold {kind = default',
                         con = default',
                         exp = actionableExp,
                         decl = default'}
            IS.empty file

        fun bind (env, b) =
            case b of
                U.Decl.RelE xt => xt :: env
              | _ => env

        fun exp (env, e, st : state) =
            let
                fun getApp e =
                    case e of
                        ENamed f => SOME (f, [])
                      | EApp (e1, e2) =>
                        (case getApp (#1 e1) of
                             NONE => NONE
                           | SOME (f, xs) => SOME (f, xs @ [e2]))
                      | _ => NONE
            in
                case getApp e of
                    NONE => (e, st)
                  | SOME (f, xs) =>
                    case IM.find (#funcs st, f) of
                        NONE => (e, st)
                      | SOME {name, args, body, typ, tag} =>
                        let
                            val functionInside = U.Con.exists {kind = fn _ => false,
                                                               con = fn TFun _ => true
                                                                      | CFfi ("Basis", "transaction") => true
                                                                      | _ => false}
                            val loc = ErrorMsg.dummySpan

                            fun findSplit (xs, typ, fxs, fvs) =
                                case (#1 typ, xs) of
                                    (TFun (dom, ran), e :: xs') =>
                                    if functionInside dom then
                                        findSplit (xs',
                                                   ran,
                                                   e :: fxs,
                                                   IS.union (fvs, freeVars e))
                                    else
                                        (rev fxs, xs, fvs)
                                  | _ => (rev fxs, xs, fvs)

                            val (fxs, xs, fvs) = findSplit (xs, typ, [], IS.empty)

                            val fxs' = map (squish (IS.listItems fvs)) fxs

                            fun firstRel () =
                                case fxs' of
                                    (ERel _, _) :: _ => true
                                  | _ => false
                        in
                            if firstRel ()
                               orelse List.all (fn (ERel _, _) => true
                                                 | _ => false) fxs' then
                                (e, st)
                            else
                                case KM.find (args, fxs') of
                                    SOME f' =>
                                    let
                                        val e = (ENamed f', loc)
                                        val e = IS.foldr (fn (arg, e) => (EApp (e, (ERel arg, loc)), loc))
                                                         e fvs
                                        val e = foldl (fn (arg, e) => (EApp (e, arg), loc))
                                                      e xs
                                    in
                                        (*Print.prefaces "Brand new (reuse)"
                                                       [("e'", CorePrint.p_exp env e)];*)
                                        (#1 e, st)
                                    end
                                  | NONE =>
                                    let
                                        fun subBody (body, typ, fxs') =
                                            case (#1 body, #1 typ, fxs') of
                                                (_, _, []) => SOME (body, typ)
                                              | (EAbs (_, _, _, body'), TFun (_, typ'), x :: fxs'') =>
                                                let
                                                    val body'' = E.subExpInExp (0, x) body'
                                                in
                                                    subBody (body'',
                                                             typ',
                                                             fxs'')
                                                end
                                              | _ => NONE
                                    in
                                        case subBody (body, typ, fxs') of
                                            NONE => (e, st)
                                          | SOME (body', typ') =>
                                            let
                                                val f' = #maxName st
                                                val args = KM.insert (args, fxs', f')
                                                val funcs = IM.insert (#funcs st, f, {name = name,
                                                                                      args = args,
                                                                                      body = body,
                                                                                      typ = typ,
                                                                                      tag = tag})
                                                val st = {
                                                    maxName = f' + 1,
                                                    funcs = funcs,
                                                    decls = #decls st
                                                }

                                                (*val () = Print.prefaces "specExp"
                                                                        [("f", CorePrint.p_exp env (ENamed f, loc)),
                                                                         ("f'", CorePrint.p_exp env (ENamed f', loc)),
                                                                         ("xs", Print.p_list (CorePrint.p_exp env) xs),
                                                                         ("fxs'", Print.p_list
                                                                                      (CorePrint.p_exp E.empty) fxs'),
                                                                         ("e", CorePrint.p_exp env (e, loc))]*)
                                                val (body', typ') = IS.foldl (fn (n, (body', typ')) =>
                                                                                 let
                                                                                     val (x, xt) = List.nth (env, n)
                                                                                 in
                                                                                     ((EAbs (x, xt, typ', body'),
                                                                                       loc),
                                                                                      (TFun (xt, typ'), loc))
                                                                                 end)
                                                                             (body', typ') fvs
                                                val (body', st) = specExp env st body'

                                                val e' = (ENamed f', loc)
                                                val e' = IS.foldr (fn (arg, e) => (EApp (e, (ERel arg, loc)), loc))
                                                                  e' fvs
                                                val e' = foldl (fn (arg, e) => (EApp (e, arg), loc))
                                                               e' xs
                                                (*val () = Print.prefaces "Brand new"
                                                                        [("e'", CorePrint.p_exp env e'),
                                                                         ("e", CorePrint.p_exp env (e, loc)),
                                                                         ("body'", CorePrint.p_exp env body')]*)
                                            in
                                                (#1 e',
                                                 {maxName = #maxName st,
                                                  funcs = #funcs st,
                                                  decls = (name, f', typ', body', tag) :: #decls st})
                                            end
                                    end
                        end
            end

        and specExp env = U.Exp.foldMapB {kind = id, con = default, exp = exp, bind = bind} env

        val specDecl = U.Decl.foldMapB {kind = id, con = default, exp = exp, decl = default, bind = bind}

        fun doDecl (d, (st : state, changed)) =
            let
                (*val befor = Time.now ()*)

                val funcs = #funcs st
                val funcs = 
                    case #1 d of
                        DValRec vis =>
                        foldl (fn ((x, n, c, e, tag), funcs) =>
                                  IM.insert (funcs, n, {name = x,
                                                        args = KM.empty,
                                                        body = e,
                                                        typ = c,
                                                        tag = tag}))
                              funcs vis
                      | _ => funcs

                val st = {maxName = #maxName st,
                          funcs = funcs,
                          decls = []}

                (*val () = Print.prefaces "decl" [("d", CorePrint.p_decl CoreEnv.empty d)]*)

                val (d', st) =
                    if isPoly d then
                        (d, st)
                    else
                        specDecl [] st d

                (*val () = print "/decl\n"*)

                val funcs = #funcs st
                val funcs =
                    case #1 d of
                        DVal (x, n, c, e as (EAbs _, _), tag) =>
                        IM.insert (funcs, n, {name = x,
                                              args = KM.empty,
                                              body = e,
                                              typ = c,
                                              tag = tag})
                      | DVal (_, n, _, (ENamed n', _), _) =>
                        (case IM.find (funcs, n') of
                             NONE => funcs
                           | SOME v => IM.insert (funcs, n, v))
                      | _ => funcs

                val (changed, ds) =
                    case #decls st of
                        [] => (changed, [d'])
                      | vis =>
                        (true, case d' of
                                   (DValRec vis', _) => [(DValRec (vis @ vis'), ErrorMsg.dummySpan)]
                                 | _ => [(DValRec vis, ErrorMsg.dummySpan), d'])
            in
                (*Print.prefaces "doDecl" [("d", CorePrint.p_decl E.empty d),
                                         ("t", Print.PD.string (Real.toString (Time.toReal
                                                                                   (Time.- (Time.now (), befor)))))];*)
                (ds, ({maxName = #maxName st,
                       funcs = funcs,
                       decls = []}, changed))
            end

        val (ds, (_, changed)) = ListUtil.foldlMapConcat doDecl
                                                            ({maxName = U.File.maxName file + 1,
                                                              funcs = IM.empty,
                                                              decls = []},
                                                             false)
                                                            file
    in
        (changed, ds)
    end

fun specialize file =
    let
        (*val () = Print.prefaces "Intermediate" [("file", CorePrint.p_file CoreEnv.empty file)];*)
        (*val file = ReduceLocal.reduce file*)
        val (changed, file) = specialize' file
        (*val file = ReduceLocal.reduce file
        val file = CoreUntangle.untangle file
        val file = Shake.shake file*)
    in
        (*print "Round over\n";*)
        if changed then
            let
                val file = ReduceLocal.reduce file
                val file = CoreUntangle.untangle file
                val file = Shake.shake file
            in
                (*print "Again!\n";*)
                specialize file
            end
        else
            file
    end

end
