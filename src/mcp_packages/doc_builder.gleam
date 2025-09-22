import envoy
import gleam/float
import gleam/list
import gleam/string
import gleam/time/timestamp
import shellout
import simplifile

pub type DocBuildResult {
  DocBuildResult(
    package_name: String,
    success: Bool,
    docs_path: String,
    interface_json_path: String,
    error_message: String,
  )
}

pub fn build_package_docs(
  package_path: String,
  package_name: String,
) -> Result(DocBuildResult, String) {
  case fix_naming_clashes(package_path) {
    Ok(_) -> Nil
    Error(_) -> Nil
  }

  case run_gleam_docs_build(package_path) {
    Ok(_) -> {
      let docs_path = package_path <> "/build/dev/docs/" <> package_name
      let interface_json_path = docs_path <> "/package-interface.json"

      case simplifile.is_file(interface_json_path) {
        Ok(_) -> {
          Ok(DocBuildResult(
            package_name: package_name,
            success: True,
            docs_path: docs_path,
            interface_json_path: interface_json_path,
            error_message: "",
          ))
        }
        Error(_) -> {
          Error(
            "Documentation built but package_interface.json not found at "
            <> interface_json_path,
          )
        }
      }
    }
    Error(msg) -> {
      Ok(DocBuildResult(
        package_name: package_name,
        success: False,
        docs_path: "",
        interface_json_path: "",
        error_message: msg,
      ))
    }
  }
}

fn run_gleam_docs_build(package_path: String) -> Result(String, String) {
  // Check if directory exists and is accessible
  case
    shellout.command(
      run: "gleam",
      with: ["docs", "build"],
      in: package_path,
      opt: [shellout.LetBeStderr],
    )
  {
    Ok(output) -> {
      Ok(output)
    }
    Error(#(exit_code, stderr)) -> {
      Error(
        "Gleam docs build failed (exit "
        <> string.inspect(exit_code)
        <> "): "
        <> stderr,
      )
    }
  }
}

pub fn ensure_docs_directory() -> Result(Nil, String) {
  let docs_dir = get_docs_cache_dir()
  case simplifile.create_directory_all(docs_dir) {
    Ok(_) -> Ok(Nil)
    Error(err) ->
      Error("Failed to create docs directory: " <> string.inspect(err))
  }
}

fn get_docs_cache_dir() -> String {
  case envoy.get("GLEAM_DOCS_CACHE") {
    Ok(cache_dir) -> cache_dir
    Error(_) -> "./docs_cache"
  }
}

pub fn clean_old_docs(max_age_hours: Int) -> Result(Int, String) {
  let docs_dir = get_docs_cache_dir()
  case simplifile.read_directory(docs_dir) {
    Ok(entries) -> {
      let cleaned =
        entries
        |> list.filter(fn(entry) {
          case get_directory_age_hours(docs_dir <> "/" <> entry) {
            Ok(age) -> age > max_age_hours
            Error(_) -> False
          }
        })
        |> list.map(fn(entry) {
          case simplifile.delete(docs_dir <> "/" <> entry) {
            Ok(_) -> 1
            Error(_) -> 0
          }
        })
        |> list.fold(0, fn(acc, count) { acc + count })

      Ok(cleaned)
    }
    Error(err) ->
      Error("Failed to read docs directory: " <> string.inspect(err))
  }
}

fn get_directory_age_hours(path: String) -> Result(Int, String) {
  case simplifile.file_info(path) {
    Ok(info) -> {
      let now =
        timestamp.system_time() |> timestamp.to_unix_seconds() |> float.round()
      let age_seconds = now - info.mtime_seconds
      Ok(age_seconds / 3600)
    }
    Error(err) -> Error("Failed to get file info: " <> string.inspect(err))
  }
}

fn fix_naming_clashes(package_path: String) -> Result(Nil, String) {
  fix_naming_clashes_recursive(package_path <> "/src")
}

