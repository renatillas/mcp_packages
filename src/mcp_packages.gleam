import aide
import aide/definitions
import aide/tool
import clockwork
import clockwork_schedule
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import mcp_packages/doc_builder
import mcp_packages/interface_parser
import mcp_packages/package_manager
import mist
import oas/json_schema
import pack
import simplifile
import wisp
import wisp/wisp_mist

pub type McpRequest {
  McpRequest(jsonrpc: String, id: String, method: String, params: McpParams)
}

pub type McpParams {
  CallToolParams(name: String, arguments: ToolArguments)
  ListToolsParams
  ListResourcesParams
  ReadResourceParams(uri: String)
  InitializeParams(client_info: ClientInfo, capabilities: ClientCapabilities)
}

pub type ToolArguments {
  SearchArguments(query: String)
  PackageArguments(package_name: String)
  ModuleArguments(package_name: String, module_name: String)
}

pub type ClientInfo {
  ClientInfo(name: String, version: String)
}

pub type ClientCapabilities {
  ClientCapabilities(experimental: Bool, sampling: Bool)
}

pub type ToolCall {
  SearchPackages(query: String)
  GetPackageInfo(package_name: String)
  GetModules(package_name: String)
  GetModuleInfo(package_name: String, module_name: String)
}

fn refresh_packages(pack_instance: pack.Pack) -> Result(Nil, String) {
  package_manager.download_packages_to_disc(pack_instance)
}

pub fn main() {
  // Initialize persistent storage directories
  use _ <- result.try(init_persistent_storage())

  use pack_instance <- result.try(package_manager.init_pack())
  let scheduler_receiver = process.new_subject()
  let schedule = clockwork.default() |> clockwork.with_hour(clockwork.every(6))
  let schedule =
    clockwork_schedule.new("data_sync", schedule, fn() {
      let assert Ok(_) = refresh_packages(pack_instance)
      Nil
    })
    |> clockwork_schedule.supervised(scheduler_receiver)

  wisp.configure_logger()

  let server = create_server(pack_instance)
  let handler = mcp_handler(server, pack_instance, _)
  let secret = wisp.random_string(64)

  let server =
    handler
    |> wisp_mist.handler(secret)
    |> mist.new()
    |> mist.bind("0.0.0.0")
    |> mist.port(3000)
    |> mist.supervised()

  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(schedule)
    |> static_supervisor.add(server)
    |> static_supervisor.start()

  Ok(process.sleep_forever())
}

