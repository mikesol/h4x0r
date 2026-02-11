# Issue #1: @:build macro — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the `@:build` macro that analyzes method bodies for placement signals and rewrites them for client/server builds.

**Architecture:** A recursive AST walker detects `proxyFetch`, `js.Browser.*`/`js.html.*`, `serverOnly`/`clientOnly` calls. On client build, server-bound methods become fetch proxy stubs calling `POST /rpc`. On server build, browser-anchored methods are stripped. Designed for extensibility — later phases add `@:shared` mutation and `@:guard` signals.

**Tech Stack:** Haxe 4.3.6 macros (`haxe.macro.Context`, `haxe.macro.Expr`), JS target.

**Working directory:** `/home/mikesol/Documents/GitHub/h4x0r/h4x0r-1` (worktree on branch `issue-1`)

---

### Task 1: Create test app and API stubs

Set up the test app that exercises all Phase 1 signal types, plus the stub functions that make `proxyFetch`/`secret`/`serverOnly`/`clientOnly` resolvable on the server build.

**Files:**
- Create: `src/h4x0r/Api.hx`
- Create: `test/TestApp.hx`
- Create: `test/Main.hx`

**Step 1: Create `src/h4x0r/Api.hx`**

```haxe
package h4x0r;

/**
 * SCAFFOLD(Phase 1, #1)
 *
 * Runtime stubs for h4x0r primitives. In Phase 1, these are no-op placeholders.
 * The @:build macro injects these as instance methods on server builds so user
 * code can call proxyFetch(...) etc. as bare names.
 *
 * Later phases replace these with real implementations:
 * - proxyFetch: HTTP forwarding with event log piggybacking
 * - secret: environment variable resolution
 * - serverOnly/clientOnly: stripped at compile time (the block content runs directly)
 */
class Api {
    public static function proxyFetch(url:String, headers:Dynamic, body:Dynamic):Dynamic {
        return null;
    }

    public static function secret(name:String):String {
        return "";
    }

    public static function serverOnly(f:() -> Void):Void {
        f();
    }

    public static function clientOnly(f:() -> Void):Void {
        f();
    }
}
```

**Step 2: Create `test/TestApp.hx`**

```haxe
package;

import h4x0r.Api;

/**
 * Test application exercising all Phase 1 signal types.
 * The @:build macro should classify each method from its body, not annotations.
 */
@:build(h4x0r.Build.process())
class TestApp {
    @:shared var items:Array<String> = [];

    public function new() {}

    /** Server-bound: contains proxyFetch + secret */
    public function fetchData(query:String):Dynamic {
        return Api.proxyFetch("https://api.example.com/data",
            {authorization: "Bearer " + Api.secret("api-key")},
            {query: query});
    }

    /** Server-bound: contains proxyFetch (no secret) */
    public function sendReport(data:Dynamic):Dynamic {
        return Api.proxyFetch("https://api.example.com/report", {}, data);
    }

    /** Client-anchored: DOM references */
    public function render():Void {
        var el = js.Browser.document.getElementById("app");
        el.textContent = "hello";
    }

    /** Portable: no signals at all */
    public function format(s:String):String {
        return s.toUpperCase();
    }

    /** Server-bound: forced via serverOnly */
    public function audit(action:String):Void {
        Api.serverOnly(function() {
            trace("audit: " + action);
        });
    }
}
```

**Step 3: Create `test/Main.hx`**

```haxe
package;

class Main {
    static function main() {
        var app = new TestApp();
        trace("TestApp instantiated");

        // Call portable method (works on both builds)
        trace(app.format("hello"));

        #if !h4x0r_server
        // Client-only: render
        app.render();
        // Proxy stubs (would fetch /rpc in real browser)
        trace(app.fetchData("test"));
        trace(app.sendReport({x: 1}));
        #end
    }
}
```

**Step 4: Commit**

```bash
git add src/h4x0r/Api.hx test/TestApp.hx test/Main.hx
git commit -m "feat(#1): add test app and API stubs for macro development"
```