fn fix_naming_clashes_recursive(dir_path: String) -> Result(Nil, String) {
  fix_clashes_in_directory(dir_path)
}

fn fix_clashes_in_directory(base_dir: String) -> Result(Nil, String) {
  case collect_all_gleam_modules(base_dir, base_dir) {
    Ok(gleam_modules) -> {
      case simplifile.read_directory(base_dir) {
        Ok(entries) -> {
          let erl_files =
            entries
            |> list.filter(fn(file) { string.ends_with(file, ".erl") })
            |> list.map(fn(file) {
              let name = string.drop_end(file, 4)
              string.replace(name, "@", "/")
            })

          let clashing_modules =
            gleam_modules
            |> list.filter(fn(module_path) {
              list.contains(erl_files, module_path)
            })

          clashing_modules
          |> list.each(fn(clash_path) {
            let erl_name = string.replace(clash_path, "/", "@")
            let old_erl_path = base_dir <> "/" <> erl_name <> ".erl"
            let new_erl_path = base_dir <> "/" <> erl_name <> "_ffi.erl"
            case simplifile.rename(old_erl_path, new_erl_path) {
              Ok(_) -> {
                case
                  update_erlang_module_name(new_erl_path, erl_name <> "_ffi")
                {
                  Ok(_) -> Nil
                  Error(_) -> Nil
                }
              }
              Error(_) -> Nil
            }
          })

          Ok(Nil)
        }
        Error(err) ->
          Error("Failed to read base directory: " <> string.inspect(err))
      }
    }
    Error(err) -> Error(err)
  }
}

fn collect_all_gleam_modules(
  base_dir: String,
  current_dir: String,
) -> Result(List(String), String) {
  case simplifile.read_directory(current_dir) {
    Ok(entries) -> {
      let files =
        entries
        |> list.filter(fn(entry) {
          let full_path = current_dir <> "/" <> entry
          case simplifile.is_file(full_path) {
            Ok(_) -> string.ends_with(entry, ".gleam")
            Error(_) -> False
          }
        })
        |> list.map(fn(file) {
          let module_name = string.drop_end(file, 6)
          case current_dir == base_dir {
            True -> module_name
            False -> {
              let relative_path =
                string.drop_start(current_dir, string.length(base_dir) + 1)
              relative_path <> "/" <> module_name
            }
          }
        })

      let subdirs =
        entries
        |> list.filter(fn(entry) {
          let full_path = current_dir <> "/" <> entry
          case simplifile.is_directory(full_path) {
            Ok(_) -> True
            Error(_) -> False
          }
        })

      let subdir_modules =
        subdirs
        |> list.map(fn(subdir) {
          collect_all_gleam_modules(base_dir, current_dir <> "/" <> subdir)
        })
        |> list.fold([], fn(acc, result) {
          case result {
            Ok(modules) -> list.append(acc, modules)
            Error(_) -> acc
          }
        })

      Ok(list.append(files, subdir_modules))
    }
    Error(err) -> Error("Failed to read directory: " <> string.inspect(err))
  }
}

fn update_erlang_module_name(
  file_path: String,
  new_module_name: String,
) -> Result(Nil, String) {
  case simplifile.read(file_path) {
    Ok(content) -> {
      let lines = string.split(content, "\n")
      let updated_lines = case lines {
        [first_line, ..rest] -> {
          case string.starts_with(first_line, "-module(") {
            True -> {
              let new_first_line = "-module(" <> new_module_name <> ")."
              [new_first_line, ..rest]
            }
            False -> lines
          }
        }
        [] -> lines
      }
      let updated_content = string.join(updated_lines, "\n")
      case simplifile.write(file_path, updated_content) {
        Ok(_) -> Ok(Nil)
        Error(err) ->
          Error("Failed to write updated module: " <> string.inspect(err))
      }
    }
    Error(err) -> Error("Failed to read Erlang file: " <> string.inspect(err))
  }
}
