# CLI Arena Allocation

This patch changes the CLI entrypoint to pick its backing allocator by build mode.
`Debug` and `ReleaseSafe` keep `DebugAllocator`, while `ReleaseFast` and `ReleaseSmall` switch to `std.heap.smp_allocator`.

It also moves the arena boundary to the top of `main`.
That makes the CLI lifecycle explicit: choose the backing allocator once, create one arena for the process run, and pass that arena allocator through the rest of the command path.

```diff id=main-cli-arena
diff --git a/src/main.zig b/src/main.zig
index 086accbf7cb8..f9d6bf19ffa3 100644
--- a/src/main.zig
+++ b/src/main.zig
@@ -1,8 +1,24 @@
 const std = @import("std");
+const builtin = @import("builtin");
 const latch = @import("latch.zig");
 
 pub fn main() void {
-    run() catch |err| {
+    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
+    const backing_allocator, const is_debug = allocator: {
+        break :allocator switch (builtin.mode) {
+            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
+            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
+        };
+    };
+    defer if (is_debug) {
+        _ = debug_allocator.deinit();
+    };
+
+    var arena_state = std.heap.ArenaAllocator.init(backing_allocator);
+    defer arena_state.deinit();
+    const allocator = arena_state.allocator();
+
+    run(allocator) catch |err| {
         reportError(err) catch |report_err| {
             std.debug.panic("failed to report error: {s}", .{@errorName(report_err)});
         };
@@ -10,11 +26,7 @@ pub fn main() void {
     };
 }
 
-fn run() !void {
-    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
-    defer _ = debug_allocator.deinit();
-    const allocator = debug_allocator.allocator();
-
+fn run(allocator: std.mem.Allocator) !void {
     const args = try std.process.argsAlloc(allocator);
     defer std.process.argsFree(allocator, args);
 
```
