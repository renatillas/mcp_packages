import gleam/int
import plinth/javascript/console
import plinth/javascript/date

/// Log levels for filtering
pub type LogLevel {
  Debug
  Info
  Warn
  Error
}

/// Log a debug message
pub fn debug(message: String) -> Nil {
  console.debug(format_message("DEBUG", message))
}

/// Log an info message
pub fn info(message: String) -> Nil {
  console.info(format_message("INFO", message))
}

/// Log a warning message
pub fn warn(message: String) -> Nil {
  console.warn(format_message("WARN", message))
}

/// Log an error message
pub fn error(message: String) -> Nil {
  console.error(format_message("ERROR", message))
}

/// Log a request
pub fn request(method: String, path: String) -> Nil {
  info("[REQUEST] " <> method <> " " <> path)
}

/// Log a response
pub fn response(status: Int, duration_ms: Int) -> Nil {
  info(
    "[RESPONSE] "
    <> int.to_string(status)
    <> " ("
    <> int.to_string(duration_ms)
    <> "ms)",
  )
}

/// Log a tool call
pub fn tool_call(tool_name: String) -> Nil {
  info("[TOOL] " <> tool_name)
}

/// Log a cache hit
pub fn cache_hit(key: String) -> Nil {
  debug("[CACHE HIT] " <> key)
}

/// Log a cache miss
pub fn cache_miss(key: String) -> Nil {
  debug("[CACHE MISS] " <> key)
}

/// Log a cache write
pub fn cache_write(key: String) -> Nil {
  debug("[CACHE WRITE] " <> key)
}

/// Log an MCP method
pub fn mcp_method(method: String, id: String) -> Nil {
  info("[MCP] " <> method <> " (id: " <> id <> ")")
}

/// Format a log message with timestamp
fn format_message(level: String, message: String) -> String {
  let timestamp = date.now() |> date.to_iso_string
  "[" <> timestamp <> "] [" <> level <> "] " <> message
}
