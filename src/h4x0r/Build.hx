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
 * Tasks 4 and 5 will implement rewriteForClient and rewriteForServer respectively.
 */
class Build {
    public static function configure() {
        // Called from build.hxml --macro h4x0r.Build.configure()
        // Will register onAfterGenerate and global compilation hooks
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
                    var placement = classify(signals);
                    trace('[h4x0r] $className.${field.name} -> $placement');

                    #if h4x0r_server
                    var rewritten = rewriteForServer(field, placement);
                    #else
                    var rewritten = rewriteForClient(field, placement);
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

    static function classify(signals:MethodSignals):Placement {
        if (signals.hasProxyFetch || signals.hasServerOnly) return ServerBound;
        if (signals.hasBrowserAPI || signals.hasClientOnly) return ClientAnchored;
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
     * SCAFFOLD(Phase 1, #1)
     * Stub: returns field unchanged. Task 5 will implement server-build rewriting.
     */
    static function rewriteForServer(field:Field, placement:Placement):Null<Field> {
        return field;
    }

    /**
     * SCAFFOLD(Phase 1, #1)
     * Stub: returns field unchanged. Task 4 will implement client-build proxy stub generation.
     */
    static function rewriteForClient(field:Field, placement:Placement):Null<Field> {
        return field;
    }
}
#end
