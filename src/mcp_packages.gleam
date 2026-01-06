import gleam/dynamic
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import mcp_packages/hex_client
import mcp_packages/interface_parser

// ============================================================================
// Types
// ============================================================================

pub type McpRequest {
  McpRequest(jsonrpc: String, id: String, method: String, params: McpParams)
}

pub type McpParams {
  CallToolParams(name: String, arguments: ToolArguments)
  ListToolsParams
  ListResourcesParams
  ReadResourceParams(uri: String)
  InitializeParams
}

pub type ToolArguments {
  SearchArguments(query: String)
  PackageArguments(package_name: String)
  ModuleArguments(package_name: String, module_name: String)
}

// ============================================================================
// Cloudflare Worker Entry Point
// ============================================================================

/// Main fetch handler for Cloudflare Workers
/// This is called from the JavaScript entry point
pub fn fetch(
  req: Request(String),
  _env: dynamic.Dynamic,
) -> Promise(Response(String)) {
  case req.method {
    http.Post -> handle_post(req)
    _ -> {
      promise.resolve(
        response.new(405)
        |> response.set_body("Method not allowed"),
      )
    }
  }
}

fn handle_post(req: Request(String)) -> Promise(Response(String)) {
  case json.parse(req.body, mcp_request_decoder()) {
    Ok(mcp_req) -> handle_mcp_request(mcp_req)
    Error(_) -> {
      promise.resolve(
        response.new(400)
        |> response.set_body("Invalid JSON"),
      )
    }
  }
}

fn handle_mcp_request(req: McpRequest) -> Promise(Response(String)) {
  case req.method {
    "notifications/initialized" -> {
      promise.resolve(response.new(204) |> response.set_body(""))
    }
    _ -> {
      use response_json <- promise.map(get_response_json(req))
      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(json.to_string(response_json))
    }
  }
}

fn get_response_json(req: McpRequest) -> Promise(json.Json) {
  case req.method {
    "initialize" -> promise.resolve(handle_initialize(req))
    "tools/list" -> promise.resolve(handle_tools_list(req))
    "tools/call" -> handle_tool_call(req)
    "resources/list" -> promise.resolve(handle_resources_list(req))
    "resources/read" -> handle_resource_read(req)
    _ -> promise.resolve(create_error_response(req.id, -32_601, "Method not found"))
  }
}

// ============================================================================
// MCP Protocol Handlers
// ============================================================================

fn handle_initialize(req: McpRequest) -> json.Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(req.id)),
    #(
      "result",
      json.object([
        #("protocolVersion", json.string("2024-11-05")),
        #(
          "capabilities",
          json.object([
            #("tools", json.object([])),
            #("resources", json.object([])),
          ]),
        ),
        #(
          "serverInfo",
          json.object([
            #("name", json.string("gleam-package-mcp")),
            #("version", json.string("2.0.0")),
          ]),
        ),
      ]),
    ),
  ])
}

fn handle_tools_list(req: McpRequest) -> json.Json {
  let tools = [
    tool_definition(
      "search_packages",
      "Search for Gleam packages on hex.pm by name or description",
      [#("query", "string", "Search query for package name or description", True)],
    ),
    tool_definition(
      "get_package_info",
      "Get detailed information about a specific package from hex.pm",
      [#("package_name", "string", "Name of the package", True)],
    ),
    tool_definition(
      "get_modules",
      "Get a list of all modules in a package with their documentation. Fetches from hexdocs.pm",
      [#("package_name", "string", "Name of the package", True)],
    ),
    tool_definition(
      "get_module_info",
      "Get detailed information about a specific module including functions and types",
      [
        #("package_name", "string", "Name of the package containing the module", True),
        #("module_name", "string", "Name of the module (e.g., 'gleam/list')", True),
      ],
    ),
  ]

  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(req.id)),
    #("result", json.object([#("tools", json.preprocessed_array(tools))])),
  ])
}

