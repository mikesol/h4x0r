package h4x0r;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

using haxe.macro.ExprTools;

private typedef MethodSignals = {
    hasProxyFetch:Bool,
    hasServerOnly:Bool,
    hasBrowserAPI:Bool,
    hasClientOnly:Bool,
};

private enum Placement {
    ServerBound;
    ClientAnchored;
    Portable;
}

private typedef SharedFieldInfo = {
    name:String,
    typeName:String,
};

private typedef ServerEndpoint = {
    className:String,
    methodName:String,
    args:Array<String>,
};

/**
 * SCAFFOLD(Phase 1, #1)
 *
 * The h4x0r build macro. Applied to application classes via @:build(h4x0r.Build.process()).
 *
 * In Phase 1, this will:
 * - Analyze method bodies to determine client/server placement
 * - Rewrite server-bound methods to fetch proxies (client build)
 * - Strip DOM-referencing methods (server build)
 * - Emit infrastructure artifacts via onAfterGenerate
 *
 * Phase 1 implements: AST signal walker, client proxy stub generation,
 * server-build client-method stripping, @:shared metadata collection.
 */
class Build {
    static var serverEndpoints:Array<ServerEndpoint> = [];

    public static function configure() {
        // Called from build.hxml --macro h4x0r.Build.configure()
        #if h4x0r_server
        Context.onAfterGenerate(function() {
            patchServerExports();
            emitDOShell();
            emitWorker();
            emitWranglerToml();
            emitManifest();
        });
        #end
    }

    public static function process():Array<Field> {
        var fields = Context.getBuildFields();
        var localClass = Context.getLocalClass().get();
        var className = localClass.name;

        // Collect @:shared fields
        var sharedFields = collectSharedFields(fields);
        for (sf in sharedFields) {
            trace('[h4x0r] @:shared ${sf.name}: ${sf.typeName}');
        }

        // Add @:expose on server build so the class is accessible at runtime
        #if h4x0r_server
        var classMeta = Context.getLocalClass().get().meta;
        var hasExpose = false;
        for (m in classMeta.get()) {
            if (m.name == ":expose") hasExpose = true;
        }
        if (!hasExpose) {
            classMeta.add(":expose", [macro $v{className}], Context.currentPos());
        }
        #end

        var result:Array<Field> = [];

        for (field in fields) {
            switch (field.kind) {
                case FFun(func):
                    // Skip constructor
                    if (field.name == "new") {
                        result.push(field);
                        continue;
                    }

                    var signals = analyzeMethod(func.expr);
                    var placement = classify(signals, field.pos);
                    trace('[h4x0r] $className.${field.name} -> $placement');

                    #if h4x0r_server
                    // Collect endpoint for DO shell generation
                    if (placement == ServerBound) {
                        var argNames = switch (field.kind) {
                            case FFun(f): [for (a in f.args) a.name];
                            default: [];
                        };
                        serverEndpoints.push({
                            className: className,
                            methodName: field.name,
                            args: argNames,
                        });
                        // Prevent DCE from removing server-bound methods
                        if (field.meta == null) field.meta = [];
                        field.meta.push({name: ":keep", params: null, pos: field.pos});
                    }
                    var rewritten = rewriteForServer(field, placement, className);
                    #else
                    var rewritten = rewriteForClient(field, placement, className);
                    #end

                    if (rewritten != null) {
                        result.push(rewritten);
                    }

                default:
                    // Non-method fields pass through unchanged
                    result.push(field);
            }
        }

        return result;
    }

    static function analyzeMethod(expr:Null<Expr>):MethodSignals {
        var signals:MethodSignals = {
            hasProxyFetch: false,
            hasServerOnly: false,
            hasBrowserAPI: false,
            hasClientOnly: false,
        };
        if (expr != null) {
            walkExpr(expr, signals);
        }
        return signals;
    }

    static function walkExpr(expr:Expr, signals:MethodSignals):Void {
        switch (expr.expr) {
            case ECall(target, args):
                var name = extractCallName(target);
                if (name == "proxyFetch") signals.hasProxyFetch = true;
                if (name == "serverOnly") signals.hasServerOnly = true;
                if (name == "clientOnly") signals.hasClientOnly = true;
                if (isBrowserAPI(target)) signals.hasBrowserAPI = true;
                // Walk the call target and all arguments
                walkExpr(target, signals);
                for (arg in args) {
                    walkExpr(arg, signals);
                }

            case EField(sub, _):
                if (isBrowserAPI(expr)) signals.hasBrowserAPI = true;
                walkExpr(sub, signals);

            default:
                expr.iter(function(e) {
                    walkExpr(e, signals);
                });
        }
    }

    static function extractCallName(expr:Expr):String {
        switch (expr.expr) {
            case EConst(CIdent(name)):
                return name;
            case EField(_, name):
                return name;
            default:
                return "";
        }
    }

    static function isBrowserAPI(expr:Expr):Bool {
        var chain = extractFieldChain(expr);
        if (chain.length >= 2) {
            if (chain[0] == "js" && (chain[1] == "Browser" || chain[1] == "html")) {
                return true;
            }
        }
        return false;
    }

