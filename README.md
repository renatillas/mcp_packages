# Gleam Package MCP Server

An MCP server that provides AI agents with access to Gleam package documentation, search, and module details. Built with Gleam, runs on Cloudflare Workers.

## Features

- **Package search & info** - Search hex.pm, get versions, downloads, licenses, repository links
- **Module documentation** - Function signatures, types, constants, type aliases with full docs
- **Platform compatibility** - See which functions run on Erlang, JavaScript, or both
- **Deprecation tracking** - Identify deprecated functions and types
- **Release history** - View all versions with retirement info
- **D1 caching** - Fast repeat queries with background cache writes

## Quick Start

```sh
gleam deps download
npm install
npm run dev   # Local dev server on http://localhost:8788
```

## MCP Integration

Add to your MCP configuration:

```json
{
  "mcpServers": {
    "gleam-packages": {
      "transport": "http",
      "url": "https://your-worker.workers.dev"
    }
  }
}
```

## Tools

### `search_packages`
Search for packages on hex.pm by name or description.
- `query` (required) - Search query

### `get_package_info`
Get package details including version, downloads, licenses, repository URL, and hex.pm link.
- `package_name` (required)

### `get_package_releases`
Get version history with release dates and retirement status.
- `package_name` (required)

### `get_modules`
List all modules in a package with function/type/constant counts and Gleam version constraint.
- `package_name` (required)

### `get_module_info`
Get full module documentation: functions (with platform support), types, constants, and type aliases.
- `package_name` (required)
- `module_name` (required) - e.g., `gleam/list`

### `search_functions`
Search for functions within a package by name or documentation.
- `package_name` (required)
- `query` (required)

### `search_types`
Search for types within a package by name or documentation.
- `package_name` (required)
- `query` (required)

## Resources

### `gleam://packages`
Lists popular Gleam packages sorted by recent downloads.

## Deploy to Cloudflare

```sh
# Create D1 database (first time)
npx wrangler d1 create mcp-packages-cache

# Initialize cache table
npx wrangler d1 execute mcp-packages-cache --remote \
  --command="CREATE TABLE IF NOT EXISTS cache (key TEXT PRIMARY KEY, value TEXT NOT NULL, expires_at INTEGER NOT NULL)"
npx wrangler d1 execute mcp-packages-cache --remote \
  --command="CREATE INDEX IF NOT EXISTS idx_cache_expires ON cache(expires_at)"

# Deploy
npm run deploy
```

## Caching

| Data | TTL |
|------|-----|
| Package info & search | 1 hour |
| Package interfaces | 24 hours |

Cache writes happen asynchronously via `waitUntil`.
