open SharedTypes

let showModuleTopLevel ~docstring ~name (topLevel : Module.item list) =
  let contents =
    topLevel
    |> List.map (fun item ->
           match item.Module.kind with
           (* TODO pretty print module contents *)
           | Type ({decl}, recStatus) ->
             "  " ^ (decl |> Shared.declToString ~recStatus item.name)
           | Module _ -> "  module " ^ item.name
           | Value typ ->
             "  let " ^ item.name ^ ": " ^ (typ |> Shared.typeToString))
    (* TODO indent *)
    |> String.concat "\n"
  in
  let full =
    Markdown.codeBlock ("module " ^ name ^ " = {" ^ "\n" ^ contents ^ "\n}")
  in
  let doc =
    match docstring with
    | [] -> ""
    | _ :: _ -> "\n" ^ (docstring |> String.concat "\n") ^ "\n"
  in
  Some (doc ^ full)

let rec showModule ~docstring ~(file : File.t) ~name
    (declared : Module.t Declared.t option) =
  match declared with
  | None -> showModuleTopLevel ~docstring ~name file.structure.items
  | Some {item = Structure {items}} -> showModuleTopLevel ~docstring ~name items
  | Some ({item = Constraint (_moduleItem, moduleTypeItem)} as declared) ->
    (* show the interface *)
    showModule ~docstring ~file ~name
      (Some {declared with item = moduleTypeItem})
  | Some {item = Ident path} ->
    Some ("Unable to resolve module reference " ^ Path.name path)

type extractedType = {
  name: string;
  path: Path.t;
  decl: Types.type_declaration;
  env: SharedTypes.QueryEnv.t;
  loc: Warnings.loc;
}

let findRelevantTypesFromType ~file ~package typ =
  (* Expand definitions of types mentioned in typ.
     If typ itself is a record or variant, search its body *)
  let env = QueryEnv.fromFile file in
  let envToSearch, typesToSearch =
    match typ |> Shared.digConstructor with
    | Some path -> (
      let labelDeclarationsTypes lds =
        lds |> List.map (fun (ld : Types.label_declaration) -> ld.ld_type)
      in
      match References.digConstructor ~env ~package path with
      | None -> (env, [typ])
      | Some (env1, {item = {decl}}) -> (
        match decl.type_kind with
        | Type_record (lds, _) -> (env1, typ :: (lds |> labelDeclarationsTypes))
        | Type_variant cds ->
          ( env1,
            cds
            |> List.map (fun (cd : Types.constructor_declaration) ->
                   let fromArgs =
                     match cd.cd_args with
                     | Cstr_tuple ts -> ts
                     | Cstr_record lds -> lds |> labelDeclarationsTypes
                   in
                   typ
                   ::
                   (match cd.cd_res with
                   | None -> fromArgs
                   | Some t -> t :: fromArgs))
            |> List.flatten )
        | _ -> (env, [typ])))
    | None -> (env, [typ])
  in
  let fromConstructorPath ~env path =
    match References.digConstructor ~env ~package path with
    | None -> None
    | Some (env, {name = {txt}; extentLoc; item = {decl}}) ->
      if Utils.isUncurriedInternal path then None
      else Some {name = txt; env; loc = extentLoc; decl; path}
  in
  let constructors = Shared.findTypeConstructors typesToSearch in
  constructors |> List.filter_map (fromConstructorPath ~env:envToSearch)

(* Produces a hover with relevant types expanded in the main type being hovered. *)
let hoverWithExpandedTypes ~docstring ~file ~package ~supportsMarkdownLinks typ
    =
  let typeString = Markdown.codeBlock (typ |> Shared.typeToString) in
  let types = findRelevantTypesFromType typ ~file ~package in
  let typeDefinitions =
    types
    |> List.map (fun {decl; env; loc; path} ->
           let linkToTypeDefinitionStr =
             if supportsMarkdownLinks then
               Markdown.goToDefinitionText ~env ~pos:loc.Warnings.loc_start
             else ""
           in
           "\n" ^ Markdown.spacing
           ^ Markdown.codeBlock
               (decl
               |> Shared.declToString ~printNameAsIs:true
                    (SharedTypes.pathIdentToString path))
           ^ linkToTypeDefinitionStr ^ "\n" ^ Markdown.divider)
  in
  (typeString :: typeDefinitions |> String.concat "\n", docstring)

(* Leverages autocomplete functionality to produce a hover for a position. This
   makes it (most often) work with unsaved content. *)
