# h4x0r — Vision Document v0.1.0

> Eliminate the backend.

The developer writes one Haxe class. The compiler produces everything: client JS, Cloudflare Worker, Durable Object code, migration SQL, deployment config. No runtime framework. No backend code. The Haxe compiler IS the codegen.

**The developer writes client code.** The server is an implementation detail the compiler manages. You don't think about "this is a server method" vs "this is a client method." You write an application that conceptually runs in the browser, and the compiler figures out what needs to run where.

---

## 1. Core Principles

1. **The server is an implementation detail.** The developer writes client code. The compiler routes operations through the server when needed (secrets, API calls, guarded state). No manual server/client annotations on methods.

2. **Compile-time, not runtime.** All code generation, context splitting, and optimization happens during Haxe compilation via `@:build` macros and `onAfterGenerate`. Zero framework runtime in the browser.

3. **Ejectability by design.** Every generated artifact is independently runnable. The framework is a compiler, not a dependency. You can take the generated Worker, DO, client JS, and SQL migrations and deploy them without h4x0r.

4. **Real infrastructure, not abstractions.** Cloudflare Workers, Durable Objects, D1, R2 — the framework generates code for real services. No abstraction layers that hide what's happening.

5. **The event log is the source of truth.** Every state change is an immutable event. The sync protocol, offline support, and state verification all flow from the append-only log.

6. **Security at cost-inducing boundaries.** Verification happens at the moment before the proxy spends money on an external API call. The proxy is domain-ignorant — it enforces mechanical rules, not business logic.

7. **Agent-first.** The primary consumer of error messages, logs, and debugging tools is an LLM agent. Human-readable is a bonus, not the goal.

---

## 2. How It Works

### What the developer writes

```haxe
@:build(h4x0r.Build.process())
class PhotoApp {
    @:shared var shoots:Array<Shoot> = [];
    @:guard("credits") @:shared var credits:Int = 0;

    @:auth(providers = ["google", "github"], credentials = true)
    @:store("photos") var photoStorage:StoreBucket;

    public function createShoot(name:String):Void {
        shoots.push(new Shoot(newId(), name, Active));
    }

    public function editPhoto(shootId:String, photoId:String, prompt:String):Void {
        var result = proxyFetch("https://api.openai.com/v1/images/edits",
            {authorization: "Bearer " + secret("ai-key")},
            {image: photos[photoId].url, prompt: prompt}
        );
        db.update("photos", photoId, {editedUrl: result.url});
    }

    public function renderShoots():Void {
        var container = js.Browser.document.getElementById("shoots");
        for (shoot in shoots) {
            var div = js.Browser.document.createElement("div");
            div.textContent = shoot.name;
            container.appendChild(div);
        }
    }
}
```

### What the compiler infers

| Method | Signals detected | Placement |
|---|---|---|
| `createShoot` | Mutates `@:shared`, no proxyFetch, not destructive | Optimistic (client-local, confirm via DO) |
| `editPhoto` | `proxyFetch` + `secret()` | Server (DO verifies context, forwards API call) |
| `renderShoots` | DOM references (`js.Browser.document`) | Client only |

No annotations on methods. The compiler reads `proxyFetch`, `secret()`, `js.Browser.*`, `@:shared` state access, and destructive patterns to classify every operation.

### What the compiler produces

```
gen/
  client.js       # Haxe-compiled client (editPhoto body → fetch proxy)
  server.js       # Haxe-compiled server (editPhoto body → real impl, renderShoots stripped)
  do.js           # Thin JS shell: DO lifecycle, imports server.js
  worker.js       # Stateless router: JWT validation, CORS, DO routing
  wrangler.toml   # Cloudflare deployment config
  migrations/     # SQLite DDL from @:shared types
  manifest.md     # API documentation
```

Dual Haxe compilation: same source, two JS targets. The `@:build` macro strips differently based on `#if h4x0r_server`. The DO shell is the only hand-generated JS — thin infrastructure glue that imports the Haxe-compiled server module.

