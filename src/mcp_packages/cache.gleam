import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option, None, Some}
import mcp_packages/logger
import plinth/cloudflare/d1.{type Database}

/// Cache entry with expiration
pub type CacheEntry {
  CacheEntry(key: String, value: String, expires_at: Int)
}

/// Cache TTL in seconds (1 hour default)
pub const default_ttl = 3600

/// Package interface TTL (24 hours - they don't change often)
pub const interface_ttl = 86_400

/// Initialize the cache tables (run once)
pub fn init_schema(db: Database) -> Promise(Result(Nil, String)) {
  logger.debug("Initializing cache schema...")

  let create_table_sql =
    "CREATE TABLE IF NOT EXISTS cache (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      expires_at INTEGER NOT NULL
    )"

  let create_index_sql =
    "CREATE INDEX IF NOT EXISTS idx_cache_expires ON cache(expires_at)"

  use table_result <- promise.await(d1.exec(db, create_table_sql))
  case table_result {
    Ok(_) -> {
      use index_result <- promise.map(d1.exec(db, create_index_sql))
      case index_result {
        Ok(_) -> {
          logger.info("Cache schema initialized successfully")
          Ok(Nil)
        }
        Error(err) -> {
          logger.error("Failed to create cache index: " <> err)
          Error(err)
        }
      }
    }
    Error(err) -> {
      logger.error("Failed to create cache table: " <> err)
      promise.resolve(Error(err))
    }
  }
}

/// Get a cached value if it exists and hasn't expired
pub fn get(
  db: Database,
  key: String,
  current_time: Int,
) -> Promise(Option(String)) {
  let stmt =
    d1.prepare(db, "SELECT value FROM cache WHERE key = ? AND expires_at > ?")
    |> d1.bind([key, int.to_string(current_time)])

  use result <- promise.map(d1.first(stmt))
  case result {
    Ok(row) -> {
      case decode.run(row, decode.at(["value"], decode.string)) {
        Ok(value) -> Some(value)
        Error(_) -> None
      }
    }
    Error(err) -> {
      logger.error("Cache get failed for key '" <> key <> "': " <> err)
      None
    }
  }
}

/// Set a cached value with TTL
pub fn set(
  db: Database,
  key: String,
  value: String,
  current_time: Int,
  ttl: Int,
) -> Promise(Result(Nil, String)) {
  let expires_at = current_time + ttl
  let stmt =
    d1.prepare(
      db,
      "INSERT OR REPLACE INTO cache (key, value, expires_at) VALUES (?, ?, ?)",
    )
    |> d1.bind([key, value, int.to_string(expires_at)])

  use result <- promise.map(d1.run(stmt))
  case result {
    Ok(_) -> {
      logger.debug("Cache set successful for key: " <> key)
      Ok(Nil)
    }
    Error(err) -> {
      logger.error("Cache set failed for key '" <> key <> "': " <> err)
      Error(err)
    }
  }
}

/// Delete expired entries (cleanup)
pub fn cleanup_expired(
  db: Database,
  current_time: Int,
) -> Promise(Result(Int, String)) {
  let stmt =
    d1.prepare(db, "DELETE FROM cache WHERE expires_at <= ?")
    |> d1.bind([int.to_string(current_time)])

  use result <- promise.map(d1.run(stmt))
  case result {
    Ok(run_result) -> {
      case
        decode.run(run_result.meta, decode.at(["changes"], decode.int))
      {
        Ok(changes) -> Ok(changes)
        Error(_) -> Ok(0)
      }
    }
    Error(err) -> Error(err)
  }
}

/// Cache key generators
pub fn package_info_key(package_name: String) -> String {
  "pkg:" <> package_name
}

pub fn package_search_key(query: String) -> String {
  "search:" <> query
}

pub fn package_interface_key(package_name: String) -> String {
  "interface:" <> package_name
}

pub fn package_list_key() -> String {
  "packages:popular"
}
