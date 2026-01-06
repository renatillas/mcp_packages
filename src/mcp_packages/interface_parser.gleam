import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string

pub type PackageInterface {
  PackageInterface(name: String, version: String, modules: List(ModuleInfo))
}

pub type ModuleInfo {
  ModuleInfo(
    name: String,
    documentation: String,
    functions: List(FunctionInfo),
    types: List(TypeInfo),
  )
}

pub type TypeInfo {
  TypeInfo(
    name: String,
    documentation: String,
    signature: String,
    type_kind: String,
  )
}

pub type FunctionInfo {
  FunctionInfo(
    name: String,
    documentation: String,
    signature: String,
    parameters: List(ParameterInfo),
  )
}

pub type ParameterInfo {
  ParameterInfo(label: String, type_name: String)
}

type ModuleData {
  ModuleData(
    documentation: String,
    functions: Dict(String, dynamic.Dynamic),
    types: Dict(String, dynamic.Dynamic),
  )
}

/// Parse a package interface from a JSON string (fetched from hexdocs.pm)
pub fn parse_package_interface(
  json_content: String,
) -> Result(PackageInterface, String) {
  case json.parse(json_content, interface_decoder()) {
    Ok(interface) -> Ok(interface)
    Error(err) -> Error("Failed to parse package interface JSON: " <> string.inspect(err))
  }
}

fn interface_decoder() -> decode.Decoder(PackageInterface) {
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.string)
  use modules_dict <- decode.field(
    "modules",
    decode.dict(decode.string, module_data_decoder()),
  )

  let modules =
    modules_dict
    |> dict.to_list()
    |> list.map(fn(entry) {
      let #(module_name, module_data) = entry
      ModuleInfo(
        name: module_name,
        documentation: module_data.documentation,
        functions: extract_functions(module_data.functions),
        types: extract_types(module_data.types),
      )
    })

  decode.success(PackageInterface(
    name: name,
    version: version,
    modules: modules,
  ))
}

fn module_data_decoder() -> decode.Decoder(ModuleData) {
  use documentation <- decode.field(
    "documentation",
    decode.list(decode.string),
  )
  use functions <- decode.optional_field(
    "functions",
    dict.new(),
    decode.dict(decode.string, decode.dynamic),
  )
  use types <- decode.optional_field(
    "types",
    dict.new(),
    decode.dict(decode.string, decode.dynamic),
  )

  let doc_string = string.join(documentation, "\n")

  decode.success(ModuleData(
    documentation: doc_string,
    functions: functions,
    types: types,
  ))
}

fn extract_functions(
  functions_dict: Dict(String, dynamic.Dynamic),
) -> List(FunctionInfo) {
  functions_dict
  |> dict.to_list()
  |> list.map(fn(entry) {
    let #(func_name, func_data) = entry
    let documentation = case
      decode.run(func_data, decode.at(["documentation"], decode.string))
    {
      Ok(doc) -> doc
      Error(_) -> ""
    }

    let parameters = case
      decode.run(
        func_data,
        decode.at(["parameters"], decode.list(decode.dynamic)),
      )
    {
      Ok(params_list) -> extract_parameters(params_list)
      Error(_) -> []
    }

    let return_type = case
      decode.run(func_data, decode.at(["return"], decode.dynamic))
    {
      Ok(return_dynamic) -> extract_type_name(return_dynamic)
      Error(_) -> "unknown"
    }

    let signature = build_function_signature(func_name, parameters, return_type)

    FunctionInfo(
      name: func_name,
      documentation: documentation,
      signature: signature,
      parameters: parameters,
    )
  })
}

fn extract_parameters(params_list: List(dynamic.Dynamic)) -> List(ParameterInfo) {
  params_list
  |> list.map(fn(param_dynamic) {
    let label = case
      decode.run(param_dynamic, decode.at(["label"], decode.string))
    {
      Ok(label_str) -> label_str
      Error(_) -> ""
    }

    let type_name = case
      decode.run(param_dynamic, decode.at(["type"], decode.dynamic))
    {
      Ok(type_dynamic) -> extract_type_name(type_dynamic)
      Error(_) -> "unknown"
    }

    ParameterInfo(label: label, type_name: type_name)
  })
}