let getHoverViaCompletions ~debug ~path ~pos ~currentFile ~forHover
    ~supportsMarkdownLinks =
  let textOpt = Files.readFile currentFile in
  match textOpt with
  | None | Some "" -> None
  | Some text -> (
    match
      CompletionFrontEnd.completionWithParser ~debug ~path ~posCursor:pos
        ~currentFile ~text
    with
    | None -> None
    | Some (completable, scope) -> (
      if debug then
        Printf.printf "Completable: %s\n"
          (SharedTypes.Completable.toString completable);
      (* Only perform expensive ast operations if there are completables *)
      match Cmt.fullFromPath ~path with
      | None -> None
      | Some {file; package} -> (
        let env = SharedTypes.QueryEnv.fromFile file in
        let completions =
          completable
          |> CompletionBackEnd.processCompletable ~debug ~package ~pos ~scope
               ~env ~forHover
        in
        match completions with
        | {kind = Label typString; docstring} :: _ ->
          let parts =
            (if typString = "" then [] else [Markdown.codeBlock typString])
            @ docstring
          in
          Some (Protocol.stringifyHover (String.concat "\n\n" parts))
        | _ -> (
          match CompletionBackEnd.completionsGetTypeEnv completions with
          | Some (typ, _env) ->
            let typeString, _docstring =
              hoverWithExpandedTypes ~docstring:"" ~file ~package
                ~supportsMarkdownLinks typ
            in
            Some (Protocol.stringifyHover typeString)
          | None -> None))))

let newHover ~full:{file; package} ~supportsMarkdownLinks locItem =
  match locItem.locType with
  | TypeDefinition (name, decl, _stamp) ->
    let typeDef = Shared.declToString name decl in
    Some (Markdown.codeBlock typeDef)
  | LModule (Definition (stamp, _tip)) | LModule (LocalReference (stamp, _tip))
    -> (
    match Stamps.findModule file.stamps stamp with
    | None -> None
    | Some md -> (
      match References.resolveModuleReference ~file ~package md with
      | None -> None
      | Some (file, declared) ->
        let name, docstring =
          match declared with
          | Some d -> (d.name.txt, d.docstring)
          | None -> (file.moduleName, file.structure.docstring)
        in
        showModule ~docstring ~name ~file declared))
  | LModule (GlobalReference (moduleName, path, tip)) -> (
    match ProcessCmt.fileForModule ~package moduleName with
    | None -> None
    | Some file -> (
      let env = QueryEnv.fromFile file in
      match ResolvePath.resolvePath ~env ~path ~package with
      | None -> None
      | Some (env, name) -> (
        match References.exportedForTip ~env name tip with
        | None -> None
        | Some stamp -> (
          match Stamps.findModule file.stamps stamp with
          | None -> None
          | Some md -> (
            match References.resolveModuleReference ~file ~package md with
            | None -> None
            | Some (file, declared) ->
              let name, docstring =
                match declared with
                | Some d -> (d.name.txt, d.docstring)
                | None -> (file.moduleName, file.structure.docstring)
              in
              showModule ~docstring ~name ~file declared)))))
  | LModule NotFound -> None
  | TopLevelModule name -> (
    match ProcessCmt.fileForModule ~package name with
    | None -> None
    | Some file ->
      showModule ~docstring:file.structure.docstring ~name:file.moduleName ~file
        None)
  | Typed (_, _, Definition (_, (Field _ | Constructor _))) -> None
  | Constant t ->
    Some
      (Markdown.codeBlock
         (match t with
         | Const_int _ -> "int"
         | Const_char _ -> "char"
         | Const_string _ -> "string"
         | Const_float _ -> "float"
         | Const_int32 _ -> "int32"
         | Const_int64 _ -> "int64"
         | Const_nativeint _ -> "int"))
  | Typed (_, t, locKind) ->
    let fromType ~docstring typ =
      hoverWithExpandedTypes ~docstring ~file ~package ~supportsMarkdownLinks
        typ
    in
    let parts =
      match References.definedForLoc ~file ~package locKind with
      | None ->
        let typeString, docstring = t |> fromType ~docstring:[] in
        typeString :: docstring
      | Some (docstring, res) -> (
        match res with
        | `Declared ->
          let typeString, docstring = t |> fromType ~docstring in
          typeString :: docstring
        | `Constructor {cname = {txt}; args} ->
          let typeString, docstring = t |> fromType ~docstring in
          let argsString =
            match args with
            | [] -> ""
            | _ ->
              args
              |> List.map (fun (t, _) -> Shared.typeToString t)
              |> String.concat ", " |> Printf.sprintf "(%s)"
          in
          typeString :: Markdown.codeBlock (txt ^ argsString) :: docstring
        | `Field ->
          let typeString, docstring = t |> fromType ~docstring in
          typeString :: docstring)
    in
    Some (String.concat "\n\n" parts)