    static function extractFieldChain(expr:Expr):Array<String> {
        switch (expr.expr) {
            case EField(sub, name):
                var parent = extractFieldChain(sub);
                parent.push(name);
                return parent;
            case EConst(CIdent(name)):
                return [name];
            default:
                return [];
        }
    }

    static function classify(signals:MethodSignals, pos:Position):Placement {
        var isServer = signals.hasProxyFetch || signals.hasServerOnly;
        var isClient = signals.hasBrowserAPI || signals.hasClientOnly;
        if (isServer && isClient) {
            // Context splitting (Phase 4) will handle this properly.
            // For now, server wins — the entire method becomes a proxy stub on client.
            Context.warning("[h4x0r] method has both server and client signals; context splitting deferred to Phase 4", pos);
        }
        if (isServer) return ServerBound;
        if (isClient) return ClientAnchored;
        return Portable;
    }

    static function collectSharedFields(fields:Array<Field>):Array<SharedFieldInfo> {
        var result:Array<SharedFieldInfo> = [];
        for (field in fields) {
            if (field.meta == null) continue;
            for (m in field.meta) {
                if (m.name == ":shared" || m.name == "shared") {
                    var typeName = "Dynamic";
                    switch (field.kind) {
                        case FVar(t, _):
                            if (t != null) {
                                typeName = haxe.macro.ComplexTypeTools.toString(t);
                            }
                        default:
                    }
                    result.push({name: field.name, typeName: typeName});
                }
            }
        }
        return result;
    }

    /**
     * For the server build, strips ClientAnchored methods entirely.
     * ServerBound and Portable methods are kept as-is with their original bodies.
     */
    static function rewriteForServer(field:Field, placement:Placement, className:String):Null<Field> {
        if (placement == ClientAnchored) {
            // Strip client-anchored methods entirely on server build
            trace('[h4x0r] stripping client-anchored: $className.${field.name}');
            return null;
        }
        // ServerBound and Portable methods kept as-is
        return field;
    }

    static function patchServerExports():Void {
        var path = "gen/server.js";
        try {
            var content = sys.io.File.getContent(path);
            // The Haxe output ends with:
            // })(typeof exports != "undefined" ? exports : typeof window != "undefined" ? window : typeof self != "undefined" ? self : this, {});
            // Replace the $hx_exports resolution with globalThis
            var oldExports = "typeof exports != \"undefined\" ? exports : typeof window != \"undefined\" ? window : typeof self != \"undefined\" ? self : this";
            if (content.indexOf(oldExports) == -1) {
                trace("[h4x0r] WARNING: expected $hx_exports pattern not found in gen/server.js — skipping patch");
                return;
            }
            content = StringTools.replace(content, oldExports, "globalThis");
            sys.io.File.saveContent(path, content);
            trace("[h4x0r] patched gen/server.js: $hx_exports → globalThis");
        } catch (e:Dynamic) {
            trace("[h4x0r] WARNING: could not patch gen/server.js: " + Std.string(e));
        }
    }

    static function emitDOShell():Void {
        if (serverEndpoints.length == 0) {
            trace("[h4x0r] no server endpoints, skipping do.js");
            return;
        }

        var buf = new StringBuf();
        var appClass = serverEndpoints[0].className;
        var doClass = appClass + "DO";

        buf.add("// gen/do.js — generated by h4x0r. Do not edit.\n");
        buf.add("import './server.js';\n\n");
        buf.add("export class " + doClass + " {\n");
        buf.add("  constructor(state, env) {\n");
        buf.add("    this.state = state;\n");
        buf.add("    this.storage = state.storage;\n");
        buf.add("    this.env = env;\n");
        buf.add("    this.app = new globalThis." + appClass + "();\n");
        buf.add("  }\n\n");

        buf.add("  async fetch(request) {\n");
        buf.add("    if (request.method !== 'POST') {\n");
        buf.add("      return new Response('Method not allowed', { status: 405 });\n");
        buf.add("    }\n");
        buf.add("    const url = new URL(request.url);\n");
        buf.add("    if (url.pathname !== '/rpc') {\n");
        buf.add("      return new Response('Not found', { status: 404 });\n");
        buf.add("    }\n");
        buf.add("    const { method, args } = await request.json();\n");
        buf.add("    switch (method) {\n");

        for (ep in serverEndpoints) {
            var qualName = ep.className + "." + ep.methodName;
            var callArgs = [for (a in ep.args) "args[\"" + a + "\"]"].join(", ");
            buf.add("      case '" + qualName + "':\n");
            buf.add("        return json(await this.app." + ep.methodName + "(" + callArgs + "));\n");
        }

        buf.add("      default:\n");
        buf.add("        return new Response(JSON.stringify({error: 'Unknown method: ' + method}), {\n");
        buf.add("          status: 404, headers: {'Content-Type': 'application/json'}\n");
        buf.add("        });\n");
        buf.add("    }\n");
        buf.add("  }\n");
        buf.add("}\n\n");

        buf.add("function json(data) {\n");
        buf.add("  return new Response(JSON.stringify(data), {\n");
        buf.add("    headers: {'Content-Type': 'application/json'}\n");
        buf.add("  });\n");
        buf.add("}\n");

        sys.io.File.saveContent("gen/do.js", buf.toString());
        trace("[h4x0r] wrote gen/do.js with " + Std.string(serverEndpoints.length) + " endpoints");
    }