fn create_server(_pack_instance: pack.Pack) -> aide.Server(ToolCall, Nil) {
  let implementation =
    definitions.Implementation(
      name: "gleam-package-mcp",
      title: Some("Gleam Package MCP Server"),
      version: "1.0.0",
    )

  let search_tool_schema =
    json_schema.object([json_schema.field("query", json_schema.string())])

  let info_tool_schema =
    json_schema.object([json_schema.field("package_name", json_schema.string())])

  let modules_tool_schema =
    json_schema.object([json_schema.field("package_name", json_schema.string())])

  let module_info_tool_schema =
    json_schema.object([
      json_schema.field("package_name", json_schema.string()),
      json_schema.field("module_name", json_schema.string()),
    ])

  let search_tool =
    tool.new(
      "search_packages",
      [
        #("query", json_schema.Inline(search_tool_schema), True),
      ],
      [],
    )
    |> tool.set_title("Search Packages")
    |> tool.set_description("Search for Gleam packages by name or description")

  let info_tool =
    tool.new(
      "get_package_info",
      [#("package_name", json_schema.Inline(info_tool_schema), True)],
      [],
    )
    |> tool.set_title("Get Package Info")
    |> tool.set_description("Get detailed information about a specific package")

  let modules_tool =
    tool.new(
      "get_modules",
      [#("package_name", json_schema.Inline(modules_tool_schema), True)],
      [],
    )
    |> tool.set_title("Get Modules")
    |> tool.set_description(
      "Get a list of all modules in a package with their documentation.",
    )

  let module_info_tool =
    tool.new(
      "get_module_info",
      [#("package_name", json_schema.Inline(module_info_tool_schema), True)],
      [],
    )
    |> tool.set_title("Get Module Info")
    |> tool.set_description(
      "Get detailed information about a specific module including functions and types.",
    )

  let packages_resource =
    definitions.Resource(
      meta: None,
      annotations: None,
      description: Some("List of available Gleam packages"),
      mime_type: Some("application/json"),
      name: "packages",
      size: None,
      title: Some("Gleam Packages"),
      uri: "gleam://packages",
    )

  aide.Server(
    implementation: implementation,
    tools: [
      #(search_tool, tool_decoder()),
      #(info_tool, tool_decoder()),
      #(modules_tool, tool_decoder()),
      #(module_info_tool, tool_decoder()),
    ],
    resources: [packages_resource],
    resource_templates: [],
    prompts: [],
  )
}

fn tool_decoder() -> decode.Decoder(ToolCall) {
  use name <- decode.field("name", decode.string)
  case name {
    "search_packages" -> {
      let query_decoder = decode.at(["arguments", "query"], decode.string)
      decode.then(query_decoder, fn(arguments) {
        decode.success(SearchPackages(arguments))
      })
    }
    "get_package_info" -> {
      let query_decoder =
        decode.at(["arguments", "package_name"], decode.string)
      decode.then(query_decoder, fn(arguments) {
        decode.success(GetPackageInfo(arguments))
      })
    }
    "get_modules" -> {
      let query_decoder =
        decode.at(["arguments", "package_name"], decode.string)
      decode.then(query_decoder, fn(arguments) {
        decode.success(GetModules(arguments))
      })
    }
    "get_module_info" -> {
      let package_decoder = decode.at(["arguments", "package_name"], decode.string)
      let module_decoder = decode.at(["arguments", "module_name"], decode.string)
      decode.then(package_decoder, fn(package_name) {
        decode.then(module_decoder, fn(module_name) {
          decode.success(GetModuleInfo(package_name, module_name))
        })
      })
    }
    _ ->
      decode.failure(SearchPackages("Unknown tool name"), "Unknown tool name")
  }
}

fn mcp_handler(
  server: aide.Server(ToolCall, Nil),
  pack_instance: pack.Pack,
  req: wisp.Request,
) -> wisp.Response {
  use <- wisp.log_request(req)
  use body <- wisp.require_string_body(req)
  case req.method {
    http.Post -> {
      case json.parse(body, mcp_request_decoder()) {
        Ok(json_data) -> {
          // Handle MCP JSON-RPC request
          handle_mcp_request(server, pack_instance, json_data)
        }
        Error(_) -> {
          response.new(400)
          |> response.set_body(wisp.Text("Invalid JSON"))
        }
      }
    }
    _ -> {
      response.new(405)
      |> response.set_body(wisp.Text("Method not allowed"))
    }
  }
}

fn mcp_request_decoder() -> decode.Decoder(McpRequest) {
  use jsonrpc <- decode.field("jsonrpc", decode.string)
  use id <- decode.optional_field(
    "id",
    "notification",
    decode.one_of(decode.string, [
      decode.int |> decode.map(int.to_string),
    ]),
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
    "initialize" -> {
      use client_info <- decode.field("clientInfo", client_info_decoder())
      use capabilities <- decode.field(
        "capabilities",
        client_capabilities_decoder(),
      )
      // Ignore protocolVersion field for now
      decode.success(InitializeParams(
        client_info: client_info,
        capabilities: capabilities,
      ))
    }
    _ -> decode.failure(ListToolsParams, "Unknown method: " <> method)
  }
}

fn tool_arguments_decoder(tool_name: String) -> decode.Decoder(ToolArguments) {
  case tool_name {
    "search_packages" -> {
      use query <- decode.field("query", decode.string)
      decode.success(SearchArguments(query: query))
    }
    "get_package_info" -> {
      use package_name <- decode.field("package_name", decode.string)
      decode.success(PackageArguments(package_name: package_name))
    }
    "get_modules" -> {
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
    _ -> decode.failure(SearchArguments(""), "Unknown tool: " <> tool_name)
  }
}

fn client_info_decoder() -> decode.Decoder(ClientInfo) {
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.string)
  decode.success(ClientInfo(name: name, version: version))
}

fn client_capabilities_decoder() -> decode.Decoder(ClientCapabilities) {
  use experimental <- decode.optional_field("experimental", False, decode.bool)
  use sampling <- decode.optional_field("sampling", False, decode.bool)
  // Ignore other fields like "roots" that Claude Code might send
  decode.success(ClientCapabilities(
    experimental: experimental,
    sampling: sampling,
  ))
}

fn handle_mcp_request(
  server: aide.Server(ToolCall, Nil),
  pack_instance: pack.Pack,
  json_data: McpRequest,
) -> Response(wisp.Body) {
  case json_data.method {
    "notifications/initialized" -> {
      // Acknowledge notification - no response needed for notifications
      wisp.no_content()
    }
    _ -> {
      let response_json = case json_data.method {
        "initialize" -> handle_initialize(json_data)
        "tools/list" -> handle_tools_list(server, json_data)
        "tools/call" -> handle_tool_call(pack_instance, json_data)
        "resources/list" -> handle_resources_list(server, json_data)
        "resources/read" -> handle_resource_read(pack_instance, json_data)
        _ ->
          create_error_response(json_data.id, -32_601, "Method not found", None)
      }

      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(wisp.Text(json.to_string(response_json)))
    }
  }
}

fn create_error_response(
  id: String,
  code: Int,
  message: String,
  data: option.Option(json.Json),
) -> json.Json {
  let error_data = case data {
    Some(d) -> [#("data", d)]
    None -> []
  }
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #(
      "error",
      json.object(
        [#("code", json.int(code)), #("message", json.string(message))]
        |> list.append(error_data),
      ),
    ),
  ])
}

fn handle_initialize(json_data: McpRequest) -> json.Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(json_data.id)),
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
            #("version", json.string("1.0.0")),
          ]),
        ),
      ]),
    ),
  ])
}

