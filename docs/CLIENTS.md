# MCP Client Configuration

ChromeMCP runs a Streamable HTTP MCP server at:

```text
http://localhost:8931/mcp
```

Start and verify it before configuring clients:

```bash
cd ~/ChromeMCP
./mcp-up
./mcp-status
bash mcp/test.sh
```

## Generic MCP Snippet

Merge the `chromemcp-playwright` entry into the MCP client config:

```json
{
  "mcpServers": {
    "chromemcp-playwright": {
      "type": "http",
      "url": "http://localhost:8931/mcp",
      "headers": { "Authorization": "Bearer <TOKEN>" }
    }
  }
}
```

Older MCP clients that do not support Streamable HTTP can use `http://localhost:8931/sse`.

## Claude Code

Use a project-local `.mcp.json` when you want ChromeMCP available only for one project:

```json
{
  "mcpServers": {
    "chromemcp-playwright": {
      "type": "http",
      "url": "http://localhost:8931/mcp"
    }
  }
}
```

For global availability, merge the same `mcpServers` entry into `~/.claude.json`.

## Cursor

Merge the same `mcpServers` entry into:

```text
~/.cursor/mcp.json
```

## Codex

Codex can opt a trusted web repository into the shared server without installing
a browser runtime in that repository. Export the shared token before launching
Codex from the same shell:

```bash
export CHROMEMCP_AUTH_TOKEN="$(<~/.config/chromemcp/token)"
```

Then add this to that repository's `.codex/config.toml`:

```toml
[mcp_servers.chromemcp-playwright]
url = "http://localhost:8931/mcp"
bearer_token_env_var = "CHROMEMCP_AUTH_TOKEN"
enabled = true
required = false
```

Do not commit the token itself. Repositories without a web interface or an
explicit browser need should omit this block. The current shared-runtime setup
does not install a Codex plugin; `docs/CODEX_PLUGIN.md` is retained only as
historical packaging guidance unless that distribution path is explicitly
reintroduced.

## Python Scripts

Use the supported standard-library Python helper instead of copying test
harness code:

```python
from mcp.client import McpClient

client = McpClient()
client.initialize()
print(client.tool_text(client.call_tool("browser_tabs", {"action": "list"})))
```

See `docs/PYTHON_CLIENT.md` for tab-session helpers, structured results,
CLI usage, auth lookup, and common failure handling.