---

## 3. Primitives

Annotations for state declarations and infrastructure bindings. Never for method placement.

### `@:shared`

Declares state synced between client and server via the event log. On the client, backed by IndexedDB. On the server, backed by DO SQLite. The macro generates migration SQL from the type definition.

```haxe
@:shared var todos:Array<Todo> = [];
@:shared var filter:String = "all";
```

### `@:guard("name")`

Marks state where only proxy-minted events can increase the value. The proxy doesn't understand what "credits" means — it enforces a mechanical rule: "for state marked `@:guard('credits')`, only events generated by the proxy can increase it."

```haxe
@:guard("credits") @:shared var credits:Int = 0;

public function useCredits(prompt:String):Void {
    // proxyFetch → routed through server
    // Proxy verifies credits > 0, forwards API call, mints "credit_deducted" event
    var result = proxyFetch(AI_API,
        {authorization: "Bearer " + secret("ai-key")},
        {prompt: prompt}
    );
    processResult(result);
}
```

### `@:shared` with `shared("name")` (multi-user)

Declares state as shared across multiple users in an organization. Shared state lives in an org-level Durable Object (one DO per org, not per user). Multiple clients connect to the same org DO via WebSocket. The DO is single-threaded, providing natural total ordering of all events without distributed consensus.

The compiler analyzes operations on shared state and classifies them:

| Pattern detected | Classification | Behavior |
|---|---|---|
| Mutates shared state, no proxyFetch, not destructive | **Optimistic** | Apply locally, send to DO for sequencing, confirm/rollback |
| Mutates shared state, sets a tombstone/deleted status | **Barrier** | Send to DO immediately, DO broadcasts to all connected clients |
| Contains proxyFetch + references shared state | **Verified** | DO checks that referenced entities are valid before forwarding API call |
| Reads shared state only | **Local** | Read from local materialized view, no coordination |

```haxe
@:shared var shoots:Array<Shoot> = [];
@:guard("credits") @:shared var credits:Int = 0;

public function createShoot(name:String):Void {
    // Compiler: optimistic (not destructive, no proxyFetch)
    shoots.push(new Shoot(newId(), name, Active));
}

public function deleteShoot(id:String):Void {
    // Compiler: barrier (destructive — status → Deleted)
    db.update("shoots", id, {status: Deleted});
}

public function editPhoto(shootId:String, photoId:String, prompt:String):Void {
    // Compiler: verified (proxyFetch + references shared state)
    var result = proxyFetch(AI_API,
        {authorization: "Bearer " + secret("ai-key")},
        {image: photos[photoId].url, prompt: prompt}
    );
    db.update("photos", photoId, {editedUrl: result.url});
}
```

### `@:auth(providers, credentials)`

Declarative auth. The compiler generates proxy routes (signup, signin, OAuth initiate, OAuth callback, token refresh), D1 tables (user, account), client-side auth management (JWT storage, refresh timer, header injection), and JWT validation middleware.

```haxe
@:auth(
    providers = ["google", "github"],
    credentials = true,
    jwtSecret = secret("jwt-signing-key")
)
```

**Implementation:** Oslo (cryptographic primitives) + Arctic (OAuth 2.0 clients), both edge-compatible pure-function libraries.

### `@:permit(write, read)`

Role-based access control for state and operations. Auth provides identity ("who is this user?"); permit provides authorization ("what can this user do?"). Permit is optional — apps without it allow any authenticated user to perform any action.

```haxe
@:permit(write = ["admin", "photographer"], read = ["client", "viewer"])
var shootAccess:PermitRule;

@:permit(allowed = ["subscriber"])
var creditSpend:PermitRule;
```

### `@:store("name")`

Named blob storage bucket backed by Cloudflare R2. The compiler generates upload URL endpoints, download URL endpoints with signed URLs, and garbage collection hooks tied to event log compaction.

