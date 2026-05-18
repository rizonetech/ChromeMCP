#!/usr/bin/env bash
# Smoke test for the running Playwright MCP server.
# Verifies the full MCP protocol path: initialize -> initialized -> tool call.
# Exits non-zero on any failure so you can chain it in scripts/CI.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

URL="${MCP_URL:-http://localhost:8931/mcp}"

python3 - <<PYEOF
import json, sys, urllib.request, urllib.error

URL = "$URL"
HEADERS_BASE = {
    "Content-Type": "application/json",
    "Accept":       "application/json, text/event-stream",
}

def post(payload, sid=None, expect_response=True):
    headers = dict(HEADERS_BASE)
    if sid:
        headers["Mcp-Session-Id"] = sid
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(),
                                 headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read().decode("utf-8", errors="replace")
            new_sid = (r.headers.get("mcp-session-id")
                       or r.headers.get("Mcp-Session-Id")
                       or sid)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        new_sid = sid
    if not expect_response:
        return None, new_sid
    # SSE: one or more "data: {...}" lines. Take the last one.
    payloads = [ln[6:] for ln in body.splitlines() if ln.startswith("data: ")]
    if not payloads:
        # Plain JSON or empty
        try:
            return json.loads(body), new_sid
        except Exception:
            sys.stderr.write(f"[server raw response] {body[:500]}\n")
        raise SystemExit("Could not parse MCP response")
    return json.loads(payloads[-1]), new_sid

def text_content(resp):
    content = resp.get("result", {}).get("content", [])
    return next((c.get("text","") for c in content if c.get("type")=="text"), "")

def assert_tool_ok(resp, label):
    if "error" in resp:
        raise SystemExit(f"FAIL: {label}: {resp['error']}")
    result = resp.get("result", {})
    text = text_content(resp)
    if result.get("isError") or text.lstrip().startswith("### Error"):
        sys.stderr.write(f"[{label} tool response]\n{text[:1000]}\n")
        raise SystemExit(f"FAIL: {label}: MCP tool returned an error")
    return text

# 1. initialize
print("1. initialize ...", end=" ", flush=True)
resp, sid = post({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": "2025-03-26",
        "capabilities": {},
        "clientInfo": {"name": "chromemcp-smoketest", "version": "0.1.0"},
    },
})
if "error" in resp:
    raise SystemExit(f"FAIL: {resp['error']}")
server = resp["result"]["serverInfo"]
print(f"OK ({server['name']} {server['version']}, session {sid[:8]}...)")

# 2. notifications/initialized (no response)
print("2. notifications/initialized ...", end=" ", flush=True)
post({"jsonrpc": "2.0", "method": "notifications/initialized"},
     sid=sid, expect_response=False)
print("OK")

# 3. browser_tabs(list) - proves talk-to-Chrome roundtrip
print("3. browser_tabs(action=list) ...", end=" ", flush=True)
resp, _ = post({
    "jsonrpc": "2.0", "id": 2, "method": "tools/call",
    "params": {"name": "browser_tabs", "arguments": {"action": "list"}},
}, sid=sid)
text = assert_tool_ok(resp, "browser_tabs")
print("OK")
print("   --- live tabs as seen by Playwright MCP via CDP ---")
for line in text.strip().splitlines()[:15]:
    print(f"   {line}")
print("   --- end ---")

# 4. browser_snapshot - proves DOM/a11y read-back
print("4. browser_snapshot ...", end=" ", flush=True)
resp, _ = post({
    "jsonrpc": "2.0", "id": 3, "method": "tools/call",
    "params": {"name": "browser_snapshot", "arguments": {}},
}, sid=sid)
text = assert_tool_ok(resp, "browser_snapshot")
lines = text.strip().splitlines()
print(f"OK ({len(lines)} lines of accessibility tree)")
print("   first 8 lines:")
for line in lines[:8]:
    print(f"   {line[:100]}")

print()
print("All checks passed. The MCP server can drive your Chrome.")
PYEOF