fn handle_tools_list(
  _server: aide.Server(ToolCall, Nil),
  json_data: McpRequest,
) -> json.Json {
  let tools = [
    json.object([
      #("name", json.string("search_packages")),
      #(
        "description",
        json.string("Search for Gleam packages by name or description"),
      ),
      #(
        "inputSchema",
        json.object([
          #("type", json.string("object")),
          #(
            "properties",
            json.object([
              #(
                "query",
                json.object([
                  #("type", json.string("string")),
                  #(
                    "description",
                    json.string("Search query for package name or description"),
                  ),
                ]),
              ),
            ]),
          ),
          #("required", json.preprocessed_array([json.string("query")])),
        ]),
      ),
    ]),
    json.object([
      #("name", json.string("get_package_info")),
      #(
        "description",
        json.string("Get detailed information about a specific package"),
      ),
      #(
        "inputSchema",
        json.object([
          #("type", json.string("object")),
          #(
            "properties",
            json.object([
              #(
                "package_name",
                json.object([
                  #("type", json.string("string")),
                  #(
                    "description",
                    json.string("Name of the package to get information for"),
                  ),
                ]),
              ),
            ]),
          ),
          #("required", json.preprocessed_array([json.string("package_name")])),
        ]),
      ),
    ]),
    json.object([
      #("name", json.string("get_modules")),
      #(
        "description",
        json.string("Get a list of all modules in a package with their documentation."),
      ),
      #(
        "inputSchema",
        json.object([
          #("type", json.string("object")),
          #(
            "properties",
            json.object([
              #(
                "package_name",
                json.object([
                  #("type", json.string("string")),
                  #(
                    "description",
                    json.string("Name of the package to get modules for"),
                  ),
                ]),
              ),
            ]),
          ),
          #("required", json.preprocessed_array([json.string("package_name")])),
        ]),
      ),
    ]),
    json.object([
      #("name", json.string("get_module_info")),
      #(
        "description",
        json.string(
          "Get detailed information about a specific module including functions and types.",
        ),
      ),
      #(
        "inputSchema",
        json.object([
          #("type", json.string("object")),
          #(
            "properties",
            json.object([
              #(
                "package_name",
                json.object([
                  #("type", json.string("string")),
                  #(
                    "description",
                    json.string("Name of the package containing the module"),
                  ),
                ]),
              ),
              #(
                "module_name",
                json.object([
                  #("type", json.string("string")),
                  #(
                    "description",
                    json.string("Name of the module to get information for"),
                  ),
                ]),
              ),
            ]),
          ),
          #(
            "required",
            json.preprocessed_array([
              json.string("package_name"),
              json.string("module_name"),
            ]),
          ),
        ]),
      ),
    ]),
  ]

  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(json_data.id)),
    #("result", json.object([#("tools", json.preprocessed_array(tools))])),
  ])
}

