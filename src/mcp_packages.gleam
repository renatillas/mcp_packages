import conversation.{type JsRequest, type JsResponse, Text}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import mcp_packages/cache
import mcp_packages/hex_client
import mcp_packages/interface_parser
import mcp_packages/logger
import plinth/cloudflare/bindings
import plinth/cloudflare/d1.{type Database}
import plinth/cloudflare/worker.{type Context}
import plinth/javascript/date

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
  PackageSearchArguments(package_name: String, query: String)
}

/// Worker context with database and execution context
pub type WorkerContext {
  WorkerContext(db: Option(Database), ctx: Option(Context))
}

// ============================================================================
// Cloudflare Worker Entry Point
// ============================================================================

/// Main fetch handler for Cloudflare Workers
/// Uses conversation to handle JS <-> Gleam conversions
pub fn fetch(
  js_request: JsRequest,
  env: dynamic.Dynamic,
  ctx: Context,
) -> Promise(JsResponse) {
  let request = conversation.to_gleam_request(js_request)
  logger.request(http.method_to_string(request.method), request.path)

  // Extract D1 database from env bindings
  let db = bindings.d1_database(env, "DB") |> option.from_result
  let worker_ctx = WorkerContext(db: db, ctx: Some(ctx))

  case request.method {
    http.Post -> {
      use body_result <- promise.await(conversation.read_text(request.body))
      case body_result {
        Ok(body) -> handle_post_body(body, worker_ctx)
        Error(_) -> {
          logger.error("Failed to read request body")
          promise.resolve(
            response.new(400)
            |> response.set_body(Text("Failed to read request body"))
            |> conversation.to_js_response,
          )
        }
      }
    }
    _ -> {
      logger.warn("Method not allowed: " <> http.method_to_string(request.method))
      promise.resolve(
        response.new(405)
        |> response.set_body(Text("Method not allowed"))
        |> conversation.to_js_response,
      )
    }
  }
}

fn handle_post_body(body: String, ctx: WorkerContext) -> Promise(JsResponse) {
  case json.parse(body, mcp_request_decoder()) {
    Ok(mcp_req) -> handle_mcp_request(mcp_req, ctx)
    Error(_) -> {
      logger.error("Invalid JSON in request body")
      promise.resolve(
        response.new(400)
        |> response.set_body(Text("Invalid JSON"))
        |> conversation.to_js_response,
      )
    }
  }
}

fn handle_mcp_request(
  req: McpRequest,
  ctx: WorkerContext,
) -> Promise(JsResponse) {
  case req.method {
    "notifications/initialized" -> {
      promise.resolve(
        response.new(204)
        |> response.set_body(Text(""))
        |> conversation.to_js_response,
      )
    }
    _ -> {
      use response_json <- promise.map(get_response_json(req, ctx))
      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(Text(json.to_string(response_json)))
      |> conversation.to_js_response
    }
  }
}

fn get_response_json(req: McpRequest, ctx: WorkerContext) -> Promise(json.Json) {
  logger.mcp_method(req.method, req.id)
  case req.method {
    "initialize" -> handle_initialize(req, ctx)
    "tools/list" -> handle_tools_list(req)
    "tools/call" -> handle_tool_call(req, ctx)
    "resources/list" -> promise.resolve(handle_resources_list(req))
    "resources/read" -> handle_resource_read(req, ctx)
    _ -> {
      logger.warn("Unknown MCP method: " <> req.method)
      promise.resolve(create_error_response(req.id, -32_601, "Method not found"))
    }
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Get current Unix timestamp in seconds
fn now_seconds() -> Int {
  date.now() |> date.get_time |> fn(ms) { ms / 1000 }
}

/// Schedule a background task using wait_until
fn schedule_background(ctx: WorkerContext, task: Promise(a)) -> Nil {
  case ctx.ctx {
    Some(worker_ctx) -> worker.wait_until(worker_ctx, task)
    None -> Nil
  }
}

// ============================================================================
// MCP Protocol Handlers
// ============================================================================

fn handle_initialize(req: McpRequest, _ctx: WorkerContext) -> Promise(json.Json) {
  promise.resolve(
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
              #("version", json.string("2.1.0")),
            ]),
          ),
        ]),
      ),
    ]),
  )
}

