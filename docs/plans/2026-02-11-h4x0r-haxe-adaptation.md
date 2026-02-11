# h4x0r: Unanim Reimagined in Haxe

**Date:** 2026-02-11
**Status:** Design complete, ready for fresh repo creation

## 1. Vision and Core Change

The vision is identical to unanim: **eliminate the backend.** The developer writes one Haxe class with annotations. The compiler produces client JS, Cloudflare Worker, Durable Object code, migration SQL, and config files. No runtime framework. No codegen IR. The Haxe compiler IS the codegen — it emits clean JS natively for all targets.

### What changes from the Nim version

- **`nim js` output hygiene disappears entirely.** Haxe's `String` is JS's `String`. No byte arrays, no helper functions, no macro hacks. The Nim version required a compile-time macro pass to rewrite stdlib calls to JS-native equivalents. Haxe doesn't need this — it produces clean JS by default. This was validated in a benchmark spike: 338 lines of Haxe output vs 2,099 lines of Nim output for the same program.

- **The codegen IR is eliminated.** The Nim version needed a Nim-hosted AST (intermediate representation) that emits TypeScript/JavaScript for infrastructure artifacts (Worker, DO, IndexedDB helper, sync helper). With Haxe, dual compilation handles this: one Haxe build for client JS, one for server JS. The only generated-JS artifact is a thin Cloudflare lifecycle shell.

- **`gorge`/`gorgeEx` replaced.** Nim's compile-time shell commands become Haxe's `sys.io.File` for compile-time file I/O and `Context.onAfterGenerate()` for post-compilation artifact emission.

- **AST representation changes.** Nim's `nnkCall`/`nnkIdent` node kinds become Haxe's `Expr` enum with pattern matching — more ergonomic, same capability.

- **Browser FFI is mature.** Nim's `importjs` pragma (with open questions about ergonomics) is replaced by Haxe's `js.Browser`, `js.html.*` externs — a complete, well-tested set of browser API bindings that ship with the compiler.

### What stays the same

Everything that's language-agnostic:

- The full sync protocol (event log, sequence continuity, proxyFetch piggybacking)
- All 8 primitives (guard, permit, webhook, cron, after, shared, auth, store)
- Automatic context splitting (compiler optimization, not user-facing)
- Cloudflare-first infrastructure mapping (DO, D1, R2, Workers, Cron Triggers)
- Ejectability by design
- Performance budgets
- Agent-first observability
- The phased build approach

---

## 2. The Macro Architecture

h4x0r's compile-time magic is built on three Haxe macro features:

### `@:build` macros

The primary mechanism. Applied to each h4x0r class via `@:build(h4x0r.Build.process())`. The build macro:

- Reads metadata from fields: `@:shared`, `@:guard`, `@:permit`, `@:auth`, `@:webhook`, `@:cron`, `@:after`, `@:store`
- Analyzes method bodies to determine placement (see Section 3)
- Rewrites method bodies based on compilation target (`#if h4x0r_server` vs client)
- Collects server endpoint signatures for DO shell generation

### `Context.onAfterGenerate()`

Post-compilation hook. After the Haxe compiler finishes type-checking and code generation, h4x0r emits:

- `gen/do.js` — Thin JS shell importing Haxe-compiled server module, wiring into Cloudflare DO lifecycle
- `gen/worker.js` — Stateless Cloudflare Worker with JWT validation, routing, CORS
- `gen/wrangler.toml` — Cloudflare deployment config with DO bindings, R2 buckets, cron triggers, secrets
- `gen/migrations/*.sql` — SQLite DDL derived from `@:shared` state types
- `gen/manifest.md` — Human-readable API documentation

### Custom metadata

h4x0r's annotation vocabulary — used only for state declarations and infrastructure bindings, never for method placement:

| Metadata | Applied to | Purpose |
|---|---|---|
| `@:shared` | `var` fields | State synced between client and server via event log |
| `@:guard("name")` | `@:shared` fields | Only proxy-minted events can increase this state |
| `@:permit(write=[...], read=[...])` | `var` fields | Role-based access control |
| `@:auth(providers=[...])` | Class-level | Generates signup/login/OAuth routes, JWT management |
| `@:webhook(path, verify)` | Methods | Incoming webhook endpoint with signature verification |
| `@:cron("schedule")` | Methods | Recurring scheduled work (Cron Triggers) |
| `@:after("duration")` | Methods | One-shot delayed execution (DO Alarms) |
| `@:store("name")` | `var` fields | R2 blob storage bucket |

Methods are **never** annotated with `@:server` or `@:client`. The compiler determines placement from their contents.

---

## 3. Developer Experience — What the User Writes

The developer writes client code. The server is an implementation detail.

```haxe
@:build(h4x0r.Build.process())
class PhotoApp {
    // State declarations
    @:shared var shoots:Array<Shoot> = [];
    @:shared var filter:String = "all";
    @:guard("credits") @:shared var credits:Int = 0;

    // Infrastructure bindings
    @:auth(providers = ["google", "github"], credentials = true)
    @:permit(write = ["admin", "photographer"], read = ["client"])
    var shootAccess:PermitRule;

    @:store("photos")
    var photoStorage:StoreBucket;

    // --- Everything below is just application code. ---
    // No @:server. No @:client. The compiler figures it out.

    public function createShoot(name:String):Void {
        shoots.push(new Shoot(newId(), name, Active));
    }

    public function deleteShoot(id:String):Void {
        db.update("shoots", id, {status: Deleted});
    }

    public function editPhoto(shootId:String, photoId:String, prompt:String):Void {
        // proxyFetch + secret() → compiler routes this through the server
        var result = proxyFetch("https://api.openai.com/v1/images/edits",
            {authorization: "Bearer " + secret("ai-key")},
            {image: photos[photoId].url, prompt: prompt}
        );
        db.update("photos", photoId, {editedUrl: result.url});
    }

    public function generateReport(shootId:String):Void {
        // 3 sequential proxyFetch calls → compiler batches server-side
        var data = proxyFetch(DATA_API, {auth: "Bearer " + secret("key")});
        var analysis = proxyFetch(AI_API, {data: data});
        var chart = proxyFetch(CHART_API, {analysis: analysis});

        // DOM → forces return to client
        var canvas = js.Browser.document.getElementById("preview");
        canvas.innerHTML = chart.svg;

        // This proxyFetch is a separate round-trip (anchored by DOM above)
        proxyFetch(SAVE_API, {report: canvas.innerHTML});
    }

    public function renderShoots():Void {
        // DOM references → client-anchored, no server involvement
        var container = js.Browser.document.getElementById("shoots");
        for (shoot in shoots) {
            var div = js.Browser.document.createElement("div");
            div.textContent = shoot.name;
            container.appendChild(div);
        }
    }

    // Webhook — incoming endpoint, not application flow
    @:webhook("/hooks/stripe", verify = "stripe")
    public function handlePayment(payload:Dynamic):Void {
        credits += payload.amount;
    }

    // Cron — recurring, not application flow
    @:cron("0 */6 * * *")
    public function cleanupExpired():Void {
        for (shoot in shoots) {
            if (shoot.status == Expired) db.delete("shoots", shoot.id);
        }
    }

    // Delayed — one-shot, not application flow
    @:after("7d")
    public function sendReminder(shootId:String):Void {
        // fires once, 7 days after scheduling
    }
}
```

### What the compiler infers

The developer wrote 8 methods with zero placement annotations. The compiler classifies all 8 from their contents:

