package h4x0r;

/**
 * SCAFFOLD(Phase 1, #1)
 *
 * Runtime API for h4x0r primitives. Called as Api.proxyFetch(...), Api.secret(...), etc.
 *
 * - proxyFetch: on server, real HTTP fetch with injected headers; on client, replaced by proxy stub
 * - secret: on server, reads from Cloudflare env bindings; on client, returns "" (body replaced anyway)
 * - serverOnly/clientOnly: execute the callback directly (placement enforced at compile time)
 */
class Api {
    public static function proxyFetch(url:String, headers:Dynamic, body:Dynamic):Dynamic {
        #if h4x0r_server
        return js.Syntax.code(
            "fetch({0}, {method: 'POST', headers: Object.assign({'Content-Type': 'application/json'}, {1}), body: JSON.stringify({2})}).then(function(r) { return r.json(); })",
            url, headers, body);
        #else
        return null;
        #end
    }

    public static function secret(name:String):String {
        #if h4x0r_server
        return js.Syntax.code("(globalThis.__h4x0r_env && globalThis.__h4x0r_env[{0}]) || ''", name);
        #else
        return "";
        #end
    }

    public static function serverOnly(f:() -> Void):Void {
        f();
    }

    public static function clientOnly(f:() -> Void):Void {
        f();
    }
}
