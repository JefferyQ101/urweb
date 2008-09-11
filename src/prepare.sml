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

structure Prepare :> PREPARE = struct

open Cjr

fun prepString (e, ss, n) =
    case #1 e of
        EPrim (Prim.String s) =>
        SOME (s :: ss, n)
      | EFfiApp ("Basis", "strcat", [e1, e2]) =>
        (case prepString (e1, ss, n) of
             NONE => NONE
           | SOME (ss, n) => prepString (e2, ss, n))
      | EFfiApp ("Basis", "sqlifyInt", [e]) =>
        SOME ("$" ^ Int.toString (n + 1) ^ "::int8" :: ss, n + 1)
      | EFfiApp ("Basis", "sqlifyFloat", [e]) =>
        SOME ("$" ^ Int.toString (n + 1) ^ "::float8" :: ss, n + 1)
      | EFfiApp ("Basis", "sqlifyString", [e]) =>
        SOME ("$" ^ Int.toString (n + 1) ^ "::text" :: ss, n + 1)
      | EFfiApp ("Basis", "sqlifyBool", [e]) =>
        SOME ("$" ^ Int.toString (n + 1) ^ "::bool" :: ss, n + 1)
      | ECase (e,
               [((PCon (_, PConFfi {mod = "Basis", con = "True", ...}, _), _),
                 (EPrim (Prim.String "TRUE"), _)),
                ((PCon (_, PConFfi {mod = "Basis", con = "False", ...}, _), _),
                 (EPrim (Prim.String "FALSE"), _))],
               _) => SOME ("$" ^ Int.toString (n + 1) ^ "::bool" :: ss, n + 1)

      | _ => NONE

fun prepExp (e as (_, loc), sns) =
    case #1 e of
        EPrim _ => (e, sns)
      | ERel _ => (e, sns)
      | ENamed _ => (e, sns)
      | ECon (_, _, NONE) => (e, sns)
      | ECon (dk, pc, SOME e) =>
        let
            val (e, sns) = prepExp (e, sns)
        in
            ((ECon (dk, pc, SOME e), loc), sns)
        end
      | ENone t => (e, sns)
      | ESome (t, e) =>
        let
            val (e, sns) = prepExp (e, sns)
        in
            ((ESome (t, e), loc), sns)
        end
      | EFfi _ => (e, sns)
      | EFfiApp (m, x, es) =>
        let
            val (es, sns) = ListUtil.foldlMap prepExp sns es
        in
            ((EFfiApp (m, x, es), loc), sns)
        end
      | EApp (e1, es) =>
        let
            val (e1, sns) = prepExp (e1, sns)
            val (es, sns) = ListUtil.foldlMap prepExp sns es
        in
            ((EApp (e1, es), loc), sns)
        end

      | ERecord (rn, xes) =>
        let
            val (xes, sns) = ListUtil.foldlMap (fn ((x, e), sns) =>
                                                   let
                                                       val (e, sns) = prepExp (e, sns)
                                                   in
                                                       ((x, e), sns)
                                                   end) sns xes
        in
            ((ERecord (rn, xes), loc), sns)
        end
      | EField (e, s) =>
        let
            val (e, sns) = prepExp (e, sns)
        in
            ((EField (e, s), loc), sns)
        end

      | ECase (e, pes, ts) =>
        let
            val (e, sns) = prepExp (e, sns)
            val (pes, sns) = ListUtil.foldlMap (fn ((p, e), sns) =>
                                                   let
                                                       val (e, sns) = prepExp (e, sns)
                                                   in
                                                       ((p, e), sns)
                                                   end) sns pes
        in
            ((ECase (e, pes, ts), loc), sns)
        end

      | EError (e, t) =>
        let
            val (e, sns) = prepExp (e, sns)
        in
            ((EError (e, t), loc), sns)
        end

      | EWrite e =>
        let
            val (e, sns) = prepExp (e, sns)
        in
            ((EWrite e, loc), sns)
        end
      | ESeq (e1, e2) =>
        let
            val (e1, sns) = prepExp (e1, sns)
            val (e2, sns) = prepExp (e2, sns)
        in
            ((ESeq (e1, e2), loc), sns)
        end
      | ELet (x, t, e1, e2) =>
        let
            val (e1, sns) = prepExp (e1, sns)
            val (e2, sns) = prepExp (e2, sns)
        in
            ((ELet (x, t, e1, e2), loc), sns)
        end

      | EQuery {exps, tables, rnum, state, query, body, initial, ...} =>
        (case prepString (query, [], 0) of
             NONE => (e, sns)
           | SOME (ss, n) =>
             ((EQuery {exps = exps, tables = tables, rnum = rnum,
                       state = state, query = query, body = body,
                       initial = initial, prepared = SOME (#2 sns)}, loc),
              ((String.concat (rev ss), n) :: #1 sns, #2 sns + 1)))

      | EDml {dml, ...} =>
        (case prepString (dml, [], 0) of
             NONE => (e, sns)
           | SOME (ss, n) =>
             ((EDml {dml = dml, prepared = SOME (#2 sns)}, loc),
              ((String.concat (rev ss), n) :: #1 sns, #2 sns + 1)))

fun prepDecl (d as (_, loc), sns) =
    case #1 d of
        DStruct _ => (d, sns)
      | DDatatype _ => (d, sns)
      | DDatatypeForward _ => (d, sns)
      | DVal (x, n, t, e) =>
        let
            val (e, sns) = prepExp (e, sns)
        in
            ((DVal (x, n, t, e), loc), sns)
        end
      | DFun (x, n, xts, t, e) =>
        let
            val (e, sns) = prepExp (e, sns)
        in
            ((DFun (x, n, xts, t, e), loc), sns)
        end
      | DFunRec fs =>
        let
            val (fs, sns) = ListUtil.foldlMap (fn ((x, n, xts, t, e), sns) =>
                                                  let
                                                      val (e, sns) = prepExp (e, sns)
                                                  in
                                                      ((x, n, xts, t, e), sns)
                                                  end) sns fs
        in
            ((DFunRec fs, loc), sns)
        end

      | DTable _ => (d, sns)
      | DDatabase _ => (d, sns)
      | DPreparedStatements _ => (d, sns)

fun prepare (ds, ps) =
    let
        val (ds, (sns, _)) = ListUtil.foldlMap prepDecl ([], 0) ds
    in
        ((DPreparedStatements (rev sns), ErrorMsg.dummySpan) :: ds, ps)
    end

end
