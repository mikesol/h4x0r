package macros;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

using haxe.macro.ExprTools;
using haxe.macro.TypeTools;

// Collected server endpoints to generate Worker handler
private typedef ServerEndpoint = {
    className:String,
    methodName:String,
    args:Array<{name:String, type:String}>,
    returnType:String,
};

class ContextSplitter {
    static var serverEndpoints:Array<ServerEndpoint> = [];
    static var registeredGenerate = false;

    public static function build():Array<Field> {
        var fields = Context.getBuildFields();
        var localClass = Context.getLocalClass().get();
        var className = localClass.name;

        trace('=== ContextSplitter processing: $className ===');

        var serverMethods:Array<String> = [];
        var clientMethods:Array<String> = [];
        var sharedVars:Array<String> = [];

        // Classify fields by metadata
        for (field in fields) {
            var meta = field.meta;
            if (meta != null) {
                for (m in meta) {
                    switch (m.name) {
                        case ":server":
                            serverMethods.push(field.name);
                            trace('  [server] ${field.name}');
                        case ":client":
                            clientMethods.push(field.name);
                            trace('  [client] ${field.name}');
                        case ":shared":
                            sharedVars.push(field.name);
                            trace('  [shared] ${field.name}');
                        default:
                    }
                }
            }
        }

        // Collect server endpoint signatures for Worker generation
        for (field in fields) {
            if (field.meta == null) continue;
            var isServer = false;
            for (m in field.meta) {
                if (m.name == ":server") isServer = true;
            }
            if (!isServer) continue;

            switch (field.kind) {
                case FFun(func):
                    var args:Array<{name:String, type:String}> = [];
                    for (arg in func.args) {
                        var typeName = arg.type != null ? haxe.macro.ComplexTypeTools.toString(arg.type) : "Dynamic";
                        args.push({name: arg.name, type: typeName});
                    }
                    var retType = func.ret != null ? haxe.macro.ComplexTypeTools.toString(func.ret) : "Void";
                    serverEndpoints.push({
                        className: className,
                        methodName: field.name,
                        args: args,
                        returnType: retType,
                    });
                default:
            }
        }

        // For @:server methods on the client side, replace body with a fetch proxy
        var newFields:Array<Field> = [];
        for (field in fields) {
            var isServer = false;
            if (field.meta != null) {
                for (m in field.meta) {
                    if (m.name == ":server") isServer = true;
                }
            }

            if (isServer) {
                switch (field.kind) {
                    case FFun(func):
                        // Build JSON body from args
                        var argNames:Array<Expr> = [];
                        for (arg in func.args) {
                            var name = arg.name;
                            argNames.push(macro $v{name});
                        }

                        var endpoint = '/$className/${field.name}';
                        var endpointExpr = macro $v{endpoint};
                        // Replace body with fetch proxy
                        var proxyBody = macro {
                            // In real h4x0r this would be a fetch() call
                            // For the spike, just trace what would happen
                            trace("[PROXY] POST " + $endpointExpr + " with args");
                            return null;
                        };
                        var newFunc = {
                            args: func.args,
                            ret: func.ret,
                            expr: proxyBody,
                            params: func.params,
                        };
                        newFields.push({
                            name: field.name,
                            doc: field.doc,
                            access: field.access,
                            kind: FFun(newFunc),
                            pos: field.pos,
                            meta: field.meta,
                        });
                    default:
                        newFields.push(field);
                }
            } else {
                newFields.push(field);
            }
        }

        // Register the onAfterGenerate callback (once) to write Worker file
        if (!registeredGenerate) {
            registeredGenerate = true;
            Context.onAfterGenerate(function() {
                generateWorkerFile();
            });
        }

        return newFields;
    }

    static function generateWorkerFile() {
        trace('=== Generating Worker file with ${serverEndpoints.length} endpoints ===');

        var buf = new StringBuf();
        buf.add("// AUTO-GENERATED by h4x0r ContextSplitter\n");
        buf.add("// Do not edit — regenerated on each build\n\n");
        buf.add("export default {\n");
        buf.add("  async fetch(request, env) {\n");
        buf.add("    const url = new URL(request.url);\n");
        buf.add("    const path = url.pathname;\n\n");

        for (ep in serverEndpoints) {
            var route = '/${ep.className}/${ep.methodName}';
            buf.add('    if (path === "$route" && request.method === "POST") {\n');
            buf.add('      const body = await request.json();\n');

            // Generate argument extraction
            var argList = [];
            for (arg in ep.args) {
                argList.push('body.${arg.name}');
            }
            var call = argList.join(", ");

            buf.add('      // TODO: import and call ${ep.className}.${ep.methodName}($call)\n');
            buf.add('      const result = { todo: "implement ${ep.methodName}" };\n');
            buf.add('      return new Response(JSON.stringify(result), {\n');
            buf.add('        headers: { "Content-Type": "application/json" }\n');
            buf.add('      });\n');
            buf.add('    }\n\n');
        }

        buf.add("    return new Response('Not Found', { status: 404 });\n");
        buf.add("  }\n");
        buf.add("};\n");

        var workerCode = buf.toString();
        sys.io.File.saveContent("gen/worker.js", workerCode);
        trace("=== Wrote gen/worker.js ===");

        // Also generate a manifest
        var manifest = new StringBuf();
        manifest.add("# h4x0r Build Manifest\n\n");
        manifest.add("## Server Endpoints\n\n");
        for (ep in serverEndpoints) {
            manifest.add('- POST /${ep.className}/${ep.methodName}');
            manifest.add("(");
            var parts = [];
            for (arg in ep.args) {
                parts.push('${arg.name}: ${arg.type}');
            }
            manifest.add(parts.join(", "));
            manifest.add(') -> ${ep.returnType}\n');
        }
        sys.io.File.saveContent("gen/manifest.md", manifest.toString());
        trace("=== Wrote gen/manifest.md ===");
    }
}
#end
