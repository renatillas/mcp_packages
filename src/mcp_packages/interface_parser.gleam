import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import simplifile

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
  TypeInfo(name: String, documentation: String)
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

pub fn parse_package_interface(
  json_path: String,
) -> Result(PackageInterface, String) {
  case simplifile.read(json_path) {
    Ok(content) -> {
      case json.parse(content, interface_decoder()) {
        Ok(json_value) -> {
          Ok(json_value)
        }
        Error(_) -> Error("Failed to parse JSON: ")
      }
    }
    Error(err) ->
      Error("Failed to read file " <> json_path <> ": " <> string.inspect(err))
  }
}

fn interface_decoder() -> decode.Decoder(PackageInterface) {
  {
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
}

fn module_data_decoder() -> decode.Decoder(ModuleData) {
  {
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

    let doc_string = string.join(documentation, " ")

    decode.success(ModuleData(
      documentation: doc_string,
      functions: functions,
      types: types,
    ))
  }
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
      Ok(label_str) ->
        case label_str {
          "" -> ""
          _ -> label_str
        }
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
        "named" -> {
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
            // Built-in types don't need module prefix
            Ok(mod) -> mod <> "."
            Error(_) -> ""
          }

          package <> module <> name
        }
        "variable" -> {
          case decode.run(type_dynamic, decode.at(["id"], decode.int)) {
            Ok(id) ->
              case id {
                0 -> "a"
                1 -> "b"
                2 -> "c"
                n -> "t" <> int.to_string(n)
              }
            Error(_) -> "a"
          }
        }
        "fn" -> {
          let params = case
            decode.run(
              type_dynamic,
              decode.at(["parameters"], decode.list(decode.dynamic)),
            )
          {
            Ok(param_types) -> {
              let param_strs = list.map(param_types, extract_type_name)
              case param_strs {
                [] -> "()"
                types -> "(" <> string.join(types, ", ") <> ")"
              }
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
        _ -> "unknown"
      }
    Error(_) -> "unknown"
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

    TypeInfo(name: type_name, documentation: documentation)
  })
}

pub fn search_functions(
  interface: PackageInterface,
  query: String,
) -> List(FunctionInfo) {
  interface.modules
  |> list.flat_map(fn(module_info) { module_info.functions })
  |> list.filter(fn(func) {
    string.contains(string.lowercase(func.name), string.lowercase(query))
    || string.contains(
      string.lowercase(func.documentation),
      string.lowercase(query),
    )
    || string.contains(
      string.lowercase(func.signature),
      string.lowercase(query),
    )
  })
}

pub fn search_types(
  interface: PackageInterface,
  query: String,
) -> List(TypeInfo) {
  interface.modules
  |> list.flat_map(fn(module_info) { module_info.types })
  |> list.filter(fn(type_info) {
    string.contains(string.lowercase(type_info.name), string.lowercase(query))
    || string.contains(
      string.lowercase(type_info.documentation),
      string.lowercase(query),
    )
  })
}

pub fn get_module_info(
  interface: PackageInterface,
  module_name: String,
) -> Result(ModuleInfo, String) {
  case list.find(interface.modules, fn(mod) { mod.name == module_name }) {
    Ok(module_info) -> Ok(module_info)
    Error(_) -> Error("Module " <> module_name <> " not found")
  }
}

pub fn format_function_summary(func: FunctionInfo) -> String {
  func.name <> func.signature
}
