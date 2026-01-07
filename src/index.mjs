// Cloudflare Worker entry point
// This file bridges the Gleam application to the Cloudflare Workers runtime

import { fetch } from "../build/dev/javascript/mcp_packages/mcp_packages.mjs";

export default { fetch };
