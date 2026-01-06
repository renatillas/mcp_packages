import gleam/dynamic/decode
import gleam/fetch
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import mcp_packages/interface_parser.{type PackageInterface}

/// A Gleam package from hex.pm
pub type Package {
  Package(
    name: String,
    version: String,
    description: String,
    downloads: Int,
    docs_url: String,
  )
}

pub type PackageSearchResult {
  PackageSearchResult(packages: List(Package), total: Int)
}

pub type HexError {
  HttpError(String)
  ParseError(String)
  NotFound(String)
}

const hex_api_base = "https://hex.pm/api"

const hexdocs_base = "https://hexdocs.pm"

/// Search for packages on hex.pm (async)
pub fn search_packages(query: String) -> Promise(Result(PackageSearchResult, HexError)) {
  let url = hex_api_base <> "/packages?search=" <> query <> "&sort=recent_downloads"

  use result <- promise.map(fetch_json(url))
  case result {
    Ok(body) -> parse_package_list(body)
    Error(err) -> Error(err)
  }
}

/// Get info about a specific package (async)
pub fn get_package_info(package_name: String) -> Promise(Result(Package, HexError)) {
  let url = hex_api_base <> "/packages/" <> package_name

  use result <- promise.map(fetch_json(url))
  case result {
    Ok(body) -> parse_single_package(body)
    Error(err) -> Error(err)
  }
}

/// Fetch the package interface JSON from hexdocs.pm (async)
pub fn fetch_package_interface(
  package_name: String,
) -> Promise(Result(PackageInterface, HexError)) {
  let url = hexdocs_base <> "/" <> package_name <> "/package-interface.json"

  use result <- promise.map(fetch_json(url))
  case result {
    Ok(body) -> {
      case interface_parser.parse_package_interface(body) {
        Ok(interface) -> Ok(interface)
        Error(err) -> Error(ParseError(err))
      }
    }
    Error(err) -> Error(err)
  }
}

/// List popular packages (async)
pub fn list_gleam_packages() -> Promise(Result(List(Package), HexError)) {
  let url = hex_api_base <> "/packages?sort=recent_downloads"

  use result <- promise.map(fetch_json(url))
  case result {
    Ok(body) -> {
      case parse_package_list(body) {
        Ok(result) -> Ok(result.packages)
        Error(err) -> Error(err)
      }
    }
    Error(err) -> Error(err)
  }
}

fn fetch_json(url: String) -> Promise(Result(String, HexError)) {
  case request.to(url) {
    Ok(req) -> {
      let req = request.set_header(req, "accept", "application/json")
      let req = request.set_header(req, "user-agent", "gleam-mcp-packages/2.0")

      // Send request
      use send_result <- promise.await(fetch.send(req))
      case send_result {
        Ok(resp) -> {
          // Read the body as text
          use body_result <- promise.map(fetch.read_text_body(resp))
          case body_result {
            Ok(response_with_body) -> handle_response(response_with_body)
            Error(_) -> Error(HttpError("Failed to read response body"))
          }
        }
        Error(err) -> promise.resolve(Error(HttpError("Fetch failed: " <> string.inspect(err))))
      }
    }
    Error(_) -> promise.resolve(Error(HttpError("Invalid URL: " <> url)))
  }
}

fn handle_response(resp: Response(String)) -> Result(String, HexError) {
  case resp.status {
    200 -> Ok(resp.body)
    404 -> Error(NotFound("Resource not found"))
    status -> Error(HttpError("HTTP error: status " <> int.to_string(status)))
  }
}

fn parse_package_list(body: String) -> Result(PackageSearchResult, HexError) {
  let decoder = decode.list(package_decoder())

  case json.parse(body, decoder) {
    Ok(packages) -> {
      Ok(PackageSearchResult(
        packages: packages,
        total: list.length(packages),
      ))
    }
    Error(err) -> Error(ParseError("Failed to parse package list: " <> string.inspect(err)))
  }
}

fn parse_single_package(body: String) -> Result(Package, HexError) {
  case json.parse(body, package_decoder()) {
    Ok(pkg) -> Ok(pkg)
    Error(err) -> Error(ParseError("Failed to parse package: " <> string.inspect(err)))
  }
}

fn package_decoder() -> decode.Decoder(Package) {
  use name <- decode.field("name", decode.string)
  use latest_version <- decode.optional_field(
    "latest_stable_version",
    "",
    decode.optional(decode.string) |> decode.map(fn(o) { option.unwrap(o, "") }),
  )
  use meta <- decode.optional_field("meta", #("", []), meta_decoder())
  use downloads <- decode.optional_field("downloads", 0, downloads_decoder())
  use docs_url <- decode.optional_field(
    "docs_html_url",
    "",
    decode.optional(decode.string) |> decode.map(fn(o) { option.unwrap(o, "") }),
  )

  let #(description, _licenses) = meta
  let version = case latest_version {
    "" -> "unknown"
    v -> v
  }

  decode.success(Package(
    name: name,
    version: version,
    description: description,
    downloads: downloads,
    docs_url: case docs_url {
      "" -> hexdocs_base <> "/" <> name
      url -> url
    },
  ))
}

fn meta_decoder() -> decode.Decoder(#(String, List(String))) {
  use description <- decode.optional_field("description", "", decode.string)
  use licenses <- decode.optional_field("licenses", [], decode.list(decode.string))
  decode.success(#(description, licenses))
}

fn downloads_decoder() -> decode.Decoder(Int) {
  decode.at(["all"], decode.int)
  |> decode.optional()
  |> decode.map(fn(d) { option.unwrap(d, 0) })
}

/// Format error for display
pub fn describe_error(error: HexError) -> String {
  case error {
    HttpError(msg) -> "HTTP error: " <> msg
    ParseError(msg) -> "Parse error: " <> msg
    NotFound(msg) -> "Not found: " <> msg
  }
}
