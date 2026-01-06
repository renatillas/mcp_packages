// Cloudflare Worker entry point
// This file bridges the Gleam application to the Cloudflare Workers runtime

import { fetch as gleamFetch } from "../build/dev/javascript/mcp_packages/mcp_packages.mjs";
import { Method$Post } from "../build/dev/javascript/gleam_http/gleam/http.mjs";
import { List } from "../build/dev/javascript/prelude.mjs";
import { Option$Some, Option$None } from "../build/dev/javascript/gleam_stdlib/gleam/option.mjs";
import { Scheme$Https, Scheme$Http } from "../build/dev/javascript/gleam_http/gleam/http.mjs";

// Convert a JavaScript Request to a Gleam Request
function toGleamRequest(jsRequest, body) {
  const url = new URL(jsRequest.url);

  // Convert headers to a list of tuples using Gleam's list format
  let headers = { head: undefined, tail: undefined };
  let current = headers;
  jsRequest.headers.forEach((value, key) => {
    const newNode = { head: [key.toLowerCase(), value], tail: { head: undefined, tail: undefined } };
    if (current.head === undefined) {
      headers = newNode;
      current = headers;
    } else {
      current.tail = newNode;
      current = newNode;
    }
  });
  // Terminate the list properly
  if (current.head !== undefined) {
    current.tail = { head: undefined, tail: undefined };
  }

  // Convert to proper Gleam list format (toList style)
  const headersList = List.fromArray(
    Array.from(jsRequest.headers.entries()).map(([k, v]) => [k.toLowerCase(), v])
  );

  // Parse query parameters
  const query = url.search ? Option$Some(url.search.slice(1)) : Option$None();
  const port = url.port ? Option$Some(parseInt(url.port)) : Option$None();

  // Map HTTP method string to Gleam type
  const method = methodFromString(jsRequest.method);

  return {
    method: method,
    headers: headersList,
    body: body,
    scheme: url.protocol === "https:" ? Scheme$Https() : Scheme$Http(),
    host: url.hostname,
    port: port,
    path: url.pathname,
    query: query,
  };
}

// Map HTTP method string to Gleam enum value
function methodFromString(_) {
  return Method$Post();  // For MCP, we only handle POST requests
}


// Convert a Gleam Response to a JavaScript Response
function toJsResponse(gleamResponse) {
  const headers = new Headers();
  const headersList = gleamResponse.headers.toArray();
  for (const [key, value] of headersList) {
    headers.set(key, value);
  }

  return new Response(gleamResponse.body, {
    status: gleamResponse.status,
    headers: headers,
  });
}

export default {
  async fetch(request, env, _) {
    try {
      // Read the request body
      const body = await request.text();

      // Convert to Gleam request format
      const gleamRequest = toGleamRequest(request, body);

      // Call the Gleam handler
      const gleamResponsePromise = gleamFetch(gleamRequest, env);

      // Wait for the promise and convert to JS response
      const gleamResponse = await gleamResponsePromise;
      return toJsResponse(gleamResponse);
    } catch (error) {
      console.error("Error in worker:", error);
      return new Response(JSON.stringify({
        jsonrpc: "2.0",
        id: null,
        error: {
          code: -32603,
          message: "Internal server error: " + error.message
        }
      }), {
        status: 500,
        headers: { "Content-Type": "application/json" }
      });
    }
  },
};