```haxe
@:store("photos") var photoStorage:StoreBucket;

public function uploadPhoto(shootId:String, file:FileUpload):Void {
    var uploadUrl = photoStorage.getUploadUrl(file.contentType);
    // Client uploads directly to R2 (no proxy bandwidth cost)
    db.insert("photos", new Photo(newId(), shootId, uploadUrl.key));
}
```

### `@:webhook(path, verify)`

Stable incoming endpoint with signature verification. Registered as a fixed route on the DO.

```haxe
@:webhook("/hooks/stripe", verify = "stripe")
public function handlePayment(payload:Dynamic):Void {
    credits += payload.amount;
}
```

### `@:cron("schedule")`

Recurring scheduled work via Cloudflare Cron Triggers. Runs on the DO.

```haxe
@:cron("0 */6 * * *")
public function cleanupExpired():Void {
    for (shoot in shoots) {
        if (shoot.status == Expired) db.delete("shoots", shoot.id);
    }
}
```

### `@:after("duration")`

One-shot delayed execution via DO Alarms. Distinct from `@:cron` — fires once, not recurring.

```haxe
@:after("7d")
public function sendReminder(shootId:String):Void {
    // fires once, 7 days after scheduling
}
```

### Automatic context splitting

Not a primitive the developer invokes, but a compiler optimization. The compiler analyzes each code block for browser-only operations (DOM, Canvas, WebAudio, `js.Browser.*`). Code without browser dependencies is portable — the compiler can choose to run it on the client or server. Code with browser dependencies is anchored to the client.

For blocks with multiple `proxyFetch` calls, the compiler uses browser API anchors as split boundaries:

```haxe
public function processAndDisplay(prompt:String):Void {
    // No browser APIs — portable, compiler batches server-side
    var data = proxyFetch(DATA_API, {auth: "Bearer " + secret("key")});
    var analysis = proxyFetch(AI_API, {data: data});

    // DOM — browser anchor, must run on client
    var canvas = js.Browser.document.getElementById("preview");
    canvas.innerHTML = analysis.svg;

    // This proxyFetch is a separate round-trip (anchored by DOM above)
    proxyFetch(SAVE_API, {report: canvas.innerHTML});
}
```

The compiler determines: the first two proxyFetch calls can be batched server-side (2 round-trips become 0). The DOM operation forces a return to the client. The final proxyFetch is a separate round-trip. Total: 2 round-trips instead of 3, with no developer annotation.

---

## 4. The Sync Protocol

*This section is architecturally identical to unanim VISION.md Section 4. The protocol is language-agnostic.*

### 4.1 Architecture

**Client:** IndexedDB stores the event log and materialized state. The framework abstracts IndexedDB entirely — developers write SQL-like queries, and the compiler validates them against migrations at compile time. No WASM SQLite on the client (1.5MB bundle too steep).

**Server:** One Cloudflare Durable Object per user, with SQLite storage (GA, 10GB per object, ACID, single-threaded). The DO holds: event log mirror, materialized state, secrets (encrypted), webhook routing, lease state. D1 handles shared metadata (user lookup, webhook routing tables, auth).

### 4.2 The Event Log

Every state change is recorded as an immutable event in an append-only log:

```
Event {
    sequence: u64,          // Monotonically increasing
    timestamp: DateTime,    // Wall clock (for debugging, not determinism)
    event_type: EventType,  // User action, API response, webhook, cron, proxy-minted
    schema_version: u32,    // Compiler-assigned version
    payload: bytes,         // Serialized event data
}
```

### 4.3 Writer Model: Distributed Single-Player

Exactly one writer at any time — either the client or the server, never both. No CRDTs, no multi-writer conflict resolution, no consensus protocols.

**Lease model (adapted from LiteFS):**
- The client holds the write lease while online
- Lease is maintained via proxyFetch calls (each call renews the lease)
- If the lease expires (client offline), the server takes over
- Server processes webhook payloads and cron handlers during offline
- When the client reconnects, it receives server-generated events and applies them
- The client resumes the lease

