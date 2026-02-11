package;

class Main {
    static function main() {
        trace("=== h4x0r Spike ===");
        trace("The build macro has already:");
        trace("  1. Analyzed TodoApp's annotations");
        trace("  2. Replaced server method bodies with fetch proxies");
        trace("  3. Generated gen/worker.js with server endpoints");
        trace("  4. Generated gen/manifest.md with API docs");
        trace("");

        var app = new TodoApp();

        trace("--- Calling client method ---");
        app.renderTodoList();

        trace("");
        trace("--- Calling server-proxied method ---");
        app.handleAddClick("Buy groceries");
    }
}
