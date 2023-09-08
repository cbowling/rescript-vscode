open SharedTypes
open CompletionNewTypes
open CompletionsNewTypesCtxPath

let flattenLidCheckDot ?(jsx = true) ~(completionContext : CompletionContext.t)
    (lid : Longident.t Location.loc) =
  (* Flatten an identifier keeping track of whether the current cursor
     is after a "." in the id followed by a blank character.
     In that case, cut the path after ".". *)
  let cutAtOffset =
    let idStart = Loc.start lid.loc in
    match completionContext.positionContext.whitespaceAfterCursor with
    | Some '.' ->
      if fst completionContext.positionContext.beforeCursor = fst idStart then
        Some (snd completionContext.positionContext.beforeCursor - snd idStart)
      else None
    | _ -> None
  in
  Utils.flattenLongIdent ~cutAtOffset ~jsx lid.txt

let ctxPathFromCompletionContext (completionContext : CompletionContext.t) =
  completionContext.ctxPath

(** This is for when you want a context path for an expression, without necessarily wanting 
    to do completion in that expression. For instance when completing patterns 
    `let {<com>} = someRecordVariable`, we want the context path to `someRecordVariable` to 
    be able to figure out the type we're completing in the pattern. *)
let rec exprToContextPathInner (e : Parsetree.expression) =
  match e.pexp_desc with
  | Pexp_constant (Pconst_string _) -> Some CString
  | Pexp_constant (Pconst_integer _) -> Some CInt
  | Pexp_constant (Pconst_float _) -> Some CFloat
  | Pexp_construct ({txt = Lident ("true" | "false")}, None) -> Some CBool
  | Pexp_array exprs ->
    Some
      (CArray
         (match exprs with
         | [] -> None
         | exp :: _ -> exprToContextPath exp))
  | Pexp_ident {txt = Lident ("|." | "|.u")} -> None
  | Pexp_ident {txt} -> Some (CId (Utils.flattenLongIdent txt, Value))
  | Pexp_field (e1, {txt = Lident name}) -> (
    match exprToContextPath e1 with
    | Some contextPath ->
      Some (CRecordFieldAccess {recordCtxPath = contextPath; fieldName = name})
    | _ -> None)
  | Pexp_field (_, {txt = Ldot (lid, name)}) ->
    (* Case x.M.field ignore the x part *)
    Some
      (CRecordFieldAccess
         {
           recordCtxPath = CId (Utils.flattenLongIdent lid, Module);
           fieldName = name;
         })
  | Pexp_send (e1, {txt}) -> (
    match exprToContextPath e1 with
    | None -> None
    | Some contexPath ->
      Some (CObj {objectCtxPath = contexPath; propertyName = txt}))
  | Pexp_apply
      ( {pexp_desc = Pexp_ident {txt = Lident ("|." | "|.u")}},
        [
          (_, lhs);
          (_, {pexp_desc = Pexp_apply (d, args); pexp_loc; pexp_attributes});
        ] ) ->
    (* Transform away pipe with apply call *)
    exprToContextPath
      {
        pexp_desc = Pexp_apply (d, (Nolabel, lhs) :: args);
        pexp_loc;
        pexp_attributes;
      }
  | Pexp_apply
      ( {pexp_desc = Pexp_ident {txt = Lident ("|." | "|.u")}},
        [(_, lhs); (_, {pexp_desc = Pexp_ident id; pexp_loc; pexp_attributes})]
      ) ->
    (* Transform away pipe with identifier *)
    exprToContextPath
      {
        pexp_desc =
          Pexp_apply
            ( {pexp_desc = Pexp_ident id; pexp_loc; pexp_attributes},
              [(Nolabel, lhs)] );
        pexp_loc;
        pexp_attributes;
      }
  | Pexp_apply (e1, args) -> (
    match exprToContextPath e1 with
    | None -> None
    | Some contexPath ->
      Some (CApply {functionCtxPath = contexPath; args = args |> List.map fst}))
  | Pexp_tuple exprs ->
    let exprsAsContextPaths = exprs |> List.filter_map exprToContextPath in
    if List.length exprs = List.length exprsAsContextPaths then
      Some (CTuple exprsAsContextPaths)
    else None
  | _ -> None

and exprToContextPath (e : Parsetree.expression) =
  match
    ( Res_parsetree_viewer.hasAwaitAttribute e.pexp_attributes,
      exprToContextPathInner e )
  with
  | true, Some ctxPath -> Some (CAwait ctxPath)
  | false, Some ctxPath -> Some ctxPath
  | _, None -> None

let rec ctxPathFromCoreType ~completionContext (coreType : Parsetree.core_type)
    =
  match coreType.ptyp_desc with
  | Ptyp_constr ({txt = Lident "option"}, [innerTyp]) ->
    innerTyp
    |> ctxPathFromCoreType ~completionContext
    |> Option.map (fun innerTyp -> COption innerTyp)
  | Ptyp_constr ({txt = Lident "array"}, [innerTyp]) ->
    Some (CArray (innerTyp |> ctxPathFromCoreType ~completionContext))
  | Ptyp_constr ({txt = Lident "bool"}, []) -> Some CBool
  | Ptyp_constr ({txt = Lident "int"}, []) -> Some CInt
  | Ptyp_constr ({txt = Lident "float"}, []) -> Some CFloat
  | Ptyp_constr ({txt = Lident "string"}, []) -> Some CString
  | Ptyp_constr (lid, []) ->
    Some (CId (lid |> flattenLidCheckDot ~completionContext, Type))
  | Ptyp_tuple types ->
    let types =
      types
      |> List.map (fun (t : Parsetree.core_type) ->
             match t |> ctxPathFromCoreType ~completionContext with
             | None -> CUnknown
             | Some ctxPath -> ctxPath)
    in
    Some (CTuple types)
  | Ptyp_arrow _ -> (
    let rec loopFnTyp (ct : Parsetree.core_type) =
      match ct.ptyp_desc with
      | Ptyp_arrow (_arg, _argTyp, nextTyp) -> loopFnTyp nextTyp
      | _ -> ct
    in
    let returnType = loopFnTyp coreType in
    match ctxPathFromCoreType ~completionContext returnType with
    | None -> None
    | Some returnType -> Some (CFunction {returnType}))
  | _ -> None

let findCurrentlyLookingForInPattern ~completionContext
    (pat : Parsetree.pattern) =
  match pat.ppat_desc with
  | Ppat_constraint (_pat, typ) -> ctxPathFromCoreType ~completionContext typ
  | _ -> None

(* An expression with that's an expr hole and that has an empty cursor. TODO Explain *)
let checkIfExprHoleEmptyCursor ~(completionContext : CompletionContext.t)
    (exp : Parsetree.expression) =
  CompletionExpressions.isExprHole exp
  && CursorPosition.classifyLoc exp.pexp_loc
       ~pos:completionContext.positionContext.beforeCursor
     = EmptyLoc

let checkIfPatternHoleEmptyCursor ~(completionContext : CompletionContext.t)
    (pat : Parsetree.pattern) =
  CompletionPatterns.isPatternHole pat
  && CursorPosition.classifyLoc pat.ppat_loc
       ~pos:completionContext.positionContext.beforeCursor
     = EmptyLoc

let completePipeChain (exp : Parsetree.expression) =
  (* Complete the end of pipe chains by reconstructing the pipe chain as a single pipe,
     so it can be completed.
     Example:
      someArray->Js.Array2.filter(v => v > 10)->Js.Array2.map(v => v + 2)->
        will complete as:
      Js.Array2.map(someArray->Js.Array2.filter(v => v > 10), v => v + 2)->
  *)
  match exp.pexp_desc with
  (* When the left side of the pipe we're completing is a function application.
     Example: someArray->Js.Array2.map(v => v + 2)-> *)
  | Pexp_apply
      ( {pexp_desc = Pexp_ident {txt = Lident ("|." | "|.u")}},
        [_; (_, {pexp_desc = Pexp_apply (d, _)})] ) ->
    exprToContextPath exp |> Option.map (fun ctxPath -> (ctxPath, d.pexp_loc))
    (* When the left side of the pipe we're completing is an identifier application.
       Example: someArray->filterAllTheGoodStuff-> *)
  | Pexp_apply
      ( {pexp_desc = Pexp_ident {txt = Lident ("|." | "|.u")}},
        [_; (_, {pexp_desc = Pexp_ident _; pexp_loc})] ) ->
    exprToContextPath exp |> Option.map (fun ctxPath -> (ctxPath, pexp_loc))
  | _ -> None

let completePipe ~id (lhs : Parsetree.expression) =
  match completePipeChain lhs with
  | Some (pipe, lhsLoc) -> Some (CPipe {functionCtxPath = pipe; id; lhsLoc})
  | None -> (
    match exprToContextPath lhs with
    | Some pipe ->
      Some (CPipe {functionCtxPath = pipe; id; lhsLoc = lhs.pexp_loc})
    | None -> None)

(** Scopes *)
let rec scopePattern ~scope (pat : Parsetree.pattern) =
  match pat.ppat_desc with
  | Ppat_any -> scope
  | Ppat_var {txt; loc} -> scope |> Scope.addValue ~name:txt ~loc
  | Ppat_alias (p, asA) ->
    let scope = scopePattern p ~scope in
    scope |> Scope.addValue ~name:asA.txt ~loc:asA.loc
  | Ppat_constant _ | Ppat_interval _ -> scope
  | Ppat_tuple pl ->
    pl |> List.map (fun p -> scopePattern p ~scope) |> List.concat
  | Ppat_construct (_, None) -> scope
  | Ppat_construct (_, Some {ppat_desc = Ppat_tuple pl}) ->
    pl |> List.map (fun p -> scopePattern p ~scope) |> List.concat
  | Ppat_construct (_, Some p) -> scopePattern ~scope p
  | Ppat_variant (_, None) -> scope
  | Ppat_variant (_, Some {ppat_desc = Ppat_tuple pl}) ->
    pl |> List.map (fun p -> scopePattern p ~scope) |> List.concat
  | Ppat_variant (_, Some p) -> scopePattern ~scope p
  | Ppat_record (fields, _) ->
    fields
    |> List.map (fun (fname, p) ->
           match fname with
           | {Location.txt = Longident.Lident _fname} -> scopePattern ~scope p
           | _ -> [])
    |> List.concat
  | Ppat_array pl ->
    pl
    |> List.map (fun (p : Parsetree.pattern) -> scopePattern ~scope p)
    |> List.concat
  | Ppat_or (p1, _) -> scopePattern ~scope p1
  | Ppat_constraint (p, _coreType) -> scopePattern ~scope p
  | Ppat_type _ -> scope
  | Ppat_lazy p -> scopePattern ~scope p
  | Ppat_unpack {txt; loc} -> scope |> Scope.addValue ~name:txt ~loc
  | Ppat_exception p -> scopePattern ~scope p
  | Ppat_extension _ -> scope
  | Ppat_open (_, p) -> scopePattern ~scope p

let scopeValueBinding ~scope (vb : Parsetree.value_binding) =
  scopePattern ~scope vb.pvb_pat

let scopeValueBindings ~scope (valueBindings : Parsetree.value_binding list) =
  let newScope = ref scope in
  valueBindings
  |> List.iter (fun (vb : Parsetree.value_binding) ->
         newScope := scopeValueBinding vb ~scope:!newScope);
  !newScope

let scopeTypeKind ~scope (tk : Parsetree.type_kind) =
  match tk with
  | Ptype_variant constrDecls ->
    constrDecls
    |> List.map (fun (cd : Parsetree.constructor_declaration) ->
           scope |> Scope.addConstructor ~name:cd.pcd_name.txt ~loc:cd.pcd_loc)
    |> List.concat
  | Ptype_record labelDecls ->
    labelDecls
    |> List.map (fun (ld : Parsetree.label_declaration) ->
           scope |> Scope.addField ~name:ld.pld_name.txt ~loc:ld.pld_loc)
    |> List.concat
  | _ -> scope

let scopeTypeDeclaration ~scope (td : Parsetree.type_declaration) =
  let scope =
    scope |> Scope.addType ~name:td.ptype_name.txt ~loc:td.ptype_name.loc
  in
  scopeTypeKind ~scope td.ptype_kind

let scopeTypeDeclarations ~scope
    (typeDeclarations : Parsetree.type_declaration list) =
  let newScope = ref scope in
  typeDeclarations
  |> List.iter (fun (td : Parsetree.type_declaration) ->
         newScope := scopeTypeDeclaration td ~scope:!newScope);
  !newScope

let scopeModuleBinding ~scope (mb : Parsetree.module_binding) =
  scope |> Scope.addModule ~name:mb.pmb_name.txt ~loc:mb.pmb_name.loc

let scopeModuleDeclaration ~scope (md : Parsetree.module_declaration) =
  scope |> Scope.addModule ~name:md.pmd_name.txt ~loc:md.pmd_name.loc

let scopeValueDescription ~scope (vd : Parsetree.value_description) =
  scope |> Scope.addValue ~name:vd.pval_name.txt ~loc:vd.pval_name.loc

let scopeStructureItem ~scope (item : Parsetree.structure_item) =
  match item.pstr_desc with
  | Pstr_value (_, valueBindings) -> scopeValueBindings ~scope valueBindings
  | Pstr_type (_, typeDeclarations) ->
    scopeTypeDeclarations ~scope typeDeclarations
  | Pstr_open {popen_lid} -> scope |> Scope.addOpen ~lid:popen_lid.txt
  | Pstr_primitive vd -> scopeValueDescription ~scope vd
  | _ -> scope

let rec completeFromStructure ~(completionContext : CompletionContext.t)
    (structure : Parsetree.structure) : CompletionResult.t =
  let scope = ref completionContext.scope in
  structure
  |> Utils.findMap (fun (item : Parsetree.structure_item) ->
         let res =
           completeStructureItem
             ~completionContext:
               (CompletionContext.withScope !scope completionContext)
             item
         in
         scope := scopeStructureItem ~scope:!scope item;
         res)

and completeStructureItem ~(completionContext : CompletionContext.t)
    (item : Parsetree.structure_item) : CompletionResult.t =
  let locHasPos = completionContext.positionContext.locHasPos in
  match item.pstr_desc with
  | Pstr_value (recFlag, valueBindings) ->
    if locHasPos item.pstr_loc then
      completeValueBindings ~completionContext ~recFlag valueBindings
    else None
  | Pstr_eval _ | Pstr_primitive _ | Pstr_type _ | Pstr_typext _
  | Pstr_exception _ | Pstr_module _ | Pstr_recmodule _ | Pstr_modtype _
  | Pstr_open _ | Pstr_include _ | Pstr_attribute _ | Pstr_extension _ ->
    None
  | Pstr_class _ | Pstr_class_type _ ->
    (* These aren't relevant for ReScript *) None

and completeValueBinding ~(completionContext : CompletionContext.t)
    (vb : Parsetree.value_binding) : CompletionResult.t =
  let locHasPos = completionContext.positionContext.locHasPos in
  let bindingConstraint =
    findCurrentlyLookingForInPattern ~completionContext vb.pvb_pat
  in
  (* Always reset the context when completing value bindings,
     since they create their own context. *)
  let completionContext = CompletionContext.resetCtx completionContext in
  if locHasPos vb.pvb_pat.ppat_loc then
    (* Completing the pattern of the binding. `let {<com>} = someRecordVariable`.
       Ensure the context carries the root type of `someRecordVariable`. *)
    let completionContext =
      CompletionContext.currentlyExpectingOrTypeAtLoc ~loc:vb.pvb_expr.pexp_loc
        (exprToContextPath vb.pvb_expr)
        completionContext
    in
    completePattern ~completionContext vb.pvb_pat
  else if locHasPos vb.pvb_loc then
    (* First try completing the expression. *)
    (* A let binding expression either has the constraint of the binding,
       or an inferred constraint (if it has been compiled), or no constraint. *)
    let completionContextForExprCompletion =
      completionContext
      |> CompletionContext.currentlyExpectingOrTypeAtLoc2
           ~loc:vb.pvb_pat.ppat_loc bindingConstraint
    in
    let completedExpression =
      completeExpr ~completionContext:completionContextForExprCompletion
        vb.pvb_expr
    in
    match completedExpression with
    | Some res -> Some res
    | None ->
      (* In the binding but not in the pattern or expression means parser error recovery.
         We can still complete the pattern or expression if we have enough information. *)
      let exprHole =
        checkIfExprHoleEmptyCursor
          ~completionContext:completionContextForExprCompletion vb.pvb_expr
      in
      let patHole =
        checkIfPatternHoleEmptyCursor
          ~completionContext:completionContextForExprCompletion vb.pvb_pat
      in
      let exprCtxPath = exprToContextPath vb.pvb_expr in
      (* Try the expression. Example: `let someVar: someType = <com> *)
      if exprHole then
        let completionContext =
          completionContextForExprCompletion
          |> CompletionContext.currentlyExpectingOrTypeAtLoc
               ~loc:vb.pvb_pat.ppat_loc bindingConstraint
        in
        CompletionResult.ctxPath (CId ([], Value)) completionContext
      else if patHole then
        let completionContext =
          CompletionContext.currentlyExpectingOrTypeAtLoc
            ~loc:vb.pvb_expr.pexp_loc exprCtxPath
            completionContextForExprCompletion
        in
        CompletionResult.pattern ~prefix:"" ~completionContext
      else None
  else None

and completeValueBindings ~(completionContext : CompletionContext.t)
    ~(recFlag : Asttypes.rec_flag)
    (valueBindings : Parsetree.value_binding list) : CompletionResult.t =
  let completionContext =
    if recFlag = Recursive then
      let scopeFromBindings =
        scopeValueBindings valueBindings ~scope:completionContext.scope
      in
      CompletionContext.withScope scopeFromBindings completionContext
    else completionContext
  in
  valueBindings
  |> Utils.findMap (fun (vb : Parsetree.value_binding) ->
         completeValueBinding ~completionContext vb)

(** Completes an expression. Designed to run without pre-checking if the cursor is in the expression. *)
and completeExpr ~completionContext (expr : Parsetree.expression) :
    CompletionResult.t =
  let locHasPos = completionContext.positionContext.locHasPos in
  match expr.pexp_desc with
  (* == VARIANTS == *)
  | Pexp_construct (id, Some {pexp_desc = Pexp_tuple args; pexp_loc})
    when pexp_loc |> locHasPos ->
    (* A constructor with multiple payloads, like: `Co(true, false)` or `Somepath.Co(false, true)` *)
    args
    |> Utils.findMapWithIndex (fun itemNum (e : Parsetree.expression) ->
           completeExpr
             ~completionContext:
               {
                 completionContext with
                 ctxPath =
                   CVariantPayload
                     {
                       itemNum;
                       variantCtxPath =
                         ctxPathFromCompletionContext completionContext;
                       constructorName = Longident.last id.txt;
                     };
               }
             e)
  | Pexp_construct (id, Some payloadExpr) when payloadExpr.pexp_loc |> locHasPos
    ->
    (* A constructor with a single payload, like: `Co(true)` or `Somepath.Co(false)` *)
    completeExpr
      ~completionContext:
        {
          completionContext with
          ctxPath =
            CVariantPayload
              {
                itemNum = 0;
                variantCtxPath = ctxPathFromCompletionContext completionContext;
                constructorName = Longident.last id.txt;
              };
        }
      payloadExpr
  | Pexp_construct ({txt = Lident txt; loc}, _) when loc |> locHasPos ->
    (* A constructor, like: `Co` *)
    CompletionResult.expression ~completionContext ~prefix:txt
  | Pexp_construct (id, _) when id.loc |> locHasPos ->
    (* A path, like: `Something.Co` *)
    let lid = flattenLidCheckDot ~completionContext id in
    CompletionResult.ctxPath (CId (lid, Module)) completionContext
  (* == RECORDS == *)
  | Pexp_ident {txt = Lident prefix} when Utils.hasBraces expr.pexp_attributes
    ->
    (* An ident with braces attribute corresponds to for example `{n}`.
       Looks like a record but is parsed as an ident with braces. *)
    let prefix = if prefix = "()" then "" else prefix in
    let completionContext =
      completionContext
      |> CompletionContext.addCtxPathItem
           (CRecordField
              {
                prefix;
                seenFields = [];
                recordCtxPath = ctxPathFromCompletionContext completionContext;
              })
    in
    CompletionResult.expression ~completionContext ~prefix
  | Pexp_record ([], _) when expr.pexp_loc |> locHasPos ->
    (* No fields means we're in a record body `{}` *)
    let completionContext =
      completionContext
      |> CompletionContext.addCtxPathItem
           (CRecordField
              {
                prefix = "";
                seenFields = [];
                recordCtxPath = ctxPathFromCompletionContext completionContext;
              })
    in
    CompletionResult.expression ~completionContext ~prefix:""
  | Pexp_record (fields, _) when expr.pexp_loc |> locHasPos -> (
    (* A record with fields *)
    let seenFields =
      fields
      |> List.map (fun (fieldName, _f) -> Longident.last fieldName.Location.txt)
    in
    let fieldToComplete =
      fields
      |> Utils.findMap
           (fun
             ((fieldName, fieldExpr) :
               Longident.t Location.loc * Parsetree.expression)
           ->
             (* Complete regular idents *)
             if locHasPos fieldName.loc then
               (* Cursor in field name, complete here *)
               match fieldName with
               | {txt = Lident prefix} ->
                 CompletionResult.ctxPath
                   (CRecordField
                      {
                        prefix;
                        seenFields;
                        recordCtxPath =
                          ctxPathFromCompletionContext completionContext;
                      })
                   completionContext
               | fieldName ->
                 CompletionResult.ctxPath
                   (CId (flattenLidCheckDot ~completionContext fieldName, Value))
                   completionContext
             else
               completeExpr
                 ~completionContext:
                   (CompletionContext.addCtxPathItem
                      (CRecordFieldFollow
                         {
                           fieldName = fieldName.txt |> Longident.last;
                           recordCtxPath =
                             ctxPathFromCompletionContext completionContext;
                         })
                      completionContext)
                 fieldExpr)
    in
    match fieldToComplete with
    | None -> (
      (* Check if there's a expr hole with an empty cursor for a field.
         This means completing for an empty field `{someField: <com>}`. *)
      let fieldNameWithExprHole =
        fields
        |> Utils.findMap (fun (fieldName, fieldExpr) ->
               if checkIfExprHoleEmptyCursor ~completionContext fieldExpr then
                 Some (Longident.last fieldName.Location.txt)
               else None)
      in
      (* We found no field to complete, but we know the cursor is inside this record body.
         Check if the char to the left of the cursor is ',', if so, complete for record fields.*)
      match
        ( fieldNameWithExprHole,
          completionContext.positionContext.charBeforeNoWhitespace )
      with
      | Some fieldName, _ ->
        let completionContext =
          completionContext
          |> CompletionContext.addCtxPathItem
               (CRecordFieldFollow
                  {
                    fieldName;
                    recordCtxPath =
                      ctxPathFromCompletionContext completionContext;
                  })
        in
        CompletionResult.expression ~completionContext ~prefix:""
      | None, Some ',' ->
        let completionContext =
          completionContext
          |> CompletionContext.addCtxPathItem
               (CRecordField
                  {
                    prefix = "";
                    seenFields;
                    recordCtxPath =
                      ctxPathFromCompletionContext completionContext;
                  })
        in
        CompletionResult.expression ~completionContext ~prefix:""
      | _ -> None)
    | fieldToComplete -> fieldToComplete)
  (* == IDENTS == *)
  | Pexp_ident lid ->
    (* An identifier, like `aaa` *)
    (* TODO(1) idents vs modules, etc *)
    let lidPath = flattenLidCheckDot lid ~completionContext in
    let last = Longident.last lid.txt in
    if lid.loc |> locHasPos then
      (*let completionContext =
          completionContext
          |> CompletionContext.addCtxPathItem (CId (lidPath, Value))
        in*)
      CompletionResult.expression ~completionContext ~prefix:last
    else None
  | Pexp_let (recFlag, valueBindings, nextExpr) ->
    (* A let binding. `let a = b` *)
    let scopeFromBindings =
      scopeValueBindings valueBindings ~scope:completionContext.scope
    in
    let completionContextWithScopeFromBindings =
      completionContext |> CompletionContext.withScope scopeFromBindings
    in
    (* First check if the next expr is the thing with the cursor *)
    if locHasPos nextExpr.pexp_loc then
      completeExpr ~completionContext:completionContextWithScopeFromBindings
        nextExpr
    else if locHasPos expr.pexp_loc then
      (* The cursor is in the expression, but not in the next expression.
         Check the value bindings.*)
      completeValueBindings ~recFlag ~completionContext valueBindings
    else None
  | Pexp_ifthenelse (condition, then_, maybeElse) -> (
    if locHasPos condition.pexp_loc then
      (* TODO: I guess we could set looking for to "bool" here, since it's the if condition *)
      completeExpr
        ~completionContext:(CompletionContext.resetCtx completionContext)
        condition
    else if locHasPos then_.pexp_loc then completeExpr ~completionContext then_
    else
      match maybeElse with
      | Some else_ ->
        if locHasPos else_.pexp_loc then completeExpr ~completionContext else_
        else if checkIfExprHoleEmptyCursor ~completionContext else_ then
          let completionContext =
            completionContext
            |> CompletionContext.addCtxPathItem (CId ([], Value))
          in
          CompletionResult.expression ~completionContext ~prefix:""
        else None
      | _ ->
        (* Check then_ too *)
        if checkIfExprHoleEmptyCursor ~completionContext then_ then
          let completionContext =
            completionContext
            |> CompletionContext.addCtxPathItem (CId ([], Value))
          in
          CompletionResult.expression ~completionContext ~prefix:""
        else None)
  | Pexp_sequence (evalExpr, nextExpr) ->
    if locHasPos evalExpr.pexp_loc then
      completeExpr
        ~completionContext:(CompletionContext.resetCtx completionContext)
        evalExpr
    else if locHasPos nextExpr.pexp_loc then
      completeExpr ~completionContext nextExpr
    else None
  (* == Pipes == *)
  | Pexp_apply
      ( {pexp_desc = Pexp_ident {txt = Lident ("|." | "|.u"); loc = opLoc}},
        [
          (_, lhs);
          (_, {pexp_desc = Pexp_extension _; pexp_loc = {loc_ghost = true}});
        ] )
    when locHasPos opLoc -> (
    (* Case foo-> when the parser adds a ghost expression to the rhs
       so the apply expression does not include the cursor *)
    match completePipe lhs ~id:"" with
    | None -> None
    | Some cpipe ->
      completionContext |> CompletionContext.resetCtx
      |> CompletionResult.ctxPath cpipe)
  | Pexp_apply
      ( {pexp_desc = Pexp_ident {txt = Lident ("|." | "|.u")}},
        [
          (_, lhs);
          (_, {pexp_desc = Pexp_ident {txt = Longident.Lident id; loc}});
        ] )
    when locHasPos loc -> (
    (* foo->id *)
    match completePipe lhs ~id with
    | None -> None
    | Some cpipe ->
      completionContext |> CompletionContext.resetCtx
      |> CompletionResult.ctxPath cpipe)
  | Pexp_apply
      ( {pexp_desc = Pexp_ident {txt = Lident ("|." | "|.u"); loc = opLoc}},
        [(_, lhs); _] )
    when Loc.end_ opLoc = completionContext.positionContext.cursor -> (
    match completePipe lhs ~id:"" with
    | None -> None
    | Some cpipe ->
      completionContext |> CompletionContext.resetCtx
      |> CompletionResult.ctxPath cpipe)
  | Pexp_apply
      ( {pexp_desc = Pexp_ident {txt = Lident ("|." | "|.u")}},
        [(_, lhs); (_, rhs)] ) ->
    (* Descend into pipe parts if none of the special cases above works
       but the cursor is somewhere here. *)
    let completionContext = completionContext |> CompletionContext.resetCtx in
    if locHasPos lhs.pexp_loc then completeExpr ~completionContext lhs
    else if locHasPos rhs.pexp_loc then completeExpr ~completionContext rhs
    else None
  | Pexp_apply ({pexp_desc = Pexp_ident compName}, args)
    when Res_parsetree_viewer.isJsxExpression expr -> (
    (* == JSX == *)
    let jsxProps = CompletionJsx.extractJsxProps ~compName ~args in
    let compNamePath =
      flattenLidCheckDot ~completionContext ~jsx:true compName
    in
    let beforeCursor = completionContext.positionContext.beforeCursor in
    let endPos = Loc.end_ expr.pexp_loc in
    let posAfterCompName = Loc.end_ compName.loc in
    let seenProps =
      List.fold_right
        (fun (prop : CompletionJsx.prop) seenProps -> prop.name :: seenProps)
        jsxProps.props []
    in
    (* Go through all of the props, looking for completions *)
    let rec loop (props : CompletionJsx.prop list) =
      match props with
      | prop :: rest ->
        if prop.posStart <= beforeCursor && beforeCursor < prop.posEnd then
          (* Cursor on the prop name. <Component someP<com> *)
          CompletionResult.jsx ~completionContext ~prefix:prop.name
            ~pathToComponent:
              (Utils.flattenLongIdent ~jsx:true jsxProps.compName.txt)
            ~seenProps
        else if
          prop.posEnd <= beforeCursor
          && beforeCursor < Loc.start prop.exp.pexp_loc
        then
          (* Cursor between the prop name and expr assigned. <Component prop=<com>value *)
          None
        else if locHasPos prop.exp.pexp_loc then
          (* Cursor in the expr assigned. Move into the expr and set that we're
             expecting the return type of the prop. *)
          let completionContext =
            completionContext
            |> CompletionContext.setCurrentlyExpecting
                 (CJsxPropValue
                    {
                      propName = prop.name;
                      pathToComponent =
                        Utils.flattenLongIdent ~jsx:true jsxProps.compName.txt;
                    })
          in
          completeExpr ~completionContext prop.exp
        else if
          locHasPos expr.pexp_loc
          && checkIfExprHoleEmptyCursor ~completionContext prop.exp
        then
          (* Cursor is in the expression, but on an empty assignment. <Comp prop=<com> *)
          let completionContext =
            completionContext
            |> CompletionContext.setCurrentlyExpecting
                 (CJsxPropValue
                    {
                      propName = prop.name;
                      pathToComponent =
                        Utils.flattenLongIdent ~jsx:true jsxProps.compName.txt;
                    })
          in
          CompletionResult.expression ~completionContext ~prefix:""
        else loop rest
      | [] ->
        let beforeChildrenStart =
          match jsxProps.childrenStart with
          | Some childrenPos -> beforeCursor < childrenPos
          | None -> beforeCursor <= endPos
        in
        let afterCompName = beforeCursor >= posAfterCompName in
        if afterCompName && beforeChildrenStart then
          CompletionResult.jsx ~completionContext ~prefix:""
            ~pathToComponent:
              (Utils.flattenLongIdent ~jsx:true jsxProps.compName.txt)
            ~seenProps
        else None
    in
    let jsxCompletable = loop jsxProps.props in
    match jsxCompletable with
    | Some jsxCompletable -> Some jsxCompletable
    | None ->
      if locHasPos compName.loc then
        (* The component name has the cursor.
           Check if this is a HTML element (lowercase initial char) or a component (uppercase initial char). *)
        match compNamePath with
        | [prefix] when Char.lowercase_ascii prefix.[0] = prefix.[0] ->
          CompletionResult.htmlElement ~completionContext ~prefix
        | _ ->
          CompletionResult.ctxPath
            (CId (compNamePath, Module))
            (completionContext |> CompletionContext.resetCtx)
      else None)
  | Pexp_apply (fnExpr, _args) when locHasPos fnExpr.pexp_loc ->
    (* Handle when the cursor is in the function expression itself. *)
    fnExpr
    |> completeExpr
         ~completionContext:(completionContext |> CompletionContext.resetCtx)
  | Pexp_apply (fnExpr, args) -> (
    (* Handle when the cursor isn't in the function expression. Possibly in an argument. *)
    (* TODO: Are we moving into all expressions we need here? The fn expression itself? *)
    let fnContextPath = exprToContextPath fnExpr in
    match fnContextPath with
    | None -> None
    | Some functionContextPath -> (
      let beforeCursor = completionContext.positionContext.beforeCursor in
      let isPipedExpr = false (* TODO: Implement *) in
      let args = extractExpApplyArgs ~args in
      let endPos = Loc.end_ expr.pexp_loc in
      let posAfterFnExpr = Loc.end_ fnExpr.pexp_loc in
      let fnHasCursor =
        posAfterFnExpr <= beforeCursor && beforeCursor < endPos
      in
      (* All of the labels already written in the application. *)
      let seenLabels =
        List.fold_right
          (fun arg seenLabels ->
            match arg with
            | {label = Some labelled} -> labelled.name :: seenLabels
            | {label = None} -> seenLabels)
          args []
      in
      let makeCompletionContextWithArgumentLabel argumentLabel
          ~functionContextPath =
        completionContext |> CompletionContext.resetCtx
        |> CompletionContext.currentlyExpectingOrReset
             (Some (CFunctionArgument {functionContextPath; argumentLabel}))
      in
      (* Piped expressions always have an initial unlabelled argument. *)
      let unlabelledCount = ref (if isPipedExpr then 1 else 0) in
      let rec loop args =
        match args with
        | {label = Some labelled; exp} :: rest ->
          if labelled.posStart <= beforeCursor && beforeCursor < labelled.posEnd
          then
            (* Complete for a label: `someFn(~labelNam<com>)` *)
            CompletionResult.namedArg ~completionContext ~prefix:labelled.name
              ~seenLabels ~functionContextPath
          else if locHasPos exp.pexp_loc then
            (* Completing in the assignment of labelled argument, with a value.
               `someFn(~someLabel=someIden<com>)` *)
            let completionContext =
              makeCompletionContextWithArgumentLabel (Labelled labelled.name)
                ~functionContextPath
            in
            completeExpr ~completionContext exp
          else if CompletionExpressions.isExprHole exp then
            (* Completing in the assignment of labelled argument, with no value yet.
               The parser inserts an expr hole. `someFn(~someLabel=<com>)` *)
            let completionContext =
              makeCompletionContextWithArgumentLabel (Labelled labelled.name)
                ~functionContextPath
            in
            CompletionResult.expression ~completionContext ~prefix:""
          else loop rest
        | {label = None; exp} :: rest ->
          if Res_parsetree_viewer.isTemplateLiteral exp then
            (* Ignore template literals, or we mess up completion inside of them. *)
            None
          else if locHasPos exp.pexp_loc then
            (* Completing in an unlabelled argument with a value. `someFn(someV<com>) *)
            let completionContext =
              makeCompletionContextWithArgumentLabel
                (Unlabelled {argumentPosition = !unlabelledCount})
                ~functionContextPath
            in
            completeExpr ~completionContext exp
          else if CompletionExpressions.isExprHole exp then
            (* Completing in an unlabelled argument without a value. `someFn(true, <com>) *)
            let completionContext =
              makeCompletionContextWithArgumentLabel
                (Unlabelled {argumentPosition = !unlabelledCount})
                ~functionContextPath
            in
            CompletionResult.expression ~completionContext ~prefix:""
          else (
            unlabelledCount := !unlabelledCount + 1;
            loop rest)
        | [] ->
          if fnHasCursor then
            (* No matches, but we know we have the cursor. Check the first char
               behind the cursor. '~' means label completion. *)
            match completionContext.positionContext.charBeforeCursor with
            | Some '~' ->
              CompletionResult.namedArg ~completionContext ~prefix:""
                ~seenLabels ~functionContextPath
            | _ ->
              (* No '~'. Assume we want to complete for the next unlabelled argument. *)
              let completionContext =
                makeCompletionContextWithArgumentLabel
                  (Unlabelled {argumentPosition = !unlabelledCount})
                  ~functionContextPath
              in
              CompletionResult.expression ~completionContext ~prefix:""
          else None
      in
      match args with
      (* Special handling for empty fn calls, e.g. `let _ = someFn(<com>)` *)
      | [
       {
         label = None;
         exp = {pexp_desc = Pexp_construct ({txt = Lident "()"}, _)};
       };
      ]
        when fnHasCursor ->
        let completionContext =
          makeCompletionContextWithArgumentLabel
            (Unlabelled {argumentPosition = 0})
            ~functionContextPath
        in
        CompletionResult.expression ~completionContext ~prefix:""
      | _ -> loop args))
  | Pexp_fun _ ->
    (* We've found a function definition, like `let whatever = (someStr: string) => {}` *)
    let rec loopFnExprs ~(completionContext : CompletionContext.t)
        (expr : Parsetree.expression) =
      (* TODO: Handle completing in default expressions and patterns *)
      match expr.pexp_desc with
      | Pexp_fun (_arg, _defaultExpr, pattern, nextExpr) ->
        let scopeFromPattern =
          scopePattern ~scope:completionContext.scope pattern
        in
        loopFnExprs
          ~completionContext:
            (completionContext |> CompletionContext.withScope scopeFromPattern)
          nextExpr
      | Pexp_constraint (expr, typ) ->
        (expr, completionContext, ctxPathFromCoreType ~completionContext typ)
      | _ -> (expr, completionContext, None)
    in
    let expr, completionContext, fnReturnConstraint =
      loopFnExprs ~completionContext expr
    in
    (* Set the expected type correctly for the expr body *)
    let completionContext =
      match fnReturnConstraint with
      | None ->
        (* Having a Type here already means the binding itself had a constraint on it. Since we're now moving into the function body,
           we'll need to ensure it's the function return type we use for completion, not the function type itself *)
        completionContext
        |> CompletionContext.setCurrentlyExpecting
             (CFunctionReturnType
                {functionCtxPath = completionContext.currentlyExpecting})
      | Some ctxPath ->
        completionContext |> CompletionContext.setCurrentlyExpecting ctxPath
    in
    if locHasPos expr.pexp_loc then completeExpr ~completionContext expr
    else if checkIfExprHoleEmptyCursor ~completionContext expr then
      let completionContext =
        completionContext |> CompletionContext.addCtxPathItem (CId ([], Value))
      in
      CompletionResult.expression ~completionContext ~prefix:""
    else None
  | Pexp_match _ | Pexp_unreachable | Pexp_constant _ | Pexp_function _
  | Pexp_try (_, _)
  | Pexp_tuple _
  | Pexp_construct (_, _)
  | Pexp_variant (_, _)
  | Pexp_record (_, _)
  | Pexp_field (_, _)
  | Pexp_setfield (_, _, _)
  | Pexp_array _
  | Pexp_while (_, _)
  | Pexp_for (_, _, _, _, _)
  | Pexp_constraint (_, _)
  | Pexp_coerce (_, _, _)
  | Pexp_send (_, _)
  | Pexp_setinstvar (_, _)
  | Pexp_override _
  | Pexp_letmodule (_, _, _)
  | Pexp_letexception (_, _)
  | Pexp_assert _ | Pexp_lazy _
  | Pexp_poly (_, _)
  | Pexp_newtype (_, _)
  | Pexp_pack _
  | Pexp_open (_, _, _)
  | Pexp_extension _ ->
    None
  | Pexp_object _ | Pexp_new _ -> (* These are irrelevant to ReScript *) None

and completePattern ~(completionContext : CompletionContext.t)
    (pat : Parsetree.pattern) : CompletionResult.t =
  let locHasPos = completionContext.positionContext.locHasPos in
  match pat.ppat_desc with
  | Ppat_lazy p
  | Ppat_constraint (p, _)
  | Ppat_alias (p, _)
  | Ppat_exception p
  | Ppat_open (_, p) ->
    (* Can just continue into these patterns. *)
    if locHasPos pat.ppat_loc then p |> completePattern ~completionContext
    else None
  | Ppat_or (p1, p2) -> (
    (* Try to complete each `or` pattern *)
    let orPatCompleted =
      [p1; p2]
      |> List.find_map (fun p ->
             if locHasPos p.Parsetree.ppat_loc then
               completePattern ~completionContext p
             else None)
    in
    match orPatCompleted with
    | None
      when CompletionPatterns.isPatternHole p1
           || CompletionPatterns.isPatternHole p2 ->
      (* TODO(1) explain this *)
      CompletionResult.pattern ~completionContext ~prefix:""
    | res -> res)
  | Ppat_var {txt; loc} ->
    (* A variable, like `{ someThing: someV<com>}*)
    if locHasPos loc then
      CompletionResult.pattern ~completionContext ~prefix:txt
    else None
  | Ppat_record ([], _) ->
    (* Empty fields means we're in a record body `{}`. Complete for the fields. *)
    if locHasPos pat.ppat_loc then
      let completionContext =
        CompletionContext.addCtxPathItem
          (CRecordField
             {
               seenFields = [];
               prefix = "";
               recordCtxPath = ctxPathFromCompletionContext completionContext;
             })
          completionContext
      in
      CompletionResult.pattern ~completionContext ~prefix:""
    else None
  | Ppat_record (fields, _) -> (
    (* Record body with fields, where we know the cursor is inside of the record body somewhere. *)
    let seenFields =
      fields
      |> List.filter_map (fun (fieldName, _f) ->
             match fieldName with
             | {Location.txt = Longident.Lident fieldName} -> Some fieldName
             | _ -> None)
    in
    let fieldNameWithCursor =
      fields
      |> List.find_map
           (fun ((fieldName : Longident.t Location.loc), _fieldPattern) ->
             if locHasPos fieldName.Location.loc then Some fieldName else None)
    in
    let fieldPatternWithCursor =
      fields
      |> List.find_map (fun (fieldName, fieldPattern) ->
             if locHasPos fieldPattern.Parsetree.ppat_loc then
               Some (fieldName, fieldPattern)
             else None)
    in
    match (fieldNameWithCursor, fieldPatternWithCursor) with
    | Some fieldName, _ ->
      (* {someFieldName<com>: someValue} *)
      let prefix = Longident.last fieldName.txt in
      CompletionResult.pattern ~prefix
        ~completionContext:
          (CompletionContext.addCtxPathItem
             (CRecordField
                {
                  seenFields;
                  prefix;
                  recordCtxPath = ctxPathFromCompletionContext completionContext;
                })
             completionContext)
    | None, Some (fieldName, fieldPattern) ->
      (* {someFieldName: someOtherPattern<com>} *)
      let prefix = Longident.last fieldName.txt in
      let completionContext =
        CompletionContext.addCtxPathItem
          (CRecordField
             {
               seenFields;
               prefix;
               recordCtxPath = ctxPathFromCompletionContext completionContext;
             })
          completionContext
      in
      completePattern ~completionContext fieldPattern
    | None, None ->
      if locHasPos pat.ppat_loc then
        (* We know the cursor is here, but it's not in a field name nor a field pattern.
           Check empty field patterns. TODO(1) *)
        None
      else None)
  | Ppat_tuple tupleItems -> (
    let tupleItemWithCursor =
      tupleItems
      |> Utils.findMapWithIndex (fun index (tupleItem : Parsetree.pattern) ->
             if locHasPos tupleItem.ppat_loc then Some (index, tupleItem)
             else None)
    in
    match tupleItemWithCursor with
    | Some (itemNum, tupleItem) ->
      let completionContext =
        completionContext
        |> CompletionContext.addCtxPathItem
             (CTupleItem
                {
                  itemNum;
                  tupleCtxPath = ctxPathFromCompletionContext completionContext;
                })
      in
      completePattern ~completionContext tupleItem
    | None ->
      if locHasPos pat.ppat_loc then
        (* We found no tuple item with the cursor, but we know the cursor is in the
           pattern. Check if the user is trying to complete an empty tuple item *)
        match completionContext.positionContext.charBeforeNoWhitespace with
        | Some ',' ->
          (* `(true, false, <com>)` itemNum = 2, or `(true, <com>, false)` itemNum = 1 *)
          (* Figure out which tuple item is active. *)
          let itemNum = ref (-1) in
          tupleItems
          |> List.iteri (fun index (pat : Parsetree.pattern) ->
                 if
                   completionContext.positionContext.beforeCursor
                   >= Loc.start pat.ppat_loc
                 then itemNum := index);
          if !itemNum > -1 then
            let completionContext =
              completionContext
              |> CompletionContext.addCtxPathItem
                   (CTupleItem
                      {
                        itemNum = !itemNum + 1;
                        tupleCtxPath =
                          ctxPathFromCompletionContext completionContext;
                      })
            in
            CompletionResult.pattern ~completionContext ~prefix:""
          else None
        | Some '(' ->
          (* TODO: This should work (start of tuple), but the parser is broken for this case:
             let (<com> , true) = someRecordVar. If we fix that completing in the first position
             could work too. *)
          let completionContext =
            completionContext
            |> CompletionContext.addCtxPathItem
                 (CTupleItem
                    {
                      itemNum = 0;
                      tupleCtxPath =
                        ctxPathFromCompletionContext completionContext;
                    })
          in
          CompletionResult.pattern ~completionContext ~prefix:""
        | _ -> None
      else None)
  | Ppat_array items ->
    if locHasPos pat.ppat_loc then
      if List.length items = 0 then
        (* {someArr: [<com>]} *)
        let completionContext =
          completionContext |> CompletionContext.addCtxPathItem (CArray None)
        in
        CompletionResult.pattern ~completionContext ~prefix:""
      else
        let arrayItemWithCursor =
          items
          |> List.find_opt (fun (item : Parsetree.pattern) ->
                 locHasPos item.ppat_loc)
        in
        match
          ( arrayItemWithCursor,
            completionContext.positionContext.charBeforeNoWhitespace )
        with
        | Some item, _ ->
          (* Found an array item with the cursor. *)
          let completionContext =
            completionContext |> CompletionContext.addCtxPathItem (CArray None)
          in
          completePattern ~completionContext item
        | None, Some ',' ->
          (* No array item with the cursor, but we know the cursor is in the pattern.
             Check for "," which would signify the user is looking to add another
             array item to the pattern. *)
          let completionContext =
            completionContext |> CompletionContext.addCtxPathItem (CArray None)
          in
          CompletionResult.pattern ~completionContext ~prefix:""
        | _ -> None
    else None
  | Ppat_any ->
    (* We treat any `_` as an empty completion. This is mainly because we're
       inserting `_` in snippets and automatically put the cursor there. So
       letting it trigger an empty completion improves the ergonomics by a
       lot. *)
    if locHasPos pat.ppat_loc then
      CompletionResult.pattern ~completionContext ~prefix:""
    else None
  | Ppat_construct (_, _)
  | Ppat_variant (_, _)
  | Ppat_type _ | Ppat_unpack _ | Ppat_extension _ | Ppat_constant _
  | Ppat_interval _ ->
    None

let completion ~currentFile ~path ~debug ~offset ~posCursor text =
  let positionContext = PositionContext.make ~offset ~posCursor text in
  let completionContext = CompletionContext.make positionContext in
  if Filename.check_suffix path ".res" then
    let parser =
      Res_driver.parsingEngine.parseImplementation ~forPrinter:false
    in
    let {Res_driver.parsetree = str} = parser ~filename:currentFile in
    str |> completeFromStructure ~completionContext
  else if Filename.check_suffix path ".resi" then
    let parser = Res_driver.parsingEngine.parseInterface ~forPrinter:false in
    let {Res_driver.parsetree = signature} = parser ~filename:currentFile in
    None
  else None