    static function toUpperSnake(camelCase:String):String {
        var buf = new StringBuf();
        for (i in 0...camelCase.length) {
            var c = camelCase.charAt(i);
            if (c >= "A" && c <= "Z" && i > 0) {
                buf.add("_");
            }
            buf.add(c.toUpperCase());
        }
        return buf.toString();
    }

    static function toKebab(camelCase:String):String {
        var buf = new StringBuf();
        for (i in 0...camelCase.length) {
            var c = camelCase.charAt(i);
            if (c >= "A" && c <= "Z" && i > 0) {
                buf.add("-");
            }
            buf.add(c.toLowerCase());
        }
        return buf.toString();
    }

    static function emitWorker():Void {
        if (serverEndpoints.length == 0) return;

        var appClass = serverEndpoints[0].className;
        var doClass = appClass + "DO";
        var binding = toUpperSnake(appClass);

        var buf = new StringBuf();
        buf.add("// gen/worker.js — generated by h4x0r. Do not edit.\n");
        buf.add("import { " + doClass + " } from './do.js';\n\n");
        buf.add("export default {\n");
        buf.add("  async fetch(request, env) {\n");
        buf.add("    const id = env." + binding + ".idFromName(\"default\");\n");
        buf.add("    const stub = env." + binding + ".get(id);\n");
        buf.add("    return stub.fetch(request);\n");
        buf.add("  }\n");
        buf.add("};\n\n");
        buf.add("export { " + doClass + " };\n");

        sys.io.File.saveContent("gen/worker.js", buf.toString());
        trace("[h4x0r] wrote gen/worker.js");
    }

    static function emitWranglerToml():Void {
        if (serverEndpoints.length == 0) return;

        var appClass = serverEndpoints[0].className;
        var doClass = appClass + "DO";
        var binding = toUpperSnake(appClass);
        var workerName = toKebab(appClass);

        var buf = new StringBuf();
        buf.add("# gen/wrangler.toml — generated by h4x0r. Do not edit.\n");
        buf.add("name = \"" + workerName + "\"\n");
        buf.add("main = \"worker.js\"\n");
        buf.add("compatibility_date = \"2024-12-01\"\n\n");
        buf.add("[durable_objects]\n");
        buf.add("bindings = [\n");
        buf.add("  { name = \"" + binding + "\", class_name = \"" + doClass + "\" }\n");
        buf.add("]\n\n");
        buf.add("[[migrations]]\n");
        buf.add("tag = \"v1\"\n");
        buf.add("new_classes = [\"" + doClass + "\"]\n");

        sys.io.File.saveContent("gen/wrangler.toml", buf.toString());
        trace("[h4x0r] wrote gen/wrangler.toml");
    }

    static function emitManifest():Void {
        if (serverEndpoints.length == 0) return;

        var appClass = serverEndpoints[0].className;

        var buf = new StringBuf();
        buf.add("# " + appClass + " API\n\n");
        buf.add("Generated by h4x0r. Do not edit.\n\n");
        buf.add("## Endpoints\n\n");
        buf.add("All endpoints use `POST /rpc` with JSON body `{method, args}`.\n\n");

        for (ep in serverEndpoints) {
            var qualName = ep.className + "." + ep.methodName;
            buf.add("### `" + qualName + "`\n");
            buf.add("- **Args:** " + [for (a in ep.args) "`" + a + "`"].join(", ") + "\n\n");
        }

        sys.io.File.saveContent("gen/manifest.md", buf.toString());
        trace("[h4x0r] wrote gen/manifest.md");
    }

    /**
     * For ServerBound methods, replaces the method body with a fetch proxy stub
     * that POSTs to /rpc. ClientAnchored and Portable methods pass through unchanged.
     */
    static function rewriteForClient(field:Field, placement:Placement, className:String):Null<Field> {
        // Only rewrite ServerBound methods
        switch (placement) {
            case ServerBound:
            // proceed below
            default:
                return field;
        }

        var func = switch (field.kind) {
            case FFun(f): f;
            default: return field;
        };

        // Build the fully qualified RPC method name: "ClassName.methodName"
        var methodName = className + "." + field.name;

        // Build the args object fields for the JSON payload
        var argFields:Array<ObjectField> = [];
        for (arg in func.args) {
            argFields.push({field: arg.name, expr: macro $i{arg.name}});
        }
        var argsExpr:Expr = {expr: EObjectDecl(argFields), pos: field.pos};

        // Build the proxy body using js.Syntax.code for reliable JS output
        var proxyBody:Expr = macro {
            return js.Syntax.code("fetch('/rpc', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({method: {0}, args: {1}})}).then(function(r) { return r.json(); })",
                $v{methodName}, $argsExpr);
        };

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
}
#end
