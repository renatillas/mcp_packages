# Gleam Package MCP Server

[![Package Version](https://img.shields.io/hexpm/v/mcp_packages)](https://hex.pm/packages/mcp_packages)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/mcp_packages/)

An MCP (Model Context Protocol) server that provides AI agents with access to Gleam package information, search, and documentation.

## Features

- **Search Gleam packages** by name or description
- **Get detailed package information** including versions and descriptions  
- **Build and access package documentation** with pagination support for large packages
- **Automatic package synchronization** every 6 hours
- **Persistent documentation caching** for faster subsequent requests

## Quick Start

### Local Development
```sh
gleam deps download
gleam run   # Starts the MCP server on port 3000
```

### Use Hosted Version
The MCP server is deployed and available at: **https://gleam-package-mcp.fly.dev**

## MCP Integration

### Claude Code

Add to your Claude Code configuration:

**Option 1: Use hosted version (recommended)**
```json
{
  "mcpServers": {
    "gleam-mcp": {
      "transport": "http",
      "url": "https://gleam-package-mcp.fly.dev"
    }
  }
}
```

**Option 2: Run locally**
```json
{
  "mcpServers": {
    "gleam-mcp": {
      "command": "gleam",
      "args": ["run"],
      "cwd": "/path/to/mcp_packages"
    }
  }
}
```

### Other AI Agents (Cline, Continue, Cursor)

**Using hosted version:**
```json
{
  "mcpServers": {
    "gleam-mcp": {
      "transport": "http",
      "url": "https://gleam-package-mcp.fly.dev"
    }
  }
}
```

**Running locally:**
```json
{
  "mcpServers": {
    "gleam-mcp": {
      "command": "gleam", 
      "args": ["run"],
      "cwd": "/absolute/path/to/mcp_packages"
    }
  }
}
```

## Available Tools

1. `search_packages` - Search for Gleam packages by name or description
2. `get_package_info` - Get detailed information about a specific package  
3. `get_package_interface` - Build documentation and extract interface JSON (with pagination)

## Usage Examples

Once integrated with your AI agent:

- "Search for Gleam packages related to json"
- "Get information about the wisp package"
- "Build documentation for the gleam_http package"

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

Further documentation can be found at <https://hexdocs.pm/mcp_packages>.
