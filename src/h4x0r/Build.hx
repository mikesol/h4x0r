package h4x0r;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * SCAFFOLD(Phase 1)
 *
 * The h4x0r build macro. Applied to application classes via @:build(h4x0r.Build.process()).
 *
 * In Phase 1, this will:
 * - Analyze method bodies to determine client/server placement
 * - Rewrite server-bound methods to fetch proxies (client build)
 * - Strip DOM-referencing methods (server build)
 * - Emit infrastructure artifacts via onAfterGenerate
 *
 * Currently a no-op placeholder. See spike/macros/ContextSplitter.hx for the
 * proof-of-concept that this will evolve from.
 */
class Build {
    public static function configure() {
        // Called from build.hxml --macro h4x0r.Build.configure()
        // Will register onAfterGenerate and global compilation hooks
    }

    public static function process():Array<Field> {
        // Called from @:build(h4x0r.Build.process()) on each app class
        // For now, pass through all fields unchanged
        return Context.getBuildFields();
    }
}
#end
