// Cloudflare Worker entry point
// This file bridges the Gleam application to the Cloudflare Workers runtime

import { fetch as gleamFetch } from "../build/dev/javascript/mcp_packages/mcp_packages.mjs";
import { Post } from "../build/dev/javascript/gleam_http/gleam/http.mjs";
import { Some, None } from "../build/dev/javascript/gleam_stdlib/gleam/option.mjs";
import { Https, Http } from "../build/dev/javascript/gleam_http/gleam/http.mjs";

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
  const headersList = gleamListFromArray(
    Array.from(jsRequest.headers.entries()).map(([k, v]) => [k.toLowerCase(), v])
  );

  // Parse query parameters
  const query = url.search ? new Some(url.search.slice(1)) : new None();
  const port = url.port ? new Some(parseInt(url.port)) : new None();

  // Map HTTP method string to Gleam type
  const method = methodFromString(jsRequest.method);

  return {
    method: method,
    headers: headersList,
    body: body,
    scheme: url.protocol === "https:" ? new Https() : new Http(),
    host: url.hostname,
    port: port,
    path: url.pathname,
    query: query,
  };
}

// Convert an array to a Gleam-style linked list
function gleamListFromArray(arr) {
  let list = { head: undefined, tail: undefined };
  for (let i = arr.length - 1; i >= 0; i--) {
    list = { head: arr[i], tail: list };
  }
  return list;
}

// Map HTTP method string to Gleam enum value
function methodFromString(method) {
  return new Post();  // For MCP, we only handle POST requests
}

// Convert a Gleam linked list to a JavaScript array
function gleamListToArray(list) {
  const result = [];
  let current = list;
  while (current && current.head !== undefined) {
    result.push(current.head);
    current = current.tail;
  }
  return result;
}

// Convert a Gleam Response to a JavaScript Response
function toJsResponse(gleamResponse) {
  const headers = new Headers();
  const headersList = gleamListToArray(gleamResponse.headers);
  for (const [key, value] of headersList) {
    headers.set(key, value);
  }

  return new Response(gleamResponse.body, {
    status: gleamResponse.status,
    headers: headers,
  });
}

export default {
  async fetch(request, env, ctx) {
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