| Method | Analysis | Placement |
|---|---|---|
| `createShoot` | Mutates `@:shared` state, no proxyFetch, not destructive | Optimistic (client-local, confirm via DO) |
| `deleteShoot` | Mutates `@:shared` state, destructive (→ Deleted) | Barrier (sent to DO immediately) |
| `editPhoto` | Contains `proxyFetch` + `secret()` | Server (DO verifies context, forwards API call) |
| `generateReport` | 3 proxyFetch → DOM → 1 proxyFetch | Server batch (first 3) → client (DOM) → server (last 1) |
| `renderShoots` | DOM only | Client only |
| `handlePayment` | `@:webhook` | Server (DO endpoint) |
| `cleanupExpired` | `@:cron` | Server (DO alarm) |
| `sendReminder` | `@:after` | Server (DO alarm, one-shot) |

SSR and islands fall out of the same analysis. Methods with no DOM references and no dynamic state produce static HTML at compile time. Methods with DOM references become JS islands loaded on demand.

---

## 4. Compilation Model — Dual Haxe Targets

One `haxe` invocation, two build targets defined in `build.hxml`:

```hxml
# build.hxml
--class-path src
--macro h4x0r.Build.configure()

# Client target
--js gen/client.js
--next

# Server target
--js gen/server.js
-D h4x0r_server
```

The `@:build` macro checks `#if h4x0r_server` to decide what to strip:

### Client build (`gen/client.js`)