fn tool_definition(
  name: String,
  description: String,
  params: List(#(String, String, String, Bool)),
) -> json.Json {
  let properties =
    params
    |> list.map(fn(param) {
      let #(param_name, param_type, param_desc, _required) = param
      #(
        param_name,
        json.object([
          #("type", json.string(param_type)),
          #("description", json.string(param_desc)),
        ]),
      )
    })

  let required =
    params
    |> list.filter(fn(p) { p.3 })
    |> list.map(fn(p) { json.string(p.0) })

  json.object([
    #("name", json.string(name)),
    #("description", json.string(description)),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #("properties", json.object(properties)),
        #("required", json.preprocessed_array(required)),
      ]),
    ),
  ])
}

fn handle_tool_call(req: McpRequest) -> Promise(json.Json) {
  case req.params {
    CallToolParams(name: tool_name, arguments: arguments) -> {
      case tool_name {
        "search_packages" -> handle_search_packages(req.id, arguments)
        "get_package_info" -> handle_get_package_info(req.id, arguments)
        "get_modules" -> handle_get_modules(req.id, arguments)
        "get_module_info" -> handle_get_module_info(req.id, arguments)
        _ -> promise.resolve(create_error_response(req.id, -32_602, "Unknown tool: " <> tool_name))
      }
    }
    _ -> promise.resolve(create_error_response(req.id, -32_602, "Invalid params for tools/call"))
  }
}

fn handle_resources_list(req: McpRequest) -> json.Json {
  let resources = [
    json.object([
      #("uri", json.string("gleam://packages")),
      #("name", json.string("Popular Gleam Packages")),
      #("description", json.string("List of popular Gleam packages from hex.pm")),
      #("mimeType", json.string("application/json")),
    ]),
  ]

  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(req.id)),
    #("result", json.object([#("resources", json.preprocessed_array(resources))])),
  ])
}

fn handle_resource_read(req: McpRequest) -> Promise(json.Json) {
  case req.params {
    ReadResourceParams(uri: uri) -> {
      case uri {
        "gleam://packages" -> {
          use result <- promise.map(hex_client.list_gleam_packages())
          case result {
            Ok(packages) -> {
              let package_list =
                packages
                |> list.map(fn(pkg) {
                  json.object([
                    #("name", json.string(pkg.name)),
                    #("version", json.string(pkg.version)),
                    #("description", json.string(pkg.description)),
                    #("downloads", json.int(pkg.downloads)),
                  ])
                })

              json.object([
                #("jsonrpc", json.string("2.0")),
                #("id", json.string(req.id)),
                #(
                  "result",
                  json.object([
                    #(
                      "contents",
                      json.preprocessed_array([
                        json.object([
                          #("uri", json.string(uri)),
                          #("mimeType", json.string("application/json")),
                          #(
                            "text",
                            json.string(
                              json.to_string(
                                json.object([
                                  #("packages", json.preprocessed_array(package_list)),
                                  #("total", json.int(list.length(packages))),
                                ]),
                              ),
                            ),
                          ),
                        ]),
                      ]),
                    ),
                  ]),
                ),
              ])
            }
            Error(err) ->
              create_error_response(
                req.id,
                -32_603,
                "Failed to list packages: " <> hex_client.describe_error(err),
              )
          }
        }
        _ -> promise.resolve(create_error_response(req.id, -32_602, "Unknown resource URI: " <> uri))
      }
    }
    _ -> promise.resolve(create_error_response(req.id, -32_602, "Invalid params for resources/read"))
  }
}

// ============================================================================
// Tool Implementations (Async)
// ============================================================================

