import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import simplifile

pub type PackageInterface {
  PackageInterface(
    name: String,
    version: String,
    modules: List(ModuleInfo),
    types: List(TypeInfo),
    functions: List(FunctionInfo),
  )
}

pub type ModuleInfo {
  ModuleInfo(
    name: String,
    documentation: String,
    functions: List(String),
    types: List(String),
  )
}

pub type TypeInfo {
  TypeInfo(
    name: String,
    module: String,
    documentation: String,
    constructors: List(ConstructorInfo),
  )
}

pub type ConstructorInfo {
  ConstructorInfo(name: String, parameters: List(String))
}

pub type FunctionInfo {
  FunctionInfo(
    name: String,
    module: String,
    documentation: String,
    signature: String,
    parameters: List(ParameterInfo),
  )
}

pub type ParameterInfo {
  ParameterInfo(name: String, type_annotation: String)
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
    use modules <- decode.field("modules", decode.list(module_decoder()))
    use types <- decode.field("types", decode.list(type_decoder()))
    use functions <- decode.field("functions", decode.list(function_decoder()))
    decode.success(PackageInterface(
      name: name,
      version: version,
      modules: modules,
      types: types,
      functions: functions,
    ))
  }
}

fn module_decoder() -> decode.Decoder(ModuleInfo) {
  {
    use name <- decode.field("name", decode.string)
    use documentation <- decode.field("documentation", decode.string)
    use functions <- decode.field("functions", decode.list(decode.string))
    use types <- decode.field("types", decode.list(decode.string))
    decode.success(ModuleInfo(
      name: name,
      documentation: documentation,
      functions: functions,
      types: types,
    ))
  }
}

fn type_decoder() -> decode.Decoder(TypeInfo) {
  {
    use name <- decode.field("name", decode.string)
    use module <- decode.field("module", decode.string)
    use documentation <- decode.field("documentation", decode.string)
    use constructors <- decode.field(
      "constructors",
      decode.list(constructor_decoder()),
    )
    decode.success(TypeInfo(
      name: name,
      module: module,
      documentation: documentation,
      constructors: constructors,
    ))
  }
}

fn constructor_decoder() -> decode.Decoder(ConstructorInfo) {
  {
    use name <- decode.field("name", decode.string)
    use parameters <- decode.field("parameters", decode.list(decode.string))
    decode.success(ConstructorInfo(name: name, parameters: parameters))
  }
}

fn function_decoder() -> decode.Decoder(FunctionInfo) {
  {
    use name <- decode.field("name", decode.string)
    use module <- decode.field("module", decode.string)
    use documentation <- decode.field("documentation", decode.string)
    use signature <- decode.field("signature", decode.string)
    use parameters <- decode.field(
      "parameters",
      decode.list(parameter_decoder()),
    )
    decode.success(FunctionInfo(
      name: name,
      module: module,
      documentation: documentation,
      signature: signature,
      parameters: parameters,
    ))
  }
}

fn parameter_decoder() -> decode.Decoder(ParameterInfo) {
  {
    use name <- decode.field("name", decode.string)
    use type_annotation <- decode.field("type_annotation", decode.string)
    decode.success(ParameterInfo(name: name, type_annotation: type_annotation))
  }
}

pub fn search_functions(
  interface: PackageInterface,
  query: String,
) -> List(FunctionInfo) {
  interface.functions
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
  interface.types
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
  let params_str = case func.parameters {
    [] -> ""
    params -> {
      params
      |> list.map(fn(p) { p.name <> ": " <> p.type_annotation })
      |> string.join(", ")
      |> fn(s) { "(" <> s <> ")" }
    }
  }

  func.module <> "." <> func.name <> params_str <> " -> " <> func.signature
}