fn handle_tool_call(
  pack_instance: pack.Pack,
  json_data: McpRequest,
) -> json.Json {
  case json_data.params {
    CallToolParams(name: tool_name, arguments: arguments) -> {
      case tool_name {
        "search_packages" ->
          handle_search_packages(pack_instance, json_data.id, arguments)
        "get_package_info" ->
          handle_get_package_info(pack_instance, json_data.id, arguments)
        "get_modules" ->
          handle_get_modules(pack_instance, json_data.id, arguments)
        "get_module_info" ->
          handle_get_module_info(pack_instance, json_data.id, arguments)
        _ ->
          create_error_response(
            json_data.id,
            -32_602,
            "Unknown tool: " <> tool_name,
            None,
          )
      }
    }
    _ ->
      create_error_response(
        json_data.id,
        -32_602,
        "Invalid params for tools/call",
        None,
      )
  }
}

fn handle_search_packages(
  pack_instance: pack.Pack,
  id: String,
  arguments: ToolArguments,
) -> json.Json {
  case arguments {
    SearchArguments(query: query) -> {
      case package_manager.search_packages(pack_instance, query) {
        Ok(search_result) -> {
          let packages =
            search_result.packages
            |> list.map(fn(pkg) {
              json.object([
                #("name", json.string(pkg.name)),
                #("version", json.string(pkg.version)),
                #("description", json.string(pkg.description)),
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
                          "Found "
                          <> string.inspect(search_result.total)
                          <> " packages matching '"
                          <> query
                          <> "'",
                        ),
                      ),
                      #("packages", json.preprocessed_array(packages)),
                    ]),
                  ]),
                ),
              ]),
            ),
          ])
        }
        Error(err) ->
          create_error_response(id, -32_603, "Search failed: " <> err, None)
      }
    }
    _ ->
      create_error_response(
        id,
        -32_602,
        "Invalid arguments for search_packages",
        None,
      )
  }
}

fn handle_get_package_info(
  pack_instance: pack.Pack,
  id: String,
  arguments: ToolArguments,
) -> json.Json {
  case arguments {
    PackageArguments(package_name: package_name) -> {
      case package_manager.get_package_info(pack_instance, package_name) {
        Ok(pkg) -> {
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
                          "Package: "
                          <> pkg.name
                          <> "\nVersion: "
                          <> pkg.version
                          <> "\nDescription: "
                          <> pkg.description,
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
            id,
            -32_603,
            "Package info failed: " <> err,
            None,
          )
      }
    }
    _ ->
      create_error_response(
        id,
        -32_602,
        "Invalid arguments for get_package_info",
        None,
      )
  }
}

fn handle_get_modules(
  pack_instance: pack.Pack,
  id: String,
  arguments: ToolArguments,
) -> json.Json {
  case arguments {
    PackageArguments(package_name: package_name) -> {
      let packages_dir = package_manager.get_packages_directory(pack_instance)
      let package_path = packages_dir <> "/" <> package_name

      // Check if directory exists
      case simplifile.is_directory(package_path) {
        Ok(_) -> {
          case doc_builder.build_package_docs(package_path, package_name) {
            Ok(doc_result) -> {
              case doc_result.success {
                True -> {
                  case interface_parser.parse_package_interface(
                    doc_result.interface_json_path,
                  ) {
                    Ok(interface) -> {
                      let modules =
                        interface.modules
                        |> list.map(fn(module_info) {
                          json.object([
                            #("name", json.string(module_info.name)),
                            #(
                              "documentation",
                              json.string(module_info.documentation),
                            ),
                            #(
                              "functions_count",
                              json.int(list.length(module_info.functions)),
                            ),
                            #(
                              "types_count",
                              json.int(list.length(module_info.types)),
                            ),
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
                                      "Package: "
                                      <> package_name
                                      <> "\nModules: "
                                      <> string.inspect(list.length(interface.modules)),
                                    ),
                                  ),
                                ]),
                              ]),
                            ),
                            #("modules", json.preprocessed_array(modules)),
                          ]),
                        ),
                      ])
                    }
                    Error(err) ->
                      create_error_response(
                        id,
                        -32_603,
                        "Failed to parse package interface: " <> err,
                        None,
                      )
                  }
                }
                False ->
                  create_error_response(
                    id,
                    -32_603,
                    "Documentation build failed: " <> doc_result.error_message,
                    None,
                  )
              }
            }
            Error(err) ->
              create_error_response(
                id,
                -32_603,
                "Documentation build failed: " <> err,
                None,
              )
          }
        }
        Error(_) ->
          create_error_response(
            id,
            -32_603,
            "Package directory not found: " <> package_path,
            None,
          )
      }
    }
    _ ->
      create_error_response(
        id,
        -32_602,
        "Invalid arguments for get_modules",
        None,
      )
  }
}