- Methods containing `proxyFetch`/`secret()` → bodies replaced with fetch proxy calls
- Methods with DOM references → kept as-is
- `@:shared` state → backed by IndexedDB wrapper with sync glue
- Every proxy call automatically piggybacks the event log delta
- Offline queue: events buffered in IndexedDB when network unavailable; proxyFetch disabled (can't spend money offline)

### Server build (`gen/server.js`)

- Methods containing `proxyFetch`/`secret()` → kept as-is (real implementation)
- Methods with DOM references → stripped entirely
- `@:shared` state → SQLite-backed
- `secret()` calls → resolved from environment variables

### Infrastructure shell (`gen/do.js`)

A thin JS wrapper emitted via `onAfterGenerate` that imports `gen/server.js` and wires it into the Cloudflare DO lifecycle:

```javascript
import { PhotoApp } from "./server.js";

export class PhotoAppDO {
  constructor(state, env) {
    this.state = state;
    this.storage = state.storage;
    this.app = new PhotoApp(this.storage);
  }

  async fetch(request) {
    // Event log verification, secret injection, guard checks,
    // then delegates to this.app.editPhoto(...) etc.
  }

  async alarm() {
    // Cron/after handlers → this.app.cleanupExpired(), etc.
  }

  async webSocketMessage(ws, msg) {
    // Shared state events, lease management
  }
}
```

### Benefits of dual compilation

- Server code is type-safe Haxe, shares exact same type definitions as client
- No AST-to-JS translator needed in the macro
- The compiler catches type errors in server code just like client code
- `@:shared` types (Shoot, Photo, etc.) are defined once, used in both targets
- The DO shell is the only generated-JS artifact — infrastructure glue, not application logic

### Generated file tree

```
gen/
  client.js          # Haxe-compiled client (default target)
  server.js          # Haxe-compiled server methods
  do.js              # Thin JS shell importing server.js
  worker.js          # Stateless router (JWT, CORS, DO routing)
  wrangler.toml      # Cloudflare deployment config
  migrations/        # SQLite DDL from @:shared types
  manifest.md        # API documentation
```

---

## 5. What Carries Over from VISION.md

The following sections transfer from VISION.md (v0.3.0) with only cosmetic changes (Nim syntax → Haxe syntax in code examples). The architecture, protocol, and design decisions are identical:

### Sync Protocol (VISION.md Section 4)

Unchanged: event log, sequence continuity, proxyFetch piggybacking, distributed single-player writer model, lease mechanism, guarded state and proxy-minted events, compile-time delegation, snapshots and log compaction, optional state verification, WebSocket channel, shared state with org-level DOs, wire protocol.

### Schema Evolution (VISION.md Section 5)

Unchanged: three-tier strategy (tolerant reader, upcasting, snapshot+reset). "Compiler as schema registry" becomes "Haxe macro as schema registry" — the macro reads `@:shared` types and diffs them across versions.

### Infrastructure Mapping (VISION.md Section 6)

Unchanged: Cloudflare-first. DO, D1, R2, KV, Queues, Cron Triggers, DO Alarms. Request flow unchanged. Pricing considerations unchanged.

### Migration and Ejection (VISION.md Section 7)

Unchanged: component ejection, progressive extraction lifecycle, generated artifacts, anti-lock-in checklist. The codegen IR references are removed (no IR in h4x0r). "Nim macro" becomes "Haxe macro."

The "target ejection (multi-language codegen)" subsection simplifies: Haxe emits JS natively for both client and server. No separate application code vs infrastructure artifact distinction needed — it's all Haxe.

### Agent-First Observability (VISION.md Section 7.5)

Unchanged: structured JSON logs, ephemeral environments (miniflare-based), state seeding and reproduction, error replay, agent-accessible interfaces (CLI, MCP server, API). CLI commands become `h4x0r dev`, `h4x0r logs`, `h4x0r replay`, etc.

### Performance Budgets (VISION.md Section 8)

Unchanged targets. One simplification: the "nim js output hygiene" concern disappears. Haxe naturally meets JS size budgets without a cleanup macro pass. The benchmark suite and CI enforcement approach carry over as-is.

### Hard Problems, Scope, Testing, Footguns (VISION.md Sections 9-13)

All language-agnostic content carries over unchanged.

---

## 6. What's Different: Nim → Haxe Summary

| Nim VISION.md | h4x0r (Haxe) |
|---|---|
| `nim js` output hygiene macro pass | Not needed — Haxe emits clean JS natively |
| Codegen IR (Nim-hosted AST → TypeScript) | Eliminated — dual Haxe compilation + thin JS shell |
| `gorge`/`gorgeEx` for compile-time shell | `sys.io.File` + `Context.onAfterGenerate()` |
| `safe{}` blocks / portability check | Automatic context splitting via AST analysis (same goal, Haxe implementation) |
| Nim `importjs` pragma for browser FFI | Haxe `js.Browser`, `js.html.*` externs (mature, ships with compiler) |
| `nnkCall`/`nnkIdent` AST walking | Haxe `Expr` enum pattern matching |
| Phase 4a: Codegen IR | Eliminated entirely — saved one full implementation phase |
| Manual `@:server`/`@:client` on methods | Automatic — compiler infers placement from method body analysis |

---

## 7. Phased Build Plan

### Phase 1: Foundation

- `@:build` macro that analyzes a class and performs dual compilation (client JS + server JS)
- `proxyFetch` + `secret()` detection → server-routed; client gets proxy stub
- Thin DO shell importing Haxe-compiled `server.js`
- Generated `worker.js` (stateless router) and `wrangler.toml`
- Deploy to real Cloudflare, verify credential injection and round-trip
- Performance: client JS size within budget

### Phase 2: State

- Event log: append events, sequence continuity, verify at proxyFetch boundary
- IndexedDB on client (macro-generated wrapper), SQLite in DO
- `@:shared` state types → migration SQL generation
- Validate: events survive browser refresh, DO restart

### Phase 3: Sync

- proxyFetch automatically carries event log delta
- DO returns missed server events bidirectionally
- `/do/sync` endpoint for event-only exchange (no API forwarding)
- 409 reconciliation: server wins, client discards conflicting events, retries
- Offline queue: events buffered in IndexedDB; proxyFetch calls disabled offline
- Todo reference app deployed to Cloudflare, validated in browser
- Performance: size budgets as CI warnings

### Phase 3b: Real-Time & Lease

- WebSocket channel to DO (hibernated, server→client push)
- proxyFetch-over-WebSocket with HTTP fallback
- Three-layer lease mechanism (proxyFetch renewal, WS auto-response, DO Alarm)
- Fencing tokens for stale-writer prevention
- Server takeover: process webhooks/crons while client offline

### Phase 4: Primitives

- `@:guard` — proxy-minted events for guarded state
- `@:permit` — role-based access control at DO level
- `@:auth` — OAuth + JWT (Oslo + Arctic)
- `@:webhook` — stable endpoints with signature verification
- `@:cron` — recurring scheduled work (Cron Triggers)
- `@:after` — one-shot delayed execution (DO Alarms)
- `@:shared` multi-user — org DO + barrier broadcast + WebSocket
- `@:store` — R2 blob storage with signed URLs and GC
- Automatic context splitting (browser API anchor detection, multi-proxyFetch batching)
- Reactive push: server-minted events pushed over WebSocket
- OrgShoots stress tests, reactive push validation

### Phase 4b: Observability

- Structured log emission in DO shell
- Ephemeral environments (miniflare-based local dev server)
- State seeding and event log replay
- Error context capture and replay
- CLI: `h4x0r dev`, `h4x0r logs`, `h4x0r replay`

### Phase 5: Battle Testing

- Port real apps, discover gaps
- Comparative benchmarks against Next.js, Astro, Qwik, vanilla CF Workers
- All reference apps (Todo, Blog, CRUD Dashboard, Real-time Chat)
- Compiler errors (LLM-friendly)
- MCP server for agent-driven debugging

### Phase 6: Developer Experience

- SSR and islands (falls out of context splitting analysis)
- Ejection tooling
- Documentation, getting-started guide
- Community onboarding

---

## 8. Validation: Why Haxe

The decision to move from Nim to Haxe was driven by a concrete discovery during implementation:

**The problem:** Nim's `string` type compiles to byte arrays (integer arrays) on the JS backend. This is a type system decision, not a code generation issue. No macro can change it. The result: a simple placeholder SVG generator produces 2,099 lines of JS from Nim vs 338 lines from Haxe. The bloat comes from string helper functions, byte array conversions, and stdlib modules pulled in by basic string operations.

**The macro attempt:** We built a `getImpl`-based AST rewriting macro (`jsnative.nim`, ~340 lines) that could rewrite individual function bodies to use JS-native string operations. It worked for simple functions (sanitizeBoolean, sanitizeString). It failed at the type system boundary: any object with `string` fields (like `PlaceholderOptions`) produces bloated JS because the type definition itself compiles to byte arrays. Macros rewrite function bodies, not type definitions.

**The Haxe proof:** Ported the same benchmark to Haxe. `String` IS JS's `String`. 338 lines, clean output, no tricks. Then built a unanim spike: `@:build` macro with `@:server`/`@:client`/`@:shared` metadata, `onAfterGenerate` emitting Worker + manifest. One compilation, three outputs. All Haxe macro capabilities (AST inspection, code generation, build macros, file I/O, type inspection, multi-file output, custom metadata) confirmed working.

**Key artifacts from validation:**
- `/tmp/haxe-spike/` — Benchmark spike (338-line JS output)
- `/tmp/haxe-spike/unanim-spike/` — Unanim proof-of-concept (ContextSplitter macro, TodoApp, generated Worker + manifest)

---

## 9. Fresh Repo Strategy

h4x0r is a fresh repository, not a fork of unanim. Reasons:

- Different language, different toolchain, different file structure
- The unanim repo has Nim-specific history (3 completed phases of Nim code) that doesn't apply
- VISION.md's architecture is the specification; this document is the Haxe adaptation
- The unanim repo remains as reference/archive

The fresh repo will be initialized with:
- This design document
- A Haxe-adapted VISION.md (rewritten from unanim's, with Haxe syntax and no Nim-specific sections)
- The spike code from `/tmp/haxe-spike/unanim-spike/` as a starting point
- CLAUDE.md with h4x0r-specific conventions
- GitHub Issues + Milestones following the phased build plan