fn handle_tools_list(req: McpRequest) -> Promise(json.Json) {
  let tools = [
    tool_definition(
      "search_packages",
      "Search for Gleam packages on hex.pm by name or description",
      [
        #(
          "query",
          "string",
          "Search query for package name or description",
          True,
        ),
      ],
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
        #(
          "package_name",
          "string",
          "Name of the package containing the module",
          True,
        ),
        #(
          "module_name",
          "string",
          "Name of the module (e.g., 'gleam/list')",
          True,
        ),
      ],
    ),
    tool_definition(
      "search_functions",
      "Search for functions within a package by name or documentation",
      [
        #("package_name", "string", "Name of the package to search in", True),
        #(
          "query",
          "string",
          "Search query to match against function names and documentation",
          True,
        ),
      ],
    ),
    tool_definition(
      "search_types",
      "Search for types within a package by name or documentation",
      [
        #("package_name", "string", "Name of the package to search in", True),
        #(
          "query",
          "string",
          "Search query to match against type names and documentation",
          True,
        ),
      ],
    ),
    tool_definition(
      "get_package_releases",
      "Get all releases for a package with version history and retirement info",
      [#("package_name", "string", "Name of the package", True)],
    ),
  ]

  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(req.id)),
    #("result", json.object([#("tools", json.preprocessed_array(tools))])),
  ])
  |> promise.resolve
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

fn handle_tool_call(req: McpRequest, ctx: WorkerContext) -> Promise(json.Json) {
  case req.params {
    CallToolParams(name: tool_name, arguments: arguments) -> {
      logger.tool_call(tool_name)
      case tool_name {
        "search_packages" -> handle_search_packages(req.id, arguments, ctx)
        "get_package_info" -> handle_get_package_info(req.id, arguments, ctx)
        "get_modules" -> handle_get_modules(req.id, arguments, ctx)
        "get_module_info" -> handle_get_module_info(req.id, arguments, ctx)
        "search_functions" -> handle_search_functions(req.id, arguments, ctx)
        "search_types" -> handle_search_types(req.id, arguments, ctx)
        "get_package_releases" -> handle_get_package_releases(req.id, arguments, ctx)
        _ -> {
          logger.warn("Unknown tool requested: " <> tool_name)
          promise.resolve(create_error_response(
            req.id,
            -32_602,
            "Unknown tool: " <> tool_name,
          ))
        }
      }
    }
    _ -> {
      logger.error("Invalid params for tools/call")
      promise.resolve(create_error_response(
        req.id,
        -32_602,
        "Invalid params for tools/call",
      ))
    }
  }
}

fn handle_resources_list(req: McpRequest) -> json.Json {
  let resources = [
    json.object([
      #("uri", json.string("gleam://packages")),
      #("name", json.string("Popular Gleam Packages")),
      #(
        "description",
        json.string("List of popular Gleam packages from hex.pm"),
      ),
      #("mimeType", json.string("application/json")),
    ]),
  ]

  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(req.id)),
    #(
      "result",
      json.object([#("resources", json.preprocessed_array(resources))]),
    ),
  ])
}

fn handle_resource_read(
  req: McpRequest,
  _ctx: WorkerContext,
) -> Promise(json.Json) {
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
            Error(err) -> {
              logger.error(
                "Failed to list packages: " <> hex_client.describe_error(err),
              )
              create_error_response(
                req.id,
                -32_603,
                "Failed to list packages: " <> hex_client.describe_error(err),
              )
            }
          }
        }
        _ ->
          promise.resolve(create_error_response(
            req.id,
            -32_602,
            "Unknown resource URI: " <> uri,
          ))
      }
    }
    _ ->
      promise.resolve(create_error_response(
        req.id,
        -32_602,
        "Invalid params for resources/read",
      ))
  }
}

// ============================================================================
// Tool Implementations with Caching
// ============================================================================

fn handle_search_packages(
  id: String,
  arguments: ToolArguments,
  ctx: WorkerContext,
) -> Promise(json.Json) {
  case arguments {
    SearchArguments(query: query) -> {
      let cache_key = cache.package_search_key(query)
      let now = now_seconds()

      // Try cache first
      case ctx.db {
        Some(db) -> {
          use cached <- promise.await(cache.get(db, cache_key, now))
          case cached {
            Some(cached_json) -> {
              logger.cache_hit(cache_key)
              // Cache hit - parse and return
              case
                json.parse(
                  cached_json,
                  hex_client.package_search_result_decoder(),
                )
              {
                Ok(search_result) -> {
                  promise.resolve(format_search_result(id, query, search_result))
                }
                Error(_) -> fetch_and_cache_search(id, query, ctx)
              }
            }
            None -> {
              logger.cache_miss(cache_key)
              fetch_and_cache_search(id, query, ctx)
            }
          }
        }
        None -> fetch_and_cache_search(id, query, ctx)
      }
    }
    _ ->
      promise.resolve(create_error_response(
        id,
        -32_602,
        "Invalid arguments for search_packages",
      ))
  }
}

