# Issue #5: E2E Validation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy generated artifacts to real Cloudflare, verify proxyFetch + secret() round-trip.

**Architecture:** Replace Api.hx stubs with real implementations (server build only), inject env via DO constructor, point test app at httpbin.org, deploy and validate.

**Tech Stack:** Haxe 4.3.6, Cloudflare Workers/DO (wrangler 4.x), httpbin.org

**Working directory:** `/home/mikesol/Documents/GitHub/h4x0r/h4x0r-5` (worktree on branch `issue-5`)

---

### Task 1: Implement real proxyFetch and secret in Api.hx

**Files:**
- Modify: `src/h4x0r/Api.hx`

**Step 1: Replace proxyFetch with conditional implementation**

```haxe
public static function proxyFetch(url:String, headers:Dynamic, body:Dynamic):Dynamic {
    #if h4x0r_server
    return js.Syntax.code(
        "fetch({0}, {method: 'POST', headers: Object.assign({'Content-Type': 'application/json'}, {1}), body: JSON.stringify({2})}).then(function(r) { return r.json(); })",
        url, headers, body);
    #else
    return null;
    #end
}
```

**Step 2: Replace secret with conditional implementation**

```haxe
public static function secret(name:String):String {
    #if h4x0r_server
    return js.Syntax.code("(globalThis.__h4x0r_env && globalThis.__h4x0r_env[{0}]) || ''", name);
    #else
    return "";
    #end
}
```

**Step 3: Update the SCAFFOLD comment**

Update the doc comment to reflect that proxyFetch and secret now have real server implementations as of issue #5. Remove the "Later phases replace these" language.

**Step 4: Compile and verify**

Run: `haxe build.hxml 2>&1`

Check `gen/server.js` contains real `fetch(` call and `globalThis.__h4x0r_env` access (not just `return null`).
Check `gen/client.js` still has proxy stubs (fetch('/rpc', ...)) — client side unchanged.

**Step 5: Commit**

```bash
git add src/h4x0r/Api.hx
git commit -m "feat(#5): implement real proxyFetch and secret for server build"
```

---

### Task 2: Inject env into globalThis from DO constructor

**Files:**
- Modify: `src/h4x0r/Build.hx`

**Step 1: Update emitDOShell() constructor**

In the DO constructor generation, add a line after `this.env = env;`:

```haxe
buf.add("    globalThis.__h4x0r_env = env;\n");
```

So the constructor becomes:
```javascript
constructor(state, env) {
    this.state = state;
    this.storage = state.storage;
    this.env = env;
    globalThis.__h4x0r_env = env;
    this.app = new globalThis.TestApp();
}
```

**Step 2: Compile and verify**

Run: `haxe build.hxml 2>&1`

Check `gen/do.js` constructor contains `globalThis.__h4x0r_env = env;`.

**Step 3: Commit**

```bash
git add src/h4x0r/Build.hx
git commit -m "feat(#5): inject env into globalThis from DO constructor"
```

---

### Task 3: Update TestApp to use httpbin.org

**Files:**
- Modify: `test/TestApp.hx`
- Modify: `test/Main.hx`

**Step 1: Update fetchData to use httpbin.org**

```haxe
public function fetchData(query:String):Dynamic {
    return Api.proxyFetch("https://httpbin.org/post",
        {authorization: "Bearer " + Api.secret("api-key")},
        {query: query});
}
```

**Step 2: Update Main.hx for client-side test**

The Main.hx should be able to invoke fetchData from the browser. For a simple validation, log the result:

```haxe
class Main {
    static function main() {
        var app = new TestApp();
        trace("TestApp instantiated");
        #if !h4x0r_server
        trace(app.format("hello"));
        // Call the server-proxied method and log the result
        var result = app.fetchData("test");
        js.Syntax.code("Promise.resolve({0}).then(function(r) { console.log('fetchData result:', JSON.stringify(r)); })", result);
        #end
    }
}
```

**Step 3: Compile and verify**

Run: `haxe build.hxml 2>&1`

Check that `gen/client.js` calls `fetch('/rpc', ...)` for fetchData.
Check that `gen/server.js` calls `fetch("https://httpbin.org/post", ...)` in the real implementation.

**Step 4: Commit**

```bash
git add test/TestApp.hx test/Main.hx
git commit -m "feat(#5): point TestApp at httpbin.org for E2E validation"
```

---

### Task 4: Deploy and validate

**Files:**
- No source changes — deployment and verification only

**Step 1: Deploy to Cloudflare**

```bash
cd gen && wrangler deploy 2>&1
```

**Step 2: Set the test secret**

```bash
echo "test-secret-value-12345" | wrangler secret put api-key
```

**Step 3: Verify with curl**

```bash
curl -X POST https://test-app.<your-subdomain>.workers.dev/rpc \
  -H "Content-Type: application/json" \
  -d '{"method": "TestApp.fetchData", "args": {"query": "hello"}}' 2>&1
```

Expected: JSON response from httpbin.org containing:
- `headers.Authorization: "Bearer test-secret-value-12345"` (proves secret() works)
- `json.query: "hello"` (proves proxyFetch forwarded the body)

**Step 4: Check client JS size**

```bash
gzip -c gen/client.js | wc -c
```

Expected: < 5120 bytes (5 KiB)

**Step 5: Record validation log**

Create `docs/validation/2026-02-11-issue-5-e2e.md` with curl output, gzip size, and deployment logs as evidence.

**Step 6: Final commit**

```bash
git add -A
git commit -m "feat(#5): E2E validation — deploy to Cloudflare, verify round-trip

Validates the full h4x0r Phase 1 pipeline:
- Client proxy stub → Worker → DO → real proxyFetch → httpbin.org
- secret() resolves from Cloudflare env, not source code
- Client JS size within budget

Closes #5"
```

---

## Notes

- **wrangler deploy requires auth**: The user must be authenticated with Cloudflare (`wrangler login` or `CLOUDFLARE_API_TOKEN` env var). If not authenticated, Task 4 will need user interaction.

- **httpbin.org availability**: If httpbin.org is down, any public POST echo service works. The key is verifying the Authorization header appears in the response.

- **Secret naming**: Cloudflare secrets are case-sensitive. The secret name `api-key` in code must match what's set via `wrangler secret put api-key`.

- **Client JS size**: The current `gen/client.js` is ~1.8K uncompressed, so gzipped should be well under 5 KiB.