fn extract_type_name(type_dynamic: dynamic.Dynamic) -> String {
  case decode.run(type_dynamic, decode.at(["kind"], decode.string)) {
    Ok(kind) ->
      case kind {
        "named" -> extract_named_type(type_dynamic)
        "variable" -> extract_variable_type(type_dynamic)
        "fn" -> extract_fn_type(type_dynamic)
        "tuple" -> extract_tuple_type(type_dynamic)
        _ -> "unknown"
      }
    Error(_) -> "unknown"
  }
}

fn extract_named_type(type_dynamic: dynamic.Dynamic) -> String {
  let name = case
    decode.run(type_dynamic, decode.at(["name"], decode.string))
  {
    Ok(type_name) -> type_name
    Error(_) -> "unknown"
  }

  let package = case
    decode.run(type_dynamic, decode.at(["package"], decode.string))
  {
    Ok("") -> ""
    Ok(pkg) -> pkg <> "/"
    Error(_) -> ""
  }

  let module = case
    decode.run(type_dynamic, decode.at(["module"], decode.string))
  {
    Ok("gleam") -> ""
    Ok(mod) -> mod <> "."
    Error(_) -> ""
  }

  // Handle type parameters
  let params = case
    decode.run(
      type_dynamic,
      decode.at(["parameters"], decode.list(decode.dynamic)),
    )
  {
    Ok([]) -> ""
    Ok(param_types) -> {
      let param_strs = list.map(param_types, extract_type_name)
      "(" <> string.join(param_strs, ", ") <> ")"
    }
    Error(_) -> ""
  }

  package <> module <> name <> params
}

fn extract_variable_type(type_dynamic: dynamic.Dynamic) -> String {
  case decode.run(type_dynamic, decode.at(["id"], decode.int)) {
    Ok(id) ->
      case id {
        0 -> "a"
        1 -> "b"
        2 -> "c"
        3 -> "d"
        4 -> "e"
        5 -> "f"
        n -> "t" <> int.to_string(n)
      }
    Error(_) -> "a"
  }
}

fn extract_fn_type(type_dynamic: dynamic.Dynamic) -> String {
  let params = case
    decode.run(
      type_dynamic,
      decode.at(["parameters"], decode.list(decode.dynamic)),
    )
  {
    Ok(param_types) -> {
      let param_strs = list.map(param_types, extract_type_name)
      "(" <> string.join(param_strs, ", ") <> ")"
    }
    Error(_) -> "()"
  }

  let return_type = case
    decode.run(type_dynamic, decode.at(["return"], decode.dynamic))
  {
    Ok(ret_type) -> extract_type_name(ret_type)
    Error(_) -> "unknown"
  }

  "fn" <> params <> " -> " <> return_type
}

fn extract_tuple_type(type_dynamic: dynamic.Dynamic) -> String {
  case
    decode.run(
      type_dynamic,
      decode.at(["elements"], decode.list(decode.dynamic)),
    )
  {
    Ok(elements) -> {
      let element_strs = list.map(elements, extract_type_name)
      "#(" <> string.join(element_strs, ", ") <> ")"
    }
    Error(_) -> "#()"
  }
}

fn build_function_signature(
  func_name: String,
  parameters: List(ParameterInfo),
  return_type: String,
) -> String {
  let param_strings =
    parameters
    |> list.map(fn(param) {
      case param.label {
        "" -> param.type_name
        label -> label <> ": " <> param.type_name
      }
    })

  let params_str = case param_strings {
    [] -> func_name <> "()"
    params -> func_name <> "(" <> string.join(params, ", ") <> ")"
  }

  params_str <> " -> " <> return_type
}