---

### Task 2: Update build.hxml for dual compilation

Configure `build.hxml` to produce both client and server JS from the test app. Keep the spike class path for reference.

**Files:**
- Modify: `build.hxml`

**Step 1: Rewrite `build.hxml`**

```hxml
-cp src
-cp test
--macro h4x0r.Build.configure()

# Client target
-main Main
-js gen/client.js
-dce full

--next

# Server target
-cp src
-cp test
--macro h4x0r.Build.configure()
-main Main
-js gen/server.js
-D h4x0r_server
-dce full
```

Note: the spike is no longer on the class path. It remains in `spike/` as reference.

**Step 2: Verify both targets compile**

Run: `haxe build.hxml`

Expected: Both targets compile. The macro is still a passthrough, so:
- `gen/client.js` contains all methods as-is (including `proxyFetch` calls which won't resolve → may get compile errors)

Wait — with the passthrough macro, the server build will work (Api.proxyFetch is importable), but the client build has methods calling `Api.proxyFetch` which references server-side code. Actually, both builds have `Api.hx` available, so both should compile since `Api.proxyFetch` is just a static method returning `Dynamic`. The passthrough macro doesn't strip anything yet.

Expected: Both targets compile successfully. `gen/client.js` and `gen/server.js` both contain all methods.

**Step 3: Commit**

```bash
git add build.hxml
git commit -m "feat(#1): dual compilation targets in build.hxml"
```

---

### Task 3: Implement AST signal walker

Build the recursive expression walker that detects placement signals and classifies each method.

**Files:**
- Modify: `src/h4x0r/Build.hx`

**Step 1: Define signal types and walker**

Replace `Build.hx` with:

```haxe
package h4x0r;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

using haxe.macro.ExprTools;

/**
 * The h4x0r build macro. Applied via @:build(h4x0r.Build.process()).
 *
 * Phase 1 signals:
 * - proxyFetch(...) → server-bound
 * - serverOnly(...) → server-bound (forced)
 * - js.Browser.* / js.html.* → client-anchored
 * - clientOnly(...) → client-anchored (forced)
 * - No signals → portable (kept on both builds)
 */

/** Signals detected in a method body. Extensible for later phases. */
private typedef MethodSignals = {
    hasProxyFetch:Bool,
    hasServerOnly:Bool,
    hasBrowserAPI:Bool,
    hasClientOnly:Bool,
};

/** Classification derived from signals. */
private enum Placement {
    ServerBound;
    ClientAnchored;
    Portable;
}

/** Metadata collected from @:shared fields. */
private typedef SharedFieldInfo = {
    name:String,
    typeName:String,
};

class Build {
    /** Collected @:shared metadata for later phases (issues #3-4). */
    static var sharedFields:Array<SharedFieldInfo> = [];

    public static function configure() {
        // Called from build.hxml --macro h4x0r.Build.configure()
        // Will register onAfterGenerate in later issues
    }

    public static function process():Array<Field> {
        var fields = Context.getBuildFields();
        var localClass = Context.getLocalClass().get();
        var className = localClass.name;

        // Collect @:shared metadata
        collectSharedFields(fields);

        // Classify and rewrite each method
        var result:Array<Field> = [];
        for (field in fields) {
            switch (field.kind) {
                case FFun(func):
                    var signals = analyzeMethod(func.expr);
                    var placement = classify(signals);
                    trace('[h4x0r] ${className}.${field.name} → $placement');

                    #if h4x0r_server
                    result.push(rewriteForServer(field, func, placement, className));
                    #else
                    result.push(rewriteForClient(field, func, placement, className));
                    #end

                default:
                    result.push(field);
            }
        }

        return result;
    }

    /** Recursively walk an expression tree, accumulating signals. */
    static function analyzeMethod(expr:Null<Expr>):MethodSignals {
        var signals:MethodSignals = {
            hasProxyFetch: false,
            hasServerOnly: false,
            hasBrowserAPI: false,
            hasClientOnly: false,
        };
        if (expr != null) walkExpr(expr, signals);
        return signals;
    }

    static function walkExpr(expr:Expr, signals:MethodSignals):Void {
        switch (expr.expr) {
            case ECall(callExpr, args):
                // Check call target for signal identifiers
                var name = extractCallName(callExpr);
                switch (name) {
                    case "proxyFetch": signals.hasProxyFetch = true;
                    case "serverOnly": signals.hasServerOnly = true;
                    case "clientOnly": signals.hasClientOnly = true;
                    default:
                }
                // Also check for browser API in the call target
                if (isBrowserAPI(callExpr)) signals.hasBrowserAPI = true;
                // Walk arguments
                for (a in args) walkExpr(a, signals);
                // Walk call target (may contain nested signals)
                walkExpr(callExpr, signals);

            case EField(sub, field):
                if (isBrowserAPI(expr)) signals.hasBrowserAPI = true;
                walkExpr(sub, signals);

            default:
                // Walk all sub-expressions
                expr.iter(function(e) walkExpr(e, signals));
        }
    }

    /** Extract the function name from a call expression target. */
    static function extractCallName(expr:Expr):String {
        return switch (expr.expr) {
            // bare: proxyFetch(...)
            case EConst(CIdent(name)): name;
            // qualified: Api.proxyFetch(...) or h4x0r.Api.proxyFetch(...)
            case EField(_, name): name;
            default: "";
        };
    }

    /** Check if an expression is a reference to js.Browser.* or js.html.* */
    static function isBrowserAPI(expr:Expr):Bool {
        var chain = extractFieldChain(expr);
        if (chain.length >= 2) {
            if (chain[0] == "js" && (chain[1] == "Browser" || chain[1] == "html")) {
                return true;
            }
        }
        return false;
    }

    /** Extract a dotted field chain from an expression. e.g., js.Browser.document → ["js", "Browser", "document"] */
    static function extractFieldChain(expr:Expr):Array<String> {
        return switch (expr.expr) {
            case EField(sub, field):
                extractFieldChain(sub).concat([field]);
            case EConst(CIdent(name)):
                [name];
            default:
                [];
        };
    }

    /** Classify a method from its signals. */
    static function classify(signals:MethodSignals):Placement {
        if (signals.hasProxyFetch || signals.hasServerOnly) return ServerBound;
        if (signals.hasBrowserAPI || signals.hasClientOnly) return ClientAnchored;
        return Portable;
    }

    /** Collect @:shared var field metadata. */
    static function collectSharedFields(fields:Array<Field>):Void {
        for (field in fields) {
            if (field.meta == null) continue;
            for (m in field.meta) {
                if (m.name == ":shared" || m.name == "shared") {
                    var typeName = switch (field.kind) {
                        case FVar(t, _): t != null ? haxe.macro.ComplexTypeTools.toString(t) : "Dynamic";
                        default: "Dynamic";
                    };
                    sharedFields.push({name: field.name, typeName: typeName});
                    trace('[h4x0r] @:shared ${field.name}: $typeName');
                }
            }
        }
    }

    // --- STUBS: implemented in Tasks 4 and 5 ---

    static function rewriteForClient(field:Field, func:Function, placement:Placement, className:String):Null<Field> {
        // Task 4: replace server-bound bodies with proxy stubs
        return field; // passthrough for now
    }

    static function rewriteForServer(field:Field, func:Function, placement:Placement, className:String):Null<Field> {
        // Task 5: strip client-anchored methods
        return field; // passthrough for now
    }
}
#end
```

**Step 2: Compile and verify classification trace output**

Run: `haxe build.hxml 2>&1`

Expected trace output (order may vary):

```
[h4x0r] @:shared items: Array<String>
[h4x0r] TestApp.fetchData → ServerBound
[h4x0r] TestApp.sendReport → ServerBound
[h4x0r] TestApp.render → ClientAnchored
[h4x0r] TestApp.format → Portable
[h4x0r] TestApp.audit → ServerBound
```

Both targets should still compile since rewriting is a passthrough.

**Step 3: Commit**

```bash
git add src/h4x0r/Build.hx
git commit -m "feat(#1): AST signal walker with method classification"
```

---

### Task 4: Implement client-build proxy stub generation

Replace server-bound method bodies with fetch proxy stubs on the client build.

**Files:**
- Modify: `src/h4x0r/Build.hx` (the `rewriteForClient` function)

**Step 1: Implement `rewriteForClient`**

```haxe
static function rewriteForClient(field:Field, func:Function, placement:Placement, className:String):Null<Field> {
    if (placement != ServerBound) return field;

    // Build the proxy stub body
    var methodName = className + "." + field.name;

    // Build args object: {arg1: arg1, arg2: arg2, ...}
    var argFields:Array<ObjectField> = [];
    for (arg in func.args) {
        argFields.push({field: arg.name, expr: macro $i{arg.name}});
    }
    var argsExpr:Expr = {expr: EObjectDecl(argFields), pos: field.pos};

    // Build: {method: "ClassName.methodName", args: {arg1: arg1, ...}}
    var payloadFields:Array<ObjectField> = [
        {field: "method", expr: macro $v{methodName}},
        {field: "args", expr: argsExpr},
    ];
    var payloadExpr:Expr = {expr: EObjectDecl(payloadFields), pos: field.pos};

    // Build fetch options: {method: "POST", headers: {...}, body: JSON.stringify(payload)}
    var fetchOptsFields:Array<ObjectField> = [
        {field: "method", expr: macro "POST"},
        {field: "headers", expr: {expr: EObjectDecl([{field: "Content-Type", expr: macro "application/json"}]), pos: field.pos}},
        {field: "body", expr: macro (untyped js.Syntax.code("JSON.stringify"))(cast $payloadExpr)},
    ];
    var fetchOpts:Expr = {expr: EObjectDecl(fetchOptsFields), pos: field.pos};

    var proxyBody:Expr = macro {
        return (untyped js.Syntax.code("fetch"))("/rpc", cast $fetchOpts)
            .then(function(r:Dynamic):Dynamic {
                return r.json();
            });
    };

    // Replace the function body
    return {
        name: field.name,
        doc: field.doc,
        access: field.access,
        kind: FFun({
            args: func.args,
            ret: macro :Dynamic,
            expr: proxyBody,
            params: func.params,
        }),
        pos: field.pos,
        meta: field.meta,
    };
}
```

Note: The exact expression construction for the fetch call may need iteration. The key patterns:
- `js.Syntax.code("fetch")` embeds the raw JS `fetch` function reference
- `js.Syntax.code("JSON.stringify")` embeds the raw JS `JSON.stringify` reference
- `cast` bypasses type checking on the dynamic objects
- The `.then()` call chains the JSON parsing

If `js.Syntax.code` doesn't work cleanly for function references, fall back to a single `js.Syntax.code` call with the entire fetch expression as a template string with `{0}`, `{1}` etc. parameter substitution.

**Step 2: Compile client target and inspect output**

Run: `haxe build.hxml 2>&1`

Then inspect `gen/client.js`. Look for the proxy stub:
- `fetchData` should contain `fetch("/rpc", ...)` with `JSON.stringify({method: "TestApp.fetchData", args: {query: query}})`
- `sendReport` should contain a similar proxy stub
- `audit` should contain a proxy stub (server-bound via `serverOnly`)
- `render` should be kept as-is (DOM references)
- `format` should be kept as-is (portable)

**Step 3: Commit**

```bash
git add src/h4x0r/Build.hx
git commit -m "feat(#1): client-build proxy stub generation"
```

---

### Task 5: Implement server-build rewriting

Strip client-anchored methods and keep everything else on the server build.

**Files:**
- Modify: `src/h4x0r/Build.hx` (the `rewriteForServer` function)

**Step 1: Implement `rewriteForServer`**

```haxe
static function rewriteForServer(field:Field, func:Function, placement:Placement, className:String):Null<Field> {
    if (placement == ClientAnchored) {
        // Strip client-anchored methods entirely on server build
        trace('[h4x0r] stripping client-anchored: ${className}.${field.name}');
        return null;
    }
    // ServerBound and Portable methods kept as-is
    return field;
}
```

Then update `process()` to handle null returns (stripped fields):

```haxe
// In the classification loop, change:
#if h4x0r_server
var rewritten = rewriteForServer(field, func, placement, className);
if (rewritten != null) result.push(rewritten);
#else
var rewritten = rewriteForClient(field, func, placement, className);
if (rewritten != null) result.push(rewritten);
#end
```

**Step 2: Compile server target and inspect output**

Run: `haxe build.hxml 2>&1`

Inspect `gen/server.js`:
- `fetchData` should contain the original body with `Api.proxyFetch(...)` call
- `sendReport` should contain the original body
- `render` should NOT be present (stripped — client-anchored)
- `format` should be present (portable)
- `audit` should contain the original body with `Api.serverOnly(...)` call

**Step 3: Compile and run both targets to verify no JS errors**

Client: `node gen/client.js 2>&1` — should run without crash (fetch won't work outside browser, but no syntax/reference errors)
Server: `node gen/server.js 2>&1` — should run without crash

Note: The client build may fail with "fetch is not defined" in Node (that's expected — it's browser code). The key check is no syntax errors. If needed, just verify with `node --check gen/client.js`.

**Step 4: Commit**

```bash
git add src/h4x0r/Build.hx
git commit -m "feat(#1): server-build client-method stripping"
```

---

### Task 6: End-to-end verification and cleanup

Verify all acceptance criteria, clean up trace output, ensure both builds are valid.

**Files:**
- Modify: `src/h4x0r/Build.hx` (optional: reduce trace verbosity)

**Step 1: Verify all acceptance criteria**

Run: `haxe build.hxml 2>&1`

Check each criterion:

1. **Test app compiles with the macro** — both targets should compile without errors
2. **Client build: server-bound methods replaced with fetch proxy stubs** — inspect `gen/client.js`
3. **Server build: browser methods stripped, server methods kept** — inspect `gen/server.js`
4. **Both builds produce valid JS** — `node --check gen/client.js && node --check gen/server.js`
5. **No @:server or @:client annotations** — grep TestApp.hx for these; should find none

**Step 2: Verify JS syntax validity**

Run: `node --check gen/client.js && node --check gen/server.js && echo "Both valid"`

Expected: "Both valid"

**Step 3: Commit final state**

```bash
git add -A
git commit -m "feat(#1): @:build macro with AST analysis and proxy stub generation

Implements method body analysis for placement inference:
- proxyFetch/serverOnly → server-bound (client gets fetch proxy stub)
- js.Browser/js.html/clientOnly → client-anchored (server strips)
- No signals → portable (kept on both builds)

RPC endpoint: POST /rpc with {method, args} JSON payload.
@:shared metadata collected for later phases.

Closes #1"
```

---

## Execution Notes

- **The proxy stub expression construction (Task 4) is the trickiest part.** Haxe macro expression building for dynamic JS patterns (`fetch`, `JSON.stringify`) requires care with `js.Syntax.code`, `untyped`, and `cast`. If the first approach doesn't compile cleanly, iterate — try a single `js.Syntax.code` template string with numbered parameter substitution.

- **The return type of proxy-stubbed methods becomes `Dynamic`.** The original return type is irrelevant on the client — the fetch returns a Promise<Dynamic>. This is a Phase 1 simplification; later phases will add typed response wrappers.

- **The test app uses `Api.proxyFetch(...)` (qualified).** For the VISION.md UX where users write bare `proxyFetch(...)`, a later enhancement can have the macro inject using-imports or rewrite bare calls. Not in Phase 1 scope.
