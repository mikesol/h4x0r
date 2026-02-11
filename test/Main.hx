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
        app.audit("login");
        app.setupUI();
        #end
    }
}