**Fencing tokens:** Each lease transfer increments a monotonic fencing token. Stale clients (old fencing token) are rejected.

### 4.4 Verification at Cost-Inducing Boundaries

The proxy:
1. Receives the event log delta from the client
2. Verifies sequence continuity (no gaps)
3. If verification passes: stores events, injects secrets, forwards the API call, mints guarded-state events
4. If verification fails: rejects with 409, returns server events for reconciliation
5. Returns: API response + proxy-generated events + pending server events

### 4.5 Guarded State and Proxy-Minted Events

Three tiers of state:
1. **Per-user, client-sovereign:** Normal state. Client is authoritative.
2. **Per-user, proxy-observable (guarded):** State with constraints. Proxy enforces invariants via minted events. Declared with `@:guard`.
3. **Shared, multi-user:** Org-level state. Lives in an org-level DO. Declared with `@:shared` on org-scoped classes.

### 4.6 Compile-Time Delegation

The Haxe macro analyzes code at compile time:

- **Single proxyFetch:** Runs on the client. Event log piggybacked on the call.
- **Multiple sequential proxyFetch calls:** The compiler delegates the entire block to the server. Instead of N round-trips, the server executes all N API calls locally.
- **Browser API anchors:** Force execution back to the client. The compiler splits around anchors.

### 4.7 Snapshots and Log Compaction

- Periodic snapshots (every N events or M minutes)
- Ring buffer of snapshots, old ones garbage-collected
- Log truncation after oldest retained snapshot
- Snapshot + Reset for major migrations

### 4.8 State Verification (Optional)

For debugging: server replays events through portable reducers and compares with client state. Hierarchical Merkle tree over state domains for O(log N) divergence localization.

### 4.9 The WebSocket Channel

The client maintains a hibernated WebSocket connection to its DO. This provides:
1. Immediate delivery of server-generated events (webhook results, cron output)
2. proxyFetch as a WebSocket message (with HTTP fallback)
3. Reactive push for server-minted events
4. Lease detection via `setWebSocketAutoResponse`

### 4.10 Shared State and Multi-User Organizations

For `@:shared` state with org scope, multiple users connect to the same org DO. The DO assigns monotonically increasing sequence numbers to all events.

### 4.11 Wire Protocol

JSON for readability; binary optimization is a v2 concern. See unanim VISION.md Section 4.11 for the full wire protocol specification (proxyFetch request/response, rejection, WebSocket event push, barrier push).

---

## 5. Schema Evolution

Three-tier strategy:

1. **Tolerant Reader:** New optional fields with defaults. No migration code needed.
2. **Upcasting:** Structural event changes via pure function transformers. Applied on read.
3. **Snapshot + Reset:** Major schema redesigns. Materialize, truncate, start fresh.

The Haxe macro is the schema registry. It reads `@:shared` types and diffs them across versions.

---

## 6. Infrastructure Mapping

### Reference Implementation: Cloudflare

| Framework Concept | Cloudflare Primitive | Role |
|---|---|---|
| Router | Worker | Stateless request routing |
| Per-user state | Durable Object (SQLite) | Event log, materialized state, lease, secrets |
| Shared metadata | D1 | User lookup, auth tables, webhook routing |
| Auth data | D1 | User/account tables (Oslo + Arctic generated) |
| File storage | R2 | `@:store` — blob storage, zero egress, signed URLs |
| Config | KV | Feature flags, public keys |
| Async work | Queues | Webhook payload buffering |
| Recurring work | Cron Triggers | `@:cron` |
| Delayed work | DO Alarms | `@:after` — one-shot scheduled execution |
| Offline processing | DO Alarms | Server-side handler execution when client is offline |
| Auth secrets | Worker Secrets | JWT signing key, OAuth client secrets |

### Request Flow

