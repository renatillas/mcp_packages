# Gleam Package MCP Server

An MCP (Model Context Protocol) server that provides AI agents with access to Gleam package information, search, and documentation. Built with Gleam and runs on Cloudflare Workers.

## Features

- **Search Gleam packages** by name or description via hex.pm API
- **Get detailed package information** including versions, downloads, and descriptions
- **Browse package modules** with function and type counts
- **Get module documentation** including function signatures, types, and docs
- **D1 database caching** for fast repeat queries with automatic TTL expiration
- **Background caching** using Cloudflare's `waitUntil` for non-blocking cache writes

## Architecture

Built with:
- **Gleam** - Type-safe functional language
- **plinth_cloudflare** - Cloudflare Workers bindings (D1, worker context)
- **conversation** - Clean JS Request/Response conversions
- **Cloudflare Workers** - Edge deployment with D1 SQLite database

## Quick Start

### Local Development

```sh
gleam deps download
npm install
npm run dev   # Starts wrangler dev server
```

### Deploy to Cloudflare

```sh
# Create D1 database (first time only)
npx wrangler d1 create mcp-packages-cache

# Update wrangler.toml with the database_id from above

# Deploy
npm run deploy
```

## MCP Integration

### Claude Code

Add to your Claude Code MCP configuration:

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

### Other AI Agents (Cline, Continue, Cursor)

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

## Available Tools

### `search_packages`
Search for Gleam packages on hex.pm by name or description.

**Parameters:**
- `query` (string, required) - Search query for package name or description

**Example:** "Search for packages related to json"

### `get_package_info`
Get detailed information about a specific package from hex.pm.

**Parameters:**
- `package_name` (string, required) - Name of the package

**Example:** "Get info about the wisp package"

### `get_modules`
Get a list of all modules in a package with their documentation from hexdocs.pm.

**Parameters:**
- `package_name` (string, required) - Name of the package

**Example:** "List all modules in gleam_stdlib"

### `get_module_info`
Get detailed information about a specific module including functions and types.

**Parameters:**
- `package_name` (string, required) - Name of the package containing the module
- `module_name` (string, required) - Name of the module (e.g., 'gleam/list')

**Example:** "Show me the functions in gleam/option"

## Available Resources

### `gleam://packages`
Lists popular Gleam packages from hex.pm sorted by recent downloads.

## Caching

The server uses Cloudflare D1 (SQLite) for caching with the following TTLs:

| Data Type | TTL |
|-----------|-----|
| Package info | 1 hour |
| Search results | 1 hour |
| Package interfaces | 24 hours |

Cache writes happen in the background using `waitUntil`, so responses are returned immediately while caching completes asynchronously.

## Development

```sh
npm run dev      # Start local dev server with wrangler
npm run build    # Build the Gleam project
npm run deploy   # Deploy to Cloudflare Workers
```

## Configuration

**wrangler.toml:**
```toml
name = "gleam-package-mcp"
main = "src/index.mjs"
compatibility_date = "2024-01-01"
compatibility_flags = ["nodejs_compat"]

[build]
command = "gleam build"

[[d1_databases]]
binding = "DB"
database_name = "mcp-packages-cache"
database_id = "your-database-id"
```
