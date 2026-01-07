import gleam/dict
import gleam/dynamic/decode
import gleam/fetch
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option
import gleam/result
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
    licenses: List(String),
    repository_url: String,
    hex_url: String,
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

/// A release version of a package
pub type Release {
  Release(
    version: String,
    inserted_at: String,
    has_docs: Bool,
    retirement: option.Option(Retirement),
  )
}

/// Retirement info for a release
pub type Retirement {
  Retirement(reason: String, message: String)
}

/// Full release info for a package
pub type PackageReleases {
  PackageReleases(name: String, releases: List(Release))
}

const hex_api_base = "https://hex.pm/api"

const hexdocs_base = "https://hexdocs.pm"

/// Search for packages on hex.pm (async)
pub fn search_packages(
  query: String,
) -> Promise(Result(PackageSearchResult, HexError)) {
  let url =
    hex_api_base <> "/packages?search=" <> query <> "&sort=recent_downloads"

  use result <- promise.map(fetch_json(url))
  case result {
    Ok(body) -> parse_package_list(body)
    Error(err) -> Error(err)
  }
}

/// Get info about a specific package (async)
pub fn get_package_info(
  package_name: String,
) -> Promise(Result(Package, HexError)) {
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

/// Get all releases for a package with retirement info (async)
pub fn get_package_releases(
  package_name: String,
) -> Promise(Result(PackageReleases, HexError)) {
  let url = hex_api_base <> "/packages/" <> package_name

  use result <- promise.map(fetch_json(url))
  case result {
    Ok(body) -> parse_package_releases(package_name, body)
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
        Error(err) ->
          promise.resolve(
            Error(HttpError("Fetch failed: " <> string.inspect(err))),
          )
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
      Ok(PackageSearchResult(packages: packages, total: list.length(packages)))
    }
    Error(err) ->
      Error(ParseError("Failed to parse package list: " <> string.inspect(err)))
  }
}

fn parse_single_package(body: String) -> Result(Package, HexError) {
  case json.parse(body, package_decoder()) {
    Ok(pkg) -> Ok(pkg)
    Error(err) ->
      Error(ParseError("Failed to parse package: " <> string.inspect(err)))
  }
}

fn parse_package_releases(
  package_name: String,
  body: String,
) -> Result(PackageReleases, HexError) {
  case json.parse(body, releases_decoder()) {
    Ok(#(releases, retirements)) -> {
      // Merge retirement info into releases
      let releases_with_retirement =
        releases
        |> list.map(fn(release) {
          let retirement =
            retirements
            |> list.find(fn(r) { r.0 == release.version })
            |> result.map(fn(r) { r.1 })
            |> option.from_result
          Release(..release, retirement: retirement)
        })
      Ok(PackageReleases(name: package_name, releases: releases_with_retirement))
    }
    Error(err) ->
      Error(ParseError("Failed to parse releases: " <> string.inspect(err)))
  }
}

fn releases_decoder() -> decode.Decoder(
  #(List(Release), List(#(String, Retirement))),
) {
  use releases <- decode.optional_field(
    "releases",
    [],
    decode.list(release_decoder()),
  )
  use retirements <- decode.optional_field(
    "retirements",
    [],
    decode.dict(decode.string, retirement_decoder())
    |> decode.map(fn(d) { dict.to_list(d) }),
  )
  decode.success(#(releases, retirements))
}

fn release_decoder() -> decode.Decoder(Release) {
  use version <- decode.field("version", decode.string)
  use inserted_at <- decode.optional_field("inserted_at", "", decode.string)
  use has_docs <- decode.optional_field("has_docs", False, decode.bool)
  decode.success(Release(
    version: version,
    inserted_at: inserted_at,
    has_docs: has_docs,
    retirement: option.None,
  ))
}

fn retirement_decoder() -> decode.Decoder(Retirement) {
  use reason <- decode.optional_field("reason", "", decode.string)
  use message <- decode.optional_field("message", "", decode.string)
  decode.success(Retirement(reason: reason, message: message))
}

fn package_decoder() -> decode.Decoder(Package) {
  use name <- decode.field("name", decode.string)
  use latest_version <- decode.optional_field(
    "latest_stable_version",
    "",
    decode.optional(decode.string) |> decode.map(fn(o) { option.unwrap(o, "") }),
  )
  use meta <- decode.optional_field(
    "meta",
    PackageMeta(description: "", licenses: [], repository_url: ""),
    meta_decoder(),
  )
  use downloads <- decode.optional_field("downloads", 0, downloads_decoder())
  use docs_url <- decode.optional_field(
    "docs_html_url",
    "",
    decode.optional(decode.string) |> decode.map(fn(o) { option.unwrap(o, "") }),
  )
  use hex_url <- decode.optional_field(
    "html_url",
    "",
    decode.optional(decode.string) |> decode.map(fn(o) { option.unwrap(o, "") }),
  )

  let version = case latest_version {
    "" -> "unknown"
    v -> v
  }

  decode.success(
    Package(
      name: name,
      version: version,
      description: meta.description,
      downloads: downloads,
      docs_url: case docs_url {
        "" -> hexdocs_base <> "/" <> name
        url -> url
      },
      licenses: meta.licenses,
      repository_url: meta.repository_url,
      hex_url: case hex_url {
        "" -> "https://hex.pm/packages/" <> name
        url -> url
      },
    ),
  )
}

/// Metadata extracted from the "meta" field
pub type PackageMeta {
  PackageMeta(
    description: String,
    licenses: List(String),
    repository_url: String,
  )
}

fn meta_decoder() -> decode.Decoder(PackageMeta) {
  use description <- decode.optional_field("description", "", decode.string)
  use licenses <- decode.optional_field(
    "licenses",
    [],
    decode.list(decode.string),
  )
  use links <- decode.optional_field(
    "links",
    [],
    decode.dict(decode.string, decode.string)
    |> decode.map(fn(d) { d |> dict.to_list }),
  )

  // Try to find repository URL from links
  let repository_url =
    links
    |> list.find(fn(pair) {
      let #(key, _) = pair
      string.lowercase(key) == "repository" || string.lowercase(key) == "github"
    })
    |> result.map(fn(pair) { pair.1 })
    |> result.unwrap("")

  decode.success(PackageMeta(
    description: description,
    licenses: licenses,
    repository_url: repository_url,
  ))
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

pub fn package_search_result_decoder() -> decode.Decoder(PackageSearchResult) {
  use packages <- decode.field("packages", decode.list(package_decoder()))
  use total <- decode.field("total", decode.int)
  decode.success(PackageSearchResult(packages: packages, total: total))
}