```
Client (Browser)
  |
  | proxyFetch (with event log delta, JWT)
  v
Router Worker (stateless)
  |
  | 1. Validate JWT (Oslo)
  | 2. Route by user ID
  v
User Durable Object
  |
  | 3. Verify event sequence continuity
  | 4. Store verified events
  | 5. Inject secrets
  | 6. Forward API call (or delegate multi-call block)
  | 7. Mint guarded-state events
  | 8. Return: API response + server events
  v
Client applies server events, updates local state
```

---

## 7. Migration and Ejection

### Component Ejection

| Component | What "eject" means | What you get |
|---|---|---|
| State (DO/SQLite) | Swap to Postgres, etc. | SQL migrations + event log schema + adapter interface |
| `@:cron` | Move to external scheduler | Standalone cron handler + crontab entry |
| `@:webhook` | Move to standalone endpoint | HTTP handler with signature verification |
| `@:auth` | Swap to Auth0, Clerk, etc. | OAuth config + session schema + token refresh logic |
| `@:store` | Swap to S3, GCS, etc. | Signed URL generation + upload handler |
| `proxyFetch` | Replace with direct API calls | Credential injection removed, secrets inlined |
| Full app | Take the whole generated project | Complete JS project, deployable standalone |

### Anti-Lock-In Checklist

For every feature: (1) What standard format does it map to? (2) Can the generated artifact run without h4x0r? (3) Can this feature be extracted without extracting everything? (4) Is the extraction path documented and tested?

---

## 7.5 Agent-First Observability

Every runtime artifact emits structured JSON logs designed for LLM consumption. Correlation IDs across client → Worker → DO → external API for end-to-end tracing.

### Agent-Accessible Interfaces

- **CLI**: `h4x0r dev`, `h4x0r env create`, `h4x0r env seed`, `h4x0r logs`, `h4x0r replay`
- **MCP server**: Tools for environment management, log querying, state inspection, error replay
- **API**: Programmatic access to everything the CLI and MCP expose

---

## 8. Performance Budgets

### 8.1 Comparative Benchmarks

The framework generates vanilla JS with zero framework runtime.

| Metric | Target | Rationale |
|---|---|---|
| Initial eager JS | ≤ Qwik (0-2 KiB) | Zero framework runtime |
| Total JS transferred | < 10 KiB gzipped | Framework overhead for standard CRUD app |
| First Contentful Paint | < 1.0s static, < 1.5s interactive | On Fast 3G |
| Worker cold start overhead | < 10ms above vanilla CF Worker | Generated Worker must not add meaningful overhead |
| Proxy round-trip overhead | < 20ms above direct fetch | Client→Worker→origin vs client→origin |

### 8.2 Absolute Budgets (CI-Enforced)

| Generated Artifact | Max Size (gzipped) | Rationale |
|---|---|---|
| Worker JS (framework overhead) | 5 KiB | Proxy + CORS + DO routing |
| IndexedDB wrapper | 3 KiB | Event storage + query API |
| HTML shell (excluding app JS) | 2 KiB | Minimal document structure |
| Per-route client JS (framework overhead) | 2 KiB | Event handlers + sync glue |

---

## 9. The Haxe Macro Architecture

### Dual Compilation

One `haxe` invocation, two build targets:

```hxml
--class-path src
--macro h4x0r.Build.configure()

# Client target
--js gen/client.js
--next

# Server target
--js gen/server.js
-D h4x0r_server
```

The `@:build` macro checks `#if h4x0r_server` to strip differently:

- **Client build:** Server-bound methods → fetch proxy stubs. DOM methods → kept. `@:shared` → IndexedDB.
- **Server build:** Server-bound methods → kept (real impl). DOM methods → stripped. `@:shared` → SQLite.

### Artifact Generation

