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
