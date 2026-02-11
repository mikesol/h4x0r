package;

// A h4x0r component — user writes normal code with annotations.
// The build macro splits it at compile time.
@:build(macros.ContextSplitter.build())
class TodoApp {
    public function new() {}

    // Shared state — synced between client and server
    @:shared
    var todos:Array<String> = [];

    @:shared
    var filter:String = "all";

    // Server-only: this runs on the Cloudflare Worker
    // On the client, the body is replaced with a fetch() proxy
    @:server
    public function addTodo(text:String):Dynamic {
        // This body only exists on the server
        todos.push(text);
        return {ok: true, count: todos.length};
    }

    @:server
    public function removeTodo(index:Int):Dynamic {
        todos.splice(index, 1);
        return {ok: true, count: todos.length};
    }

    @:server
    public function getTodos(filter:String):Array<String> {
        // In real code: query DB, filter, return
        return todos;
    }

    // Client-only: this runs in the browser
    @:client
    public function renderTodoList():Void {
        trace("Rendering " + Std.string(todos.length) + " todos");
        for (todo in todos) {
            trace("  - " + todo);
        }
    }

    @:client
    public function handleAddClick(text:String):Void {
        // On the client, addTodo() is a proxy — it calls the server
        var result = addTodo(text);
        trace("Server responded: " + Std.string(result));
        renderTodoList();
    }
}