fn handle_search_packages(id: String, arguments: ToolArguments) -> Promise(json.Json) {
  case arguments {
    SearchArguments(query: query) -> {
      use result <- promise.map(hex_client.search_packages(query))
      case result {
        Ok(search_result) -> {
          let packages =
            search_result.packages
            |> list.map(fn(pkg) {
              json.object([
                #("name", json.string(pkg.name)),
                #("version", json.string(pkg.version)),
                #("description", json.string(pkg.description)),
                #("downloads", json.int(pkg.downloads)),
                #("docs_url", json.string(pkg.docs_url)),
              ])
            })

          create_tool_result(
            id,
            "Found "
              <> int.to_string(search_result.total)
              <> " packages matching '"
              <> query
              <> "'",
            Some(json.object([#("packages", json.preprocessed_array(packages))])),
          )
        }
        Error(err) ->
          create_error_response(
            id,
            -32_603,
            "Search failed: " <> hex_client.describe_error(err),
          )
      }
    }
    _ -> promise.resolve(create_error_response(id, -32_602, "Invalid arguments for search_packages"))
  }
}

fn handle_get_package_info(id: String, arguments: ToolArguments) -> Promise(json.Json) {
  case arguments {
    PackageArguments(package_name: package_name) -> {
      use result <- promise.map(hex_client.get_package_info(package_name))
      case result {
        Ok(pkg) -> {
          create_tool_result(
            id,
            "Package: "
              <> pkg.name
              <> "\nVersion: "
              <> pkg.version
              <> "\nDescription: "
              <> pkg.description
              <> "\nDownloads: "
              <> int.to_string(pkg.downloads)
              <> "\nDocs: "
              <> pkg.docs_url,
            None,
          )
        }
        Error(err) ->
          create_error_response(
            id,
            -32_603,
            "Package info failed: " <> hex_client.describe_error(err),
          )
      }
    }
    _ -> promise.resolve(create_error_response(id, -32_602, "Invalid arguments for get_package_info"))
  }
}

fn handle_get_modules(id: String, arguments: ToolArguments) -> Promise(json.Json) {
  case arguments {
    PackageArguments(package_name: package_name) -> {
      use result <- promise.map(hex_client.fetch_package_interface(package_name))
      case result {
        Ok(interface) -> {
          let modules =
            interface.modules
            |> list.map(fn(module_info) {
              let types_info =
                module_info.types
                |> list.map(fn(type_info) {
                  json.object([
                    #("name", json.string(type_info.name)),
                    #("signature", json.string(type_info.signature)),
                    #("type_kind", json.string(type_info.type_kind)),
                  ])
                })

              json.object([
                #("name", json.string(module_info.name)),
                #("documentation", json.string(module_info.documentation)),
                #("functions_count", json.int(list.length(module_info.functions))),
                #("types_count", json.int(list.length(module_info.types))),
                #("types", json.preprocessed_array(types_info)),
              ])
            })

          create_tool_result(
            id,
            "Package: "
              <> package_name
              <> " (v"
              <> interface.version
              <> ")\nModules: "
              <> int.to_string(list.length(interface.modules)),
            Some(json.object([#("modules", json.preprocessed_array(modules))])),
          )
        }
        Error(err) ->
          create_error_response(
            id,
            -32_603,
            "Failed to fetch package interface from hexdocs.pm: "
              <> hex_client.describe_error(err),
          )
      }
    }
    _ -> promise.resolve(create_error_response(id, -32_602, "Invalid arguments for get_modules"))
  }
}

fn handle_get_module_info(id: String, arguments: ToolArguments) -> Promise(json.Json) {
  case arguments {
    ModuleArguments(package_name: package_name, module_name: module_name) -> {
      use result <- promise.map(hex_client.fetch_package_interface(package_name))
      case result {
        Ok(interface) -> {
          case interface_parser.get_module_info(interface, module_name) {
            Ok(module_info) -> {
              let functions =
                module_info.functions
                |> list.map(fn(func) {
                  json.object([
                    #("name", json.string(func.name)),
                    #("signature", json.string(func.signature)),
                    #("documentation", json.string(func.documentation)),
                    #(
                      "parameters",
                      json.preprocessed_array(
                        list.map(func.parameters, fn(param) {
                          json.object([
                            #("label", json.string(param.label)),
                            #("type", json.string(param.type_name)),
                          ])
                        }),
                      ),
                    ),
                  ])
                })

              let types =
                module_info.types
                |> list.map(fn(type_info) {
                  json.object([
                    #("name", json.string(type_info.name)),
                    #("signature", json.string(type_info.signature)),
                    #("type_kind", json.string(type_info.type_kind)),
                    #("documentation", json.string(type_info.documentation)),
                  ])
                })

              json.object([
                #("jsonrpc", json.string("2.0")),
                #("id", json.string(id)),
                #(
                  "result",
                  json.object([
                    #(
                      "content",
                      json.preprocessed_array([
                        json.object([
                          #("type", json.string("text")),
                          #(
                            "text",
                            json.string(
                              "Module: "
                                <> module_name
                                <> " (from "
                                <> package_name
                                <> ")\n"
                                <> module_info.documentation
                                <> "\n\nFunctions: "
                                <> int.to_string(list.length(functions))
                                <> "\nTypes: "
                                <> int.to_string(list.length(types)),
                            ),
                          ),
                        ]),
                      ]),
                    ),
                    #("functions", json.preprocessed_array(functions)),
                    #("types", json.preprocessed_array(types)),
                  ]),
                ),
              ])
            }
            Error(err) ->
              create_error_response(id, -32_603, "Module not found: " <> err)
          }
        }
        Error(err) ->
          create_error_response(
            id,
            -32_603,
            "Failed to fetch package interface: " <> hex_client.describe_error(err),
          )
      }
    }
    _ -> promise.resolve(create_error_response(id, -32_602, "Invalid arguments for get_module_info"))
  }
}

// ============================================================================
// Response Helpers
// ============================================================================

fn create_tool_result(
  id: String,
  text: String,
  extra_data: option.Option(json.Json),
) -> json.Json {
  let content = [
    json.object([
      #("type", json.string("text")),
      #("text", json.string(text)),
    ]),
  ]

  let result_fields = case extra_data {
    Some(data) -> [
      #("content", json.preprocessed_array(content)),
      #("data", data),
    ]
    None -> [#("content", json.preprocessed_array(content))]
  }

  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("result", json.object(result_fields)),
  ])
}

fn create_error_response(id: String, code: Int, message: String) -> json.Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #(
      "error",
      json.object([
        #("code", json.int(code)),
        #("message", json.string(message)),
      ]),
    ),
  ])
}