fn handle_get_module_info(
  pack_instance: pack.Pack,
  id: String,
  arguments: ToolArguments,
) -> json.Json {
  case arguments {
    ModuleArguments(package_name: package_name, module_name: module_name) -> {
      let packages_dir = package_manager.get_packages_directory(pack_instance)
      let package_path = packages_dir <> "/" <> package_name

      case simplifile.is_directory(package_path) {
        Ok(_) -> {
          case doc_builder.build_package_docs(package_path, package_name) {
            Ok(doc_result) -> {
              case doc_result.success {
                True -> {
                  case interface_parser.parse_package_interface(
                    doc_result.interface_json_path,
                  ) {
                    Ok(interface) -> {
                      case interface_parser.get_module_info(interface, module_name) {
                        Ok(module_info) -> {
                          let functions =
                            module_info.functions
                            |> list.map(fn(func) {
                              json.object([
                                #("name", json.string(func.name)),
                                #("signature", json.string(func.signature)),
                                #(
                                  "documentation",
                                  json.string(func.documentation),
                                ),
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
                                #(
                                  "documentation",
                                  json.string(type_info.documentation),
                                ),
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
                                          <> string.inspect(list.length(functions))
                                          <> "\nTypes: "
                                          <> string.inspect(list.length(types)),
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
                          create_error_response(
                            id,
                            -32_603,
                            "Module not found: " <> err,
                            None,
                          )
                      }
                    }
                    Error(err) ->
                      create_error_response(
                        id,
                        -32_603,
                        "Failed to parse package interface: " <> err,
                        None,
                      )
                  }
                }
                False ->
                  create_error_response(
                    id,
                    -32_603,
                    "Documentation build failed: " <> doc_result.error_message,
                    None,
                  )
              }
            }
            Error(err) ->
              create_error_response(
                id,
                -32_603,
                "Documentation build failed: " <> err,
                None,
              )
          }
        }
        Error(_) ->
          create_error_response(
            id,
            -32_603,
            "Package directory not found: " <> package_path,
            None,
          )
      }
    }
    _ ->
      create_error_response(
        id,
        -32_602,
        "Invalid arguments for get_module_info",
        None,
      )
  }
}

fn handle_resources_list(
  _server: aide.Server(ToolCall, Nil),
  json_data: McpRequest,
) -> json.Json {
  let resources = [
    json.object([
      #("uri", json.string("gleam://packages")),
      #("name", json.string("Gleam Packages")),
      #("description", json.string("List of available Gleam packages")),
      #("mimeType", json.string("application/json")),
    ]),
  ]

  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(json_data.id)),
    #(
      "result",
      json.object([#("resources", json.preprocessed_array(resources))]),
    ),
  ])
}

fn handle_resource_read(
  pack_instance: pack.Pack,
  json_data: McpRequest,
) -> json.Json {
  case json_data.params {
    ReadResourceParams(uri: uri) -> {
      case uri {
        "gleam://packages" -> {
          case package_manager.list_available_packages(pack_instance) {
            Ok(packages) -> {
              let package_list =
                packages
                |> list.map(fn(pkg) {
                  json.object([
                    #("name", json.string(pkg.name)),
                    #("version", json.string(pkg.version)),
                    #("description", json.string(pkg.description)),
                  ])
                })

              json.object([
                #("jsonrpc", json.string("2.0")),
                #("id", json.string(json_data.id)),
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
                                  #(
                                    "packages",
                                    json.preprocessed_array(package_list),
                                  ),
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
                json_data.id,
                -32_603,
                "Failed to list packages: " <> err,
                None,
              )
          }
        }
        _ ->
          create_error_response(
            json_data.id,
            -32_602,
            "Unknown resource URI: " <> uri,
            None,
          )
      }
    }
    _ ->
      create_error_response(
        json_data.id,
        -32_602,
        "Invalid params for resources/read",
        None,
      )
  }
}


fn init_persistent_storage() -> Result(Nil, String) {
  // Initialize docs cache directory
  case doc_builder.ensure_docs_directory() {
    Ok(_) -> Ok(Nil)
    Error(err) -> Error("Failed to initialize docs cache: " <> err)
  }
}