fn fetch_and_cache_search(
  id: String,
  query: String,
  ctx: WorkerContext,
) -> Promise(json.Json) {
  use result <- promise.map(hex_client.search_packages(query))
  case result {
    Ok(search_result) -> {
      // Cache in background
      case ctx.db {
        Some(db) -> {
          let cache_key = cache.package_search_key(query)
          let cache_value = encode_search_result(search_result)
          schedule_background(
            ctx,
            cache.set(
              db,
              cache_key,
              cache_value,
              now_seconds(),
              cache.default_ttl,
            ),
          )
        }
        None -> Nil
      }
      format_search_result(id, query, search_result)
    }
    Error(err) -> {
      logger.error("Search failed: " <> hex_client.describe_error(err))
      create_error_response(
        id,
        -32_603,
        "Search failed: " <> hex_client.describe_error(err),
      )
    }
  }
}

fn format_search_result(
  id: String,
  query: String,
  search_result: hex_client.PackageSearchResult,
) -> json.Json {
  let packages =
    search_result.packages
    |> list.map(fn(pkg) {
      json.object([
        #("name", json.string(pkg.name)),
        #("version", json.string(pkg.version)),
        #("description", json.string(pkg.description)),
        #("downloads", json.int(pkg.downloads)),
        #("docs_url", json.string(pkg.docs_url)),
        #("licenses", json.array(pkg.licenses, json.string)),
        #("repository_url", json.string(pkg.repository_url)),
        #("hex_url", json.string(pkg.hex_url)),
      ])
    })

  let package_list_text =
    search_result.packages
    |> list.map(fn(pkg) {
      "- "
      <> pkg.name
      <> " v"
      <> pkg.version
      <> " ("
      <> int.to_string(pkg.downloads)
      <> " downloads)\n  "
      <> pkg.description
    })
    |> string.join("\n")

  create_tool_result(
    id,
    "Found "
      <> int.to_string(search_result.total)
      <> " packages matching '"
      <> query
      <> "':\n\n"
      <> package_list_text,
    Some(json.object([#("packages", json.preprocessed_array(packages))])),
  )
}

fn handle_get_package_info(
  id: String,
  arguments: ToolArguments,
  ctx: WorkerContext,
) -> Promise(json.Json) {
  case arguments {
    PackageArguments(package_name: package_name) -> {
      let cache_key = cache.package_info_key(package_name)
      let now = now_seconds()

      case ctx.db {
        Some(db) -> {
          use cached <- promise.await(cache.get(db, cache_key, now))
          case cached {
            Some(cached_json) -> {
              logger.cache_hit(cache_key)
              case json.parse(cached_json, package_decoder()) {
                Ok(pkg) -> promise.resolve(format_package_info(id, pkg))
                Error(_) -> fetch_and_cache_package_info(id, package_name, ctx)
              }
            }
            None -> {
              logger.cache_miss(cache_key)
              fetch_and_cache_package_info(id, package_name, ctx)
            }
          }
        }
        None -> fetch_and_cache_package_info(id, package_name, ctx)
      }
    }
    _ ->
      promise.resolve(create_error_response(
        id,
        -32_602,
        "Invalid arguments for get_package_info",
      ))
  }
}

fn fetch_and_cache_package_info(
  id: String,
  package_name: String,
  ctx: WorkerContext,
) -> Promise(json.Json) {
  use result <- promise.map(hex_client.get_package_info(package_name))
  case result {
    Ok(pkg) -> {
      case ctx.db {
        Some(db) -> {
          let cache_key = cache.package_info_key(package_name)
          let cache_value = encode_package(pkg)
          schedule_background(
            ctx,
            cache.set(
              db,
              cache_key,
              cache_value,
              now_seconds(),
              cache.default_ttl,
            ),
          )
        }
        None -> Nil
      }
      format_package_info(id, pkg)
    }
    Error(err) -> {
      logger.error("Package info failed: " <> hex_client.describe_error(err))
      create_error_response(
        id,
        -32_603,
        "Package info failed: " <> hex_client.describe_error(err),
      )
    }
  }
}

fn handle_get_package_releases(
  id: String,
  arguments: ToolArguments,
  _ctx: WorkerContext,
) -> Promise(json.Json) {
  case arguments {
    PackageArguments(package_name: package_name) -> {
      use result <- promise.map(hex_client.get_package_releases(package_name))
      case result {
        Ok(releases_info) -> format_package_releases(id, releases_info)
        Error(err) -> {
          logger.error(
            "Failed to fetch releases: " <> hex_client.describe_error(err),
          )
          create_error_response(
            id,
            -32_603,
            "Failed to fetch releases: " <> hex_client.describe_error(err),
          )
        }
      }
    }
    _ ->
      promise.resolve(create_error_response(
        id,
        -32_602,
        "Invalid arguments for get_package_releases",
      ))
  }
}

fn format_package_releases(
  id: String,
  releases_info: hex_client.PackageReleases,
) -> json.Json {
  let releases_json =
    releases_info.releases
    |> list.map(fn(release) {
      let base_fields = [
        #("version", json.string(release.version)),
        #("inserted_at", json.string(release.inserted_at)),
        #("has_docs", json.bool(release.has_docs)),
      ]
      let fields = case release.retirement {
        Some(retirement) ->
          list.append(base_fields, [
            #("retired", json.bool(True)),
            #("retirement_reason", json.string(retirement.reason)),
            #("retirement_message", json.string(retirement.message)),
          ])
        None -> list.append(base_fields, [#("retired", json.bool(False))])
      }
      json.object(fields)
    })

  let releases_text =
    releases_info.releases
    |> list.map(fn(release) {
      let retired_notice = case release.retirement {
        Some(retirement) ->
          " [RETIRED: "
          <> retirement.reason
          <> case retirement.message {
            "" -> ""
            msg -> " - " <> msg
          }
          <> "]"
        None -> ""
      }
      let docs_notice = case release.has_docs {
        True -> ""
        False -> " (no docs)"
      }
      "- v"
      <> release.version
      <> " ("
      <> string.slice(release.inserted_at, 0, 10)
      <> ")"
      <> retired_notice
      <> docs_notice
    })
    |> string.join("\n")

  let retired_count =
    releases_info.releases
    |> list.filter(fn(r) { option.is_some(r.retirement) })
    |> list.length

  create_tool_result(
    id,
    "Package: "
      <> releases_info.name
      <> "\nTotal releases: "
      <> int.to_string(list.length(releases_info.releases))
      <> "\nRetired releases: "
      <> int.to_string(retired_count)
      <> "\n\nVersions:\n"
      <> releases_text,
    Some(
      json.object([
        #("name", json.string(releases_info.name)),
        #("total", json.int(list.length(releases_info.releases))),
        #("retired_count", json.int(retired_count)),
        #("releases", json.preprocessed_array(releases_json)),
      ]),
    ),
  )
}

fn format_package_info(id: String, pkg: hex_client.Package) -> json.Json {
  let licenses_text = case pkg.licenses {
    [] -> "Not specified"
    licenses -> string.join(licenses, ", ")
  }

  let repo_text = case pkg.repository_url {
    "" -> "Not specified"
    url -> url
  }

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
      <> "\nLicenses: "
      <> licenses_text
      <> "\nRepository: "
      <> repo_text
      <> "\nDocs: "
      <> pkg.docs_url
      <> "\nHex: "
      <> pkg.hex_url,
    Some(
      json.object([
        #("name", json.string(pkg.name)),
        #("version", json.string(pkg.version)),
        #("description", json.string(pkg.description)),
        #("downloads", json.int(pkg.downloads)),
        #("licenses", json.array(pkg.licenses, json.string)),
        #("repository_url", json.string(pkg.repository_url)),
        #("docs_url", json.string(pkg.docs_url)),
        #("hex_url", json.string(pkg.hex_url)),
      ]),
    ),
  )
}

fn handle_get_modules(
  id: String,
  arguments: ToolArguments,
  ctx: WorkerContext,
) -> Promise(json.Json) {
  case arguments {
    PackageArguments(package_name: package_name) -> {
      let cache_key = cache.package_interface_key(package_name)
      let now = now_seconds()

      case ctx.db {
        Some(db) -> {
          use cached <- promise.await(cache.get(db, cache_key, now))
          case cached {
            Some(cached_json) -> {
              logger.cache_hit(cache_key)
              case interface_parser.parse_package_interface(cached_json) {
                Ok(interface) ->
                  promise.resolve(format_modules(id, package_name, interface))
                Error(_) ->
                  fetch_and_cache_interface_for_modules(id, package_name, ctx)
              }
            }
            None -> {
              logger.cache_miss(cache_key)
              fetch_and_cache_interface_for_modules(id, package_name, ctx)
            }
          }
        }
        None -> fetch_and_cache_interface_for_modules(id, package_name, ctx)
      }
    }
    _ ->
      promise.resolve(create_error_response(
        id,
        -32_602,
        "Invalid arguments for get_modules",
      ))
  }
}

fn fetch_and_cache_interface_for_modules(
  id: String,
  package_name: String,
  _ctx: WorkerContext,
) -> Promise(json.Json) {
  use result <- promise.map(hex_client.fetch_package_interface(package_name))
  case result {
    Ok(interface) -> {
      // Cache the raw interface JSON in background
      // Note: We'd need to store the raw JSON, but we only have the parsed interface
      // For now, we skip caching here since we don't have the raw JSON
      format_modules(id, package_name, interface)
    }
    Error(err) -> {
      logger.error(
        "Failed to fetch package interface: " <> hex_client.describe_error(err),
      )
      create_error_response(
        id,
        -32_603,
        "Failed to fetch package interface from hexdocs.pm: "
          <> hex_client.describe_error(err),
      )
    }
  }
}

fn format_modules(
  id: String,
  package_name: String,
  interface: interface_parser.PackageInterface,
) -> json.Json {
  let modules =
    interface.modules
    |> list.map(fn(module_info) {
      let types_info =
        module_info.types
        |> list.map(fn(type_info) {
          let base_fields = [
            #("name", json.string(type_info.name)),
            #("signature", json.string(type_info.signature)),
            #("type_kind", json.string(type_info.type_kind)),
          ]
          let fields = case type_info.deprecation {
            Some(msg) -> list.append(base_fields, [#("deprecation", json.string(msg))])
            None -> base_fields
          }
          json.object(fields)
        })

      json.object([
        #("name", json.string(module_info.name)),
        #("documentation", json.string(module_info.documentation)),
        #("functions_count", json.int(list.length(module_info.functions))),
        #("types_count", json.int(list.length(module_info.types))),
        #("constants_count", json.int(list.length(module_info.constants))),
        #("type_aliases_count", json.int(list.length(module_info.type_aliases))),
        #("types", json.preprocessed_array(types_info)),
      ])
    })

  let module_list_text =
    interface.modules
    |> list.map(fn(m) {
      let extras = case list.length(m.constants), list.length(m.type_aliases) {
        0, 0 -> ""
        c, 0 -> ", " <> int.to_string(c) <> " constants"
        0, a -> ", " <> int.to_string(a) <> " type aliases"
        c, a ->
          ", "
          <> int.to_string(c)
          <> " constants, "
          <> int.to_string(a)
          <> " type aliases"
      }
      "- "
      <> m.name
      <> " ("
      <> int.to_string(list.length(m.functions))
      <> " functions, "
      <> int.to_string(list.length(m.types))
      <> " types"
      <> extras
      <> ")"
    })
    |> string.join("\n")

  let gleam_constraint_text = case interface.gleam_version_constraint {
    "" -> ""
    constraint -> "\nGleam version: " <> constraint
  }

  create_tool_result(
    id,
    "Package: "
      <> package_name
      <> " (v"
      <> interface.version
      <> ")"
      <> gleam_constraint_text
      <> "\n\nModules:\n"
      <> module_list_text,
    Some(
      json.object([
        #("version", json.string(interface.version)),
        #("gleam_version_constraint", json.string(interface.gleam_version_constraint)),
        #("modules", json.preprocessed_array(modules)),
      ]),
    ),
  )
}

fn handle_get_module_info(
  id: String,
  arguments: ToolArguments,
  _ctx: WorkerContext,
) -> Promise(json.Json) {
  case arguments {
    ModuleArguments(package_name: package_name, module_name: module_name) -> {
      use result <- promise.map(hex_client.fetch_package_interface(package_name))
      case result {
        Ok(interface) -> {
          case interface_parser.get_module_info(interface, module_name) {
            Ok(module_info) ->
              format_module_info(id, package_name, module_name, module_info)
            Error(err) -> {
              logger.warn("Module not found: " <> err)
              create_error_response(id, -32_603, "Module not found: " <> err)
            }
          }
        }
        Error(err) -> {
          logger.error(
            "Failed to fetch package interface: "
              <> hex_client.describe_error(err),
          )
          create_error_response(
            id,
            -32_603,
            "Failed to fetch package interface: "
              <> hex_client.describe_error(err),
          )
        }
      }
    }
    _ ->
      promise.resolve(create_error_response(
        id,
        -32_602,
        "Invalid arguments for get_module_info",
      ))
  }
}

fn handle_search_functions(
  id: String,
  arguments: ToolArguments,
  _ctx: WorkerContext,
) -> Promise(json.Json) {
  case arguments {
    PackageSearchArguments(package_name: package_name, query: query) -> {
      use result <- promise.map(hex_client.fetch_package_interface(package_name))
      case result {
        Ok(interface) -> {
          let functions = interface_parser.search_functions(interface, query)
          format_function_search_results(id, package_name, query, functions)
        }
        Error(err) -> {
          logger.error(
            "Failed to fetch package interface: "
              <> hex_client.describe_error(err),
          )
          create_error_response(
            id,
            -32_603,
            "Failed to fetch package interface: "
              <> hex_client.describe_error(err),
          )
        }
      }
    }
    _ ->
      promise.resolve(create_error_response(
        id,
        -32_602,
        "Invalid arguments for search_functions",
      ))
  }
}

fn format_function_search_results(
  id: String,
  package_name: String,
  query: String,
  functions: List(interface_parser.FunctionInfo),
) -> json.Json {
  let functions_json =
    functions
    |> list.map(fn(func) {
      let impl = func.implementations
      let base_fields = [
        #("name", json.string(func.name)),
        #("signature", json.string(func.signature)),
        #("documentation", json.string(func.documentation)),
        #(
          "implementations",
          json.object([
            #("can_run_on_erlang", json.bool(impl.can_run_on_erlang)),
            #("can_run_on_javascript", json.bool(impl.can_run_on_javascript)),
          ]),
        ),
      ]
      let fields = case func.deprecation {
        Some(msg) -> list.append(base_fields, [#("deprecation", json.string(msg))])
        None -> base_fields
      }
      json.object(fields)
    })

  let functions_text =
    functions
    |> list.map(fn(func) {
      let deprecation_notice = case func.deprecation {
        Some(msg) -> " [DEPRECATED: " <> msg <> "]"
        None -> ""
      }
      "- " <> func.signature <> deprecation_notice
    })
    |> string.join("\n")

  let count = list.length(functions)
  create_tool_result(
    id,
    "Found "
      <> int.to_string(count)
      <> " functions matching '"
      <> query
      <> "' in "
      <> package_name
      <> ":\n\n"
      <> functions_text,
    Some(json.object([#("functions", json.preprocessed_array(functions_json))])),
  )
}

fn handle_search_types(
  id: String,
  arguments: ToolArguments,
  _ctx: WorkerContext,
) -> Promise(json.Json) {
  case arguments {
    PackageSearchArguments(package_name: package_name, query: query) -> {
      use result <- promise.map(hex_client.fetch_package_interface(package_name))
      case result {
        Ok(interface) -> {
          let types = interface_parser.search_types(interface, query)
          format_type_search_results(id, package_name, query, types)
        }
        Error(err) -> {
          logger.error(
            "Failed to fetch package interface: "
              <> hex_client.describe_error(err),
          )
          create_error_response(
            id,
            -32_603,
            "Failed to fetch package interface: "
              <> hex_client.describe_error(err),
          )
        }
      }
    }
    _ ->
      promise.resolve(create_error_response(
        id,
        -32_602,
        "Invalid arguments for search_types",
      ))
  }
}

fn format_type_search_results(
  id: String,
  package_name: String,
  query: String,
  types: List(interface_parser.TypeInfo),
) -> json.Json {
  let types_json =
    types
    |> list.map(fn(type_info) {
      let base_fields = [
        #("name", json.string(type_info.name)),
        #("signature", json.string(type_info.signature)),
        #("type_kind", json.string(type_info.type_kind)),
        #("documentation", json.string(type_info.documentation)),
      ]
      let fields = case type_info.deprecation {
        Some(msg) -> list.append(base_fields, [#("deprecation", json.string(msg))])
        None -> base_fields
      }
      json.object(fields)
    })

  let types_text =
    types
    |> list.map(fn(t) {
      let deprecation_notice = case t.deprecation {
        Some(msg) -> " [DEPRECATED: " <> msg <> "]"
        None -> ""
      }
      "- " <> t.signature <> deprecation_notice
    })
    |> string.join("\n")

  let count = list.length(types)
  create_tool_result(
    id,
    "Found "
      <> int.to_string(count)
      <> " types matching '"
      <> query
      <> "' in "
      <> package_name
      <> ":\n\n"
      <> types_text,
    Some(json.object([#("types", json.preprocessed_array(types_json))])),
  )
}

fn format_module_info(
  id: String,
  package_name: String,
  module_name: String,
  module_info: interface_parser.ModuleInfo,
) -> json.Json {
  let functions =
    module_info.functions
    |> list.map(fn(func) {
      let impl = func.implementations
      let base_fields = [
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
        #(
          "implementations",
          json.object([
            #("gleam", json.bool(impl.gleam)),
            #("uses_erlang_externals", json.bool(impl.uses_erlang_externals)),
            #("uses_javascript_externals", json.bool(impl.uses_javascript_externals)),
            #("can_run_on_erlang", json.bool(impl.can_run_on_erlang)),
            #("can_run_on_javascript", json.bool(impl.can_run_on_javascript)),
          ]),
        ),
      ]
      let fields = case func.deprecation {
        Some(msg) -> list.append(base_fields, [#("deprecation", json.string(msg))])
        None -> base_fields
      }
      json.object(fields)
    })

  let types =
    module_info.types
    |> list.map(fn(type_info) {
      let base_fields = [
        #("name", json.string(type_info.name)),
        #("signature", json.string(type_info.signature)),
        #("type_kind", json.string(type_info.type_kind)),
        #("documentation", json.string(type_info.documentation)),
      ]
      let fields = case type_info.deprecation {
        Some(msg) -> list.append(base_fields, [#("deprecation", json.string(msg))])
        None -> base_fields
      }
      json.object(fields)
    })

  let functions_text =
    module_info.functions
    |> list.map(fn(func) {
      let deprecation_notice = case func.deprecation {
        Some(msg) -> " [DEPRECATED: " <> msg <> "]"
        None -> ""
      }
      let impl = func.implementations
      let platform_notice = case impl.can_run_on_erlang, impl.can_run_on_javascript {
        True, True -> ""
        True, False -> " [Erlang only]"
        False, True -> " [JavaScript only]"
        False, False -> " [No runtime support]"
      }
      case func.documentation {
        "" -> "### " <> func.signature <> deprecation_notice <> platform_notice
        doc -> "### " <> func.signature <> deprecation_notice <> platform_notice <> "\n" <> doc
      }
    })
    |> string.join("\n\n")

  let types_text =
    module_info.types
    |> list.map(fn(t) {
      let deprecation_notice = case t.deprecation {
        Some(msg) -> " [DEPRECATED: " <> msg <> "]"
        None -> ""
      }
      case t.documentation {
        "" -> "### " <> t.signature <> deprecation_notice
        doc -> "### " <> t.signature <> deprecation_notice <> "\n" <> doc
      }
    })
    |> string.join("\n\n")

  let constants =
    module_info.constants
    |> list.map(fn(c) {
      json.object([
        #("name", json.string(c.name)),
        #("type", json.string(c.type_name)),
        #("documentation", json.string(c.documentation)),
      ])
    })

  let constants_text = case module_info.constants {
    [] -> ""
    consts ->
      "\n\n## Constants ("
      <> int.to_string(list.length(consts))
      <> "):\n"
      <> {
        consts
        |> list.map(fn(c) {
          case c.documentation {
            "" -> "### " <> c.name <> ": " <> c.type_name
            doc -> "### " <> c.name <> ": " <> c.type_name <> "\n" <> doc
          }
        })
        |> string.join("\n\n")
      }
  }

  let type_aliases =
    module_info.type_aliases
    |> list.map(fn(ta) {
      let base_fields = [
        #("name", json.string(ta.name)),
        #("alias_for", json.string(ta.type_name)),
        #("documentation", json.string(ta.documentation)),
      ]
      let fields = case ta.deprecation {
        Some(msg) -> list.append(base_fields, [#("deprecation", json.string(msg))])
        None -> base_fields
      }
      json.object(fields)
    })

  let type_aliases_text = case module_info.type_aliases {
    [] -> ""
    aliases ->
      "\n\n## Type Aliases ("
      <> int.to_string(list.length(aliases))
      <> "):\n"
      <> {
        aliases
        |> list.map(fn(ta) {
          let deprecation_notice = case ta.deprecation {
            Some(msg) -> " [DEPRECATED: " <> msg <> "]"
            None -> ""
          }
          case ta.documentation {
            "" -> "### type " <> ta.name <> " = " <> ta.type_name <> deprecation_notice
            doc ->
              "### type " <> ta.name <> " = " <> ta.type_name <> deprecation_notice <> "\n" <> doc
          }
        })
        |> string.join("\n\n")
      }
  }

  let text_content =
    "Module: "
    <> module_name
    <> " (from "
    <> package_name
    <> ")\n\n"
    <> module_info.documentation
    <> "\n\n## Functions ("
    <> int.to_string(list.length(module_info.functions))
    <> "):\n"
    <> functions_text
    <> "\n\n## Types ("
    <> int.to_string(list.length(module_info.types))
    <> "):\n"
    <> types_text
    <> constants_text
    <> type_aliases_text

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
              #("text", json.string(text_content)),
            ]),
          ]),
        ),
        #("functions", json.preprocessed_array(functions)),
        #("types", json.preprocessed_array(types)),
        #("constants", json.preprocessed_array(constants)),
        #("type_aliases", json.preprocessed_array(type_aliases)),
      ]),
    ),
  ])
}

// ============================================================================
// Response Helpers
// ============================================================================

fn create_tool_result(
  id: String,
  text: String,
  extra_data: Option(json.Json),
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
// Cache Encoders/Decoders
// ============================================================================

fn encode_package(pkg: hex_client.Package) -> String {
  json.to_string(
    json.object([
      #("name", json.string(pkg.name)),
      #("version", json.string(pkg.version)),
      #("description", json.string(pkg.description)),
      #("downloads", json.int(pkg.downloads)),
      #("docs_url", json.string(pkg.docs_url)),
      #("licenses", json.array(pkg.licenses, json.string)),
      #("repository_url", json.string(pkg.repository_url)),
      #("hex_url", json.string(pkg.hex_url)),
    ]),
  )
}

fn package_decoder() -> decode.Decoder(hex_client.Package) {
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.string)
  use description <- decode.field("description", decode.string)
  use downloads <- decode.field("downloads", decode.int)
  use docs_url <- decode.field("docs_url", decode.string)
  use licenses <- decode.optional_field("licenses", [], decode.list(decode.string))
  use repository_url <- decode.optional_field("repository_url", "", decode.string)
  use hex_url <- decode.optional_field("hex_url", "", decode.string)
  decode.success(hex_client.Package(
    name: name,
    version: version,
    description: description,
    downloads: downloads,
    docs_url: docs_url,
    licenses: licenses,
    repository_url: repository_url,
    hex_url: hex_url,
  ))
}

fn encode_search_result(result: hex_client.PackageSearchResult) -> String {
  let packages =
    result.packages
    |> list.map(fn(pkg) {
      json.object([
        #("name", json.string(pkg.name)),
        #("version", json.string(pkg.version)),
        #("description", json.string(pkg.description)),
        #("downloads", json.int(pkg.downloads)),
        #("docs_url", json.string(pkg.docs_url)),
        #("licenses", json.array(pkg.licenses, json.string)),
        #("repository_url", json.string(pkg.repository_url)),
        #("hex_url", json.string(pkg.hex_url)),
      ])
    })

  json.to_string(
    json.object([
      #("packages", json.preprocessed_array(packages)),
      #("total", json.int(result.total)),
    ]),
  )
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
    "get_package_info" | "get_modules" | "get_package_releases" -> {
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
    "search_functions" | "search_types" -> {
      use package_name <- decode.field("package_name", decode.string)
      use query <- decode.field("query", decode.string)
      decode.success(PackageSearchArguments(
        package_name: package_name,
        query: query,
      ))
    }
    _ -> decode.success(SearchArguments(query: ""))
  }
}