fn extract_types(types_dict: Dict(String, dynamic.Dynamic)) -> List(TypeInfo) {
  types_dict
  |> dict.to_list()
  |> list.map(fn(entry) {
    let #(type_name, type_data) = entry
    let documentation = case
      decode.run(type_data, decode.at(["documentation"], decode.string))
    {
      Ok(doc) -> doc
      Error(_) -> ""
    }

    let type_kind = case
      decode.run(type_data, decode.at(["opaque"], decode.bool))
    {
      Ok(True) -> "opaque"
      Ok(False) -> "custom"
      Error(_) -> "unknown"
    }

    let signature = build_type_signature(type_name, type_data)

    TypeInfo(
      name: type_name,
      documentation: documentation,
      signature: signature,
      type_kind: type_kind,
    )
  })
}

fn build_type_signature(
  type_name: String,
  type_data: dynamic.Dynamic,
) -> String {
  let type_params = case
    decode.run(type_data, decode.at(["parameters"], decode.int))
  {
    Ok(0) -> ""
    Ok(n) -> {
      let vars = list.range(0, n - 1) |> list.map(fn(i) {
        case i {
          0 -> "a"
          1 -> "b"
          2 -> "c"
          3 -> "d"
          4 -> "e"
          _ -> "t" <> int.to_string(i)
        }
      })
      "(" <> string.join(vars, ", ") <> ")"
    }
    Error(_) -> ""
  }

  let constructors = case
    decode.run(
      type_data,
      decode.at(["constructors"], decode.list(decode.dynamic)),
    )
  {
    Ok(constructors_list) -> extract_constructors(constructors_list)
    Error(_) -> ""
  }

  case constructors {
    "" -> "type " <> type_name <> type_params
    c -> "type " <> type_name <> type_params <> " {\n  " <> c <> "\n}"
  }
}

fn extract_constructors(constructors_list: List(dynamic.Dynamic)) -> String {
  let constructor_strs =
    constructors_list
    |> list.map(fn(constructor) {
      let constructor_name = case
        decode.run(constructor, decode.at(["name"], decode.string))
      {
        Ok(name) -> name
        Error(_) -> "Unknown"
      }

      let parameters = case
        decode.run(
          constructor,
          decode.at(["parameters"], decode.list(decode.dynamic)),
        )
      {
        Ok(params_list) -> {
          let param_strs =
            params_list
            |> list.map(fn(param) {
              let param_label = case
                decode.run(param, decode.at(["label"], decode.string))
              {
                Ok(label) -> label <> ": "
                Error(_) -> ""
              }

              let param_type = case
                decode.run(param, decode.at(["type"], decode.dynamic))
              {
                Ok(type_data) -> extract_type_name(type_data)
                Error(_) -> "unknown"
              }

              param_label <> param_type
            })

          case param_strs {
            [] -> ""
            strs -> "(" <> string.join(strs, ", ") <> ")"
          }
        }
        Error(_) -> ""
      }

      constructor_name <> parameters
    })

  string.join(constructor_strs, "\n  ")
}

pub fn get_module_info(
  interface: PackageInterface,
  module_name: String,
) -> Result(ModuleInfo, String) {
  case list.find(interface.modules, fn(mod) { mod.name == module_name }) {
    Ok(module_info) -> Ok(module_info)
    Error(_) -> Error("Module '" <> module_name <> "' not found in package")
  }
}

pub fn search_functions(
  interface: PackageInterface,
  query: String,
) -> List(FunctionInfo) {
  let query_lower = string.lowercase(query)
  interface.modules
  |> list.flat_map(fn(module_info) { module_info.functions })
  |> list.filter(fn(func) {
    string.contains(string.lowercase(func.name), query_lower)
    || string.contains(string.lowercase(func.documentation), query_lower)
  })
}

pub fn search_types(
  interface: PackageInterface,
  query: String,
) -> List(TypeInfo) {
  let query_lower = string.lowercase(query)
  interface.modules
  |> list.flat_map(fn(module_info) { module_info.types })
  |> list.filter(fn(type_info) {
    string.contains(string.lowercase(type_info.name), query_lower)
    || string.contains(string.lowercase(type_info.documentation), query_lower)
  })
}
