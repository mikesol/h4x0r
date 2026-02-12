# Issue #5: E2E Validation — Design

**Date:** 2026-02-11
**Issue:** https://github.com/mikesol/h4x0r/issues/5
**Status:** Design approved, ready for implementation

## Summary

Deploy the generated artifacts to real Cloudflare and verify the full pipeline: client proxy stub → Worker → DO → proxyFetch with secret() → external API → response back to client.

## What changes

### 1. Api.hx — Real server-side implementations

Replace no-op stubs with `#if h4x0r_server` conditional implementations:

- `secret(name)` → reads from `globalThis.__h4x0r_env[name]` (Cloudflare env bindings)
- `proxyFetch(url, headers, body)` → real `fetch()` with merged headers, returns parsed JSON

Client-side stubs stay as-is (bodies get replaced by proxy stubs in the macro anyway).

Uses `js.Syntax.code` to embed raw JS, avoiding Haxe type system conflicts with Cloudflare globals.

### 2. Build.hx emitDOShell() — Inject env into global

Add `globalThis.__h4x0r_env = env;` to the DO constructor so Api.secret() can access Cloudflare environment bindings.

### 3. TestApp.hx — Point at real API

Update `fetchData` to use `https://httpbin.org/post` as the target. This echo service returns headers and body, letting us verify both proxyFetch and secret() injection.

### 4. Main.hx — Client-invocable test

Add a way to call fetchData from the client and display the result.

### 5. Deployment and validation

- `haxe build.hxml` → compile
- `wrangler deploy` from `gen/`
- `wrangler secret put api-key` → set test secret
- `curl` the deployed Worker → verify response includes echoed secret
- Check client.js gzipped size < 5 KiB

## Acceptance criteria (from issue)

- [ ] `wrangler deploy` succeeds with generated artifacts
- [ ] Browser client successfully calls a server-proxied method
- [ ] `secret()` resolves from Cloudflare secrets, not source code
- [ ] `proxyFetch` reaches the external API and returns a response
- [ ] Client JS framework overhead < 5 KiB gzipped
- [ ] Validation log with evidence (curl output, wrangler logs)