// ============================================================================
// Request Decoders
// ============================================================================

fn mcp_request_decoder() -> decode.Decoder(McpRequest) {
  use jsonrpc <- decode.field("jsonrpc", decode.string)
  use id <- decode.optional_field(
    "id",
    "notification",
    decode.one_of(decode.string, [decode.int |> decode.map(int.to_string)]),
  )
  use method <- decode.field("method", decode.string)
  use params <- decode.optional_field(
    "params",
    ListToolsParams,
    mcp_params_decoder(method),
  )
  decode.success(McpRequest(
    jsonrpc: jsonrpc,
    id: id,
    method: method,
    params: params,
  ))
}

fn mcp_params_decoder(method: String) -> decode.Decoder(McpParams) {
  case method {
    "tools/call" -> {
      use name <- decode.field("name", decode.string)
      use arguments <- decode.field("arguments", tool_arguments_decoder(name))
      decode.success(CallToolParams(name: name, arguments: arguments))
    }
    "tools/list" -> decode.success(ListToolsParams)
    "resources/list" -> decode.success(ListResourcesParams)
    "resources/read" -> {
      use uri <- decode.field("uri", decode.string)
      decode.success(ReadResourceParams(uri: uri))
    }
    "initialize" -> decode.success(InitializeParams)
    _ -> decode.success(ListToolsParams)
  }
}

fn tool_arguments_decoder(tool_name: String) -> decode.Decoder(ToolArguments) {
  case tool_name {
    "search_packages" -> {
      use query <- decode.field("query", decode.string)
      decode.success(SearchArguments(query: query))
    }
    "get_package_info" | "get_modules" -> {
      use package_name <- decode.field("package_name", decode.string)
      decode.success(PackageArguments(package_name: package_name))
    }
    "get_module_info" -> {
      use package_name <- decode.field("package_name", decode.string)
      use module_name <- decode.field("module_name", decode.string)
      decode.success(ModuleArguments(
        package_name: package_name,
        module_name: module_name,
      ))
    }
    _ -> decode.success(SearchArguments(query: ""))
  }
}