`Context.onAfterGenerate()` emits infrastructure artifacts:
- `gen/do.js` — Thin JS shell importing `gen/server.js`, wiring Cloudflare DO lifecycle
- `gen/worker.js` — Stateless router
- `gen/wrangler.toml` — Deployment config
- `gen/migrations/*.sql` — DDL from `@:shared` types
- `gen/manifest.md` — API documentation

### Method Placement Analysis

The macro walks each method's AST looking for:

| Signal | Meaning |
|---|---|
| `proxyFetch(...)` | Must go through server |
| `secret(...)` | Must go through server |
| `js.Browser.*`, `js.html.*` | Must stay on client (browser anchor) |
| `@:shared` state mutation, not destructive | Optimistic (client + DO confirm) |
| `@:shared` state mutation, destructive pattern | Barrier (DO immediately) |
| `@:shared` state read only | Local (client) |
| Multiple sequential `proxyFetch` | Batch server-side |
| `proxyFetch` → browser anchor → `proxyFetch` | Split: server batch → client → server |

No `@:server` or `@:client` annotations. The compiler infers everything.

---

## 10. Build Plan

### Phase 1: Foundation

- `@:build` macro: dual compilation, proxyFetch/secret detection, proxy stub generation
- Thin DO shell importing Haxe-compiled server.js
- Generated worker.js (stateless router) and wrangler.toml
- Deploy to real Cloudflare, verify credential injection and round-trip
- Performance: client JS size within budget

### Phase 2: State

- Event log: append, sequence continuity, verify at proxyFetch boundary
- IndexedDB on client, SQLite in DO
- `@:shared` types → migration SQL generation
- Validate: events survive browser refresh, DO restart

### Phase 3: Sync

- proxyFetch carries event log delta automatically
- DO returns missed server events bidirectionally
- `/do/sync` endpoint for event-only exchange
- 409 reconciliation: server wins, client retries
- Offline queue: events buffered, proxyFetch disabled offline
- Todo reference app deployed, validated in browser

### Phase 3b: Real-Time & Lease

- WebSocket channel (hibernated, server→client push)
- proxyFetch-over-WebSocket with HTTP fallback
- Three-layer lease mechanism
- Fencing tokens, server takeover

### Phase 4: Primitives

- `@:guard` — proxy-minted events
- `@:permit` — role-based access control
- `@:auth` — OAuth + JWT
- `@:webhook` — stable endpoints, signature verification
- `@:cron` — recurring (Cron Triggers)
- `@:after` — one-shot delayed (DO Alarms)
- `@:shared` multi-user — org DO + barrier broadcast
- `@:store` — R2 blob storage
- Automatic context splitting
- Reactive push over WebSocket

### Phase 4b: Observability

- Structured log emission
- Ephemeral environments, state seeding, error replay
- CLI tools

### Phase 5: Battle Testing

- Port real apps, discover gaps
- Comparative benchmarks
- LLM-friendly compiler errors
- MCP server for agent-driven debugging

### Phase 6: Developer Experience

- SSR and islands (from context splitting analysis)
- Ejection tooling
- Documentation

---

## 11. What's Explicitly Out of Scope

- **Custom server-side logic.** The proxy does not execute arbitrary application code beyond portable handlers.
- **Real-time collaborative editing.** No CRDTs. "Multiple people contribute to a shared pool" is in; "multiple people edit the same thing simultaneously" is out.
- **Domain-aware proxy logic.** The proxy never interprets business meaning.
- **Frontend framework.** h4x0r is not React/Vue/Svelte. It generates static HTML and JS islands.
- **Multi-region replication.** Uses Cloudflare's global network, but no custom cross-region replication.

---

## 12. Build Philosophy

### Learn by building

Many assumptions are educated guesses. The build process validates assumptions early and revises them without shame.

### Always build against the real thing

Every implementation step validated against real Cloudflare (`wrangler`) and real browser. Not mocks.

### Revise this document

This vision doc should be updated as the build progresses. When an assumption is validated, note it. When an assumption is wrong, cross it out and write what we learned.
