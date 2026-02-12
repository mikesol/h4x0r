package;

class Main {
    static function main() {
        var app = new TestApp();
        trace("TestApp instantiated");
        #if !h4x0r_server
        trace(app.format("hello"));
        var result = app.fetchData("test");
        js.Syntax.code("Promise.resolve({0}).then(function(r) { console.log('fetchData result:', JSON.stringify(r)); })", result);
        #end
    }
}
