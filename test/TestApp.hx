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
