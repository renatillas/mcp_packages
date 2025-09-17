import envoy
import gleam/dict
import gleam/io
import gleam/list
import gleam/string
import pack
import simplifile

pub type Package {
  Package(name: String, version: String, description: String)
}

pub type PackageSearchResult {
  PackageSearchResult(packages: List(Package), total: Int)
}

pub fn init_pack() -> Result(pack.Pack, String) {
  // Ensure persistent storage directories exist using envoy
  case envoy.get("XDG_DATA_HOME") {
    Ok(data_home) -> {
      let packages_dir = data_home <> "/pack/packages"
      case ensure_directory_exists(packages_dir) {
        Ok(_) -> {
          io.println("Using persistent storage at: " <> data_home)
          io.println("Pack packages directory: " <> packages_dir)
        }
        Error(err) -> {
          io.println(
            "Warning: Could not create packages directory "
            <> packages_dir
            <> ": "
            <> err,
          )
        }
      }
    }
    Error(_) -> {
      io.println("Using default ephemeral storage (XDG_DATA_HOME not set)")
    }
  }

  let options = pack.default_options
  case pack.load(options) {
    Ok(pack_instance) -> {
      let actual_packages_dir = pack.packages_directory(pack_instance)
      io.println("Pack library is using directory: " <> actual_packages_dir)
      Ok(pack_instance)
    }
    Error(err) ->
      Error("Failed to initialize pack: " <> pack.describe_error(err))
  }
}

fn ensure_directory_exists(path: String) -> Result(Nil, String) {
  case simplifile.create_directory_all(path) {
    Ok(_) -> Ok(Nil)
    Error(err) -> Error("Failed to create directory: " <> string.inspect(err))
  }
}

pub fn search_packages(
  pack_instance: pack.Pack,
  query: String,
) -> Result(PackageSearchResult, String) {
  let all_packages = pack.packages(pack_instance)
  let filtered_packages =
    all_packages
    |> list.filter(fn(pkg) {
      string.contains(string.lowercase(pkg.name), string.lowercase(query))
      || string.contains(
        string.lowercase(pkg.description),
        string.lowercase(query),
      )
    })
    |> list.map(fn(pkg) {
      Package(
        name: pkg.name,
        version: pkg.latest_version,
        description: pkg.description,
      )
    })

  Ok(PackageSearchResult(
    packages: filtered_packages,
    total: list.length(filtered_packages),
  ))
}

pub fn download_packages(
  pack_instance: pack.Pack,
) -> Result(dict.Dict(String, List(pack.File)), String) {
  case pack.download(pack_instance) {
    Ok(packages_dict) -> Ok(packages_dict)
    Error(err) ->
      Error("Failed to download packages: " <> pack.describe_error(err))
  }
}

pub fn download_packages_to_disc(
  pack_instance: pack.Pack,
) -> Result(Nil, String) {
  case pack.download_to_disc(pack_instance) {
    Ok(_) -> Ok(Nil)
    Error(err) ->
      Error("Failed to download packages to disc: " <> pack.describe_error(err))
  }
}

pub fn get_packages_directory(pack_instance: pack.Pack) -> String {
  pack.packages_directory(pack_instance)
}

pub fn get_package_info(
  pack_instance: pack.Pack,
  name: String,
) -> Result(Package, String) {
  let all_packages = pack.packages(pack_instance)
  case list.find(all_packages, fn(pkg) { pkg.name == name }) {
    Ok(pkg) ->
      Ok(Package(
        name: pkg.name,
        version: pkg.latest_version,
        description: pkg.description,
      ))
    Error(_) -> Error("Package " <> name <> " not found")
  }
}

pub fn list_available_packages(
  pack_instance: pack.Pack,
) -> Result(List(Package), String) {
  let all_packages = pack.packages(pack_instance)
  let package_list =
    all_packages
    |> list.map(fn(pkg) {
      Package(
        name: pkg.name,
        version: pkg.latest_version,
        description: pkg.description,
      )
    })
  Ok(package_list)
}

pub fn get_package_files(
  pack_instance: pack.Pack,
  package_name: String,
) -> Result(List(pack.File), String) {
  case download_packages(pack_instance) {
    Ok(packages_dict) -> {
      case dict.get(packages_dict, package_name) {
        Ok(files) -> Ok(files)
        Error(_) ->
          Error(
            "Package " <> package_name <> " not found in downloaded packages",
          )
      }
    }
    Error(err) -> Error(err)
  }
}
