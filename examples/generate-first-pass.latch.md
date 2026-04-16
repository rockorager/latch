# Teach Latch To Write Latch

This patch gives `latch` a first-pass `generate` command.
The workflow it enables is code-first: make the code changes you want, then ask `latch` to turn the current Git diff into a `.latch.md` that can be edited into a real patch narrative.

This human pass follows the narrative guidance the generator now emits.
We start with the user-facing CLI entrypoint, then show the docs that explain the workflow, then move into the implementation machinery, and leave the proof-oriented test change at the end.

The important constraint is that the story can move while the execution metadata stays stable.
The patch ids and `depends-on` edges below are the same ones generated mechanically; only the prose and section order have been rewritten.

## src/main.zig

The story starts at the command surface.
Before we explain how the generator works internally, we make the feature visible from the CLI and define what the user experience looks like.

### Hunk 1

The dispatcher learns a new subcommand so `generate` is actually reachable.

```diff id=src-main-zig-01
diff --git a/src/main.zig b/src/main.zig
index f9d6bf19ffa3..75fc3ecd8d09 100644
--- a/src/main.zig
+++ b/src/main.zig
@@ -39,6 +39,10 @@ fn run(allocator: std.mem.Allocator) !void {
         try runPlan(allocator, args[2..]);
         return;
     }
+    if (std.mem.eql(u8, args[1], "generate")) {
+        try runGenerate(allocator, args[2..]);
+        return;
+    }
     if (std.mem.eql(u8, args[1], "apply")) {
         try runApply(allocator, args[2..]);
         return;
```

### Hunk 2

This is the user-facing wrapper: accept an output path, render the current Git diff as a document, and write the resulting `.latch.md`.

```diff id=src-main-zig-02 depends-on=src-main-zig-01
diff --git a/src/main.zig b/src/main.zig
index f9d6bf19ffa3..75fc3ecd8d09 100644
--- a/src/main.zig
+++ b/src/main.zig
@@ -86,6 +90,24 @@ fn runPlan(allocator: std.mem.Allocator, args: []const []const u8) !void {
     try stdout_writer.interface.flush();
 }
 
+fn runGenerate(allocator: std.mem.Allocator, args: []const []const u8) !void {
+    if (args.len != 1) return error.MissingOutputPath;
+
+    const output_path = args[0];
+    const generated = try latch.generateDocumentFromGitDiff(allocator);
+    defer allocator.free(generated);
+
+    try std.fs.cwd().writeFile(.{
+        .sub_path = output_path,
+        .data = generated,
+    });
+
+    var stdout_buffer: [1024]u8 = undefined;
+    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
+    try stdout_writer.interface.print("generated {s}\n", .{output_path});
+    try stdout_writer.interface.flush();
+}
+
 fn runApply(allocator: std.mem.Allocator, args: []const []const u8) !void {
     var target_dir: []const u8 = ".";
     var document_path: ?[]const u8 = null;
```

### Hunk 3

Help text needs to keep pace with the command surface, so usage output starts advertising `generate`.

```diff id=src-main-zig-03 depends-on=src-main-zig-02
diff --git a/src/main.zig b/src/main.zig
index f9d6bf19ffa3..75fc3ecd8d09 100644
--- a/src/main.zig
+++ b/src/main.zig
@@ -125,6 +147,7 @@ fn printUsage() !void {
     try stderr_writer.interface.writeAll("latch: literate patch proof of concept\n\n");
     try stderr_writer.interface.writeAll("usage:\n");
     try stderr_writer.interface.writeAll("  latch plan <document.md>\n");
+    try stderr_writer.interface.writeAll("  latch generate <document.latch.md>\n");
     try stderr_writer.interface.writeAll("  latch apply [--dir path] <document.md>\n");
     try stderr_writer.interface.flush();
 }
```

### Hunk 4

Finally, the error path learns how to fail cleanly when `generate` is invoked without an output path.

```diff id=src-main-zig-04 depends-on=src-main-zig-03
diff --git a/src/main.zig b/src/main.zig
index f9d6bf19ffa3..75fc3ecd8d09 100644
--- a/src/main.zig
+++ b/src/main.zig
@@ -144,6 +167,11 @@ fn reportError(err: anyerror) !void {
             try printUsage();
             return;
         },
+        error.MissingOutputPath => {
+            try stderr_writer.interface.writeAll("error: expected an output path\n");
+            try printUsage();
+            return;
+        },
         error.MissingApplyDir => try stderr_writer.interface.writeAll("error: --dir requires a path\n"),
         error.UnexpectedArgument => try stderr_writer.interface.writeAll("error: unexpected extra argument\n"),
         else => try stderr_writer.interface.print("error: {s}\n", .{@errorName(err)}),
```

## README.md

Once the command exists, the next question is how people are supposed to use it.
The README patch answers that by describing `generate` as the bridge from ordinary code changes to a literate patch document.

### Hunk 1

This documentation update introduces the workflow and makes the new command discoverable in the project docs.

````diff id=readme-md-01
diff --git a/README.md b/README.md
index d5e0a3f93ae9..cae3e8210c4a 100644
--- a/README.md
+++ b/README.md
@@ -42,9 +42,15 @@ diff --git a/hello.txt b/hello.txt
 - If multiple patches are otherwise independent, they are applied in lexical `id` order.
 - Patch application currently shells out to `git apply --unsafe-paths`.
 
+## Workflow
+
+`latch generate` turns the current Git diff into a first-pass `.latch.md`.
+The generated document is intentionally mechanical: it preserves fine-grained hunks, inserts stable patch ids, and gives you prose stubs to edit into a coherent story.
+
 ## Usage
 
 ```sh
 zig build run -- plan examples/demo.lpatch.md
+zig build run -- generate examples/change.latch.md
 zig build run -- apply --dir examples/demo-target examples/demo.lpatch.md
 ```
````

## src/latch.zig

With the command surface and docs in place, the rest of the patch can focus on the engine.
`src/latch.zig` learns how to read the current Git diff, split it into patch-sized units, and render those units as a Markdown document that is already executable before the prose is polished.

### Hunk 1

The generator needs a vocabulary for what it is emitting, so the first internal change introduces `DiffSection` and `HunkSection`.

```diff id=src-latch-zig-01
diff --git a/src/latch.zig b/src/latch.zig
index 08ac248f1d52..2ab8428e34f5 100644
--- a/src/latch.zig
+++ b/src/latch.zig
@@ -11,6 +11,17 @@ pub const Patch = struct {
     end_line: usize,
 };
 
+const DiffSection = struct {
+    path: []const u8,
+    prelude: []const u8,
+    hunks: []HunkSection,
+    body: []const u8,
+};
+
+const HunkSection = struct {
+    body: []const u8,
+};
+
 pub const Document = struct {
     allocator: std.mem.Allocator,
     source: []u8,
```

### Hunk 2

With those types in place, the next step exposes a public entrypoint that gathers the current Git diff and hands it to the renderer.

```diff id=src-latch-zig-02 depends-on=src-latch-zig-01
diff --git a/src/latch.zig b/src/latch.zig
index 08ac248f1d52..2ab8428e34f5 100644
--- a/src/latch.zig
+++ b/src/latch.zig
@@ -102,6 +113,13 @@ pub const Document = struct {
     }
 };
 
+pub fn generateDocumentFromGitDiff(allocator: std.mem.Allocator) ![]u8 {
+    const diff = try collectGitDiff(allocator);
+    defer allocator.free(diff);
+
+    return generateDocumentFromUnifiedDiff(allocator, diff);
+}
+
 pub fn loadDocumentFromFile(allocator: std.mem.Allocator, path: []const u8) !Document {
     const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
     errdefer allocator.free(source);
```

### Hunk 3

This is the core rendering pass.
It turns parsed diff sections into a skeletal Latch document, emits explicit guidance for the human rewrite pass, and preserves stable ids while allowing the narrative to move later.

```diff id=src-latch-zig-03 depends-on=src-latch-zig-02
diff --git a/src/latch.zig b/src/latch.zig
index 08ac248f1d52..2ab8428e34f5 100644
--- a/src/latch.zig
+++ b/src/latch.zig
@@ -132,6 +150,84 @@ pub fn parseDocument(allocator: std.mem.Allocator, owned_source: []u8) !Document
     };
 }
 
+pub fn generateDocumentFromUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) ![]u8 {
+    const sections = try parseDiffSections(allocator, diff);
+    defer freeDiffSections(allocator, sections);
+
+    if (sections.len == 0) {
+        logError("no git diff found to generate from", .{});
+        return error.NoGitDiff;
+    }
+
+    var builder: std.ArrayList(u8) = .empty;
+    defer builder.deinit(allocator);
+
+    const patch_count = countGeneratedPatches(sections);
+    try builder.writer(allocator).print(
+        "# Generated Latch\n\n" ++
+            "This document was generated from the current Git diff.\n" ++
+            "It captures {d} executable patch block{s} across {d} changed file{s}.\n\n" ++
+            "This draft is intentionally mechanical.\n" ++
+            "On the human pass, prefer narrative order over diff order.\n" ++
+            "Start with user-facing commands or API entrypoints, then docs and examples, " ++
+            "then internal machinery, and leave tests or proof points near the end.\n" ++
+            "Keep patch ids stable while moving sections.\n" ++
+            "Refine dependencies only when the narrative no longer matches the mechanical order.\n",
+        .{
+            patch_count,
+            if (patch_count == 1) "" else "s",
+            sections.len,
+            if (sections.len == 1) "" else "s",
+        },
+    );
+
+    for (sections) |section| {
+        const base_slug = try slugify(allocator, section.path);
+        defer allocator.free(base_slug);
+
+        try builder.writer(allocator).print(
+            "\n## {s}\n\nThis section was generated from `{s}`.\n",
+            .{ section.path, section.path },
+        );
+
+        if (section.hunks.len == 0) {
+            const metadata = try std.fmt.allocPrint(allocator, "id={s}-01", .{base_slug});
+            defer allocator.free(metadata);
+            try writeDiffFence(
+                allocator,
+                &builder,
+                metadata,
+                section.body,
+                "",
+            );
+            continue;
+        }
+
+        for (section.hunks, 0..) |hunk, hunk_index| {
+            const patch_id = try std.fmt.allocPrint(allocator, "{s}-{d:0>2}", .{ base_slug, hunk_index + 1 });
+            defer allocator.free(patch_id);
+
+            const metadata = if (hunk_index == 0)
+                try std.fmt.allocPrint(allocator, "id={s}", .{patch_id})
+            else
+                try std.fmt.allocPrint(
+                    allocator,
+                    "id={s} depends-on={s}-{d:0>2}",
+                    .{ patch_id, base_slug, hunk_index },
+                );
+            defer allocator.free(metadata);
+
+            try builder.writer(allocator).print(
+                "\n### Hunk {d}\n\nThis hunk was generated mechanically from `{s}`.\n\n",
+                .{ hunk_index + 1, section.path },
+            );
+            try writeDiffFence(allocator, &builder, metadata, section.prelude, hunk.body);
+        }
+    }
+
+    return builder.toOwnedSlice(allocator);
+}
+
 pub fn applyPatches(
     allocator: std.mem.Allocator,
     patches: []const Patch,
```

### Hunk 4

The renderer needs raw material, so this chunk adds the Git collection path and the helpers that split a unified diff into sections and hunks.

```diff id=src-latch-zig-04 depends-on=src-latch-zig-03
diff --git a/src/latch.zig b/src/latch.zig
index 08ac248f1d52..2ab8428e34f5 100644
--- a/src/latch.zig
+++ b/src/latch.zig
@@ -206,6 +302,205 @@ fn collectPatches(
     }
 }
 
+fn collectGitDiff(allocator: std.mem.Allocator) ![]u8 {
+    const result = try std.process.Child.run(.{
+        .allocator = allocator,
+        .argv = &.{ "git", "diff", "--no-ext-diff", "HEAD" },
+        .max_output_bytes = 16 * 1024 * 1024,
+    });
+    defer allocator.free(result.stderr);
+
+    switch (result.term) {
+        .Exited => |code| {
+            if (code == 0) return result.stdout;
+        },
+        else => {},
+    }
+
+    if (result.stderr.len != 0) {
+        logError("{s}", .{result.stderr});
+    }
+    allocator.free(result.stdout);
+    return error.GitDiffFailed;
+}
+
+fn parseDiffSections(allocator: std.mem.Allocator, diff: []const u8) ![]DiffSection {
+    var sections: std.ArrayList(DiffSection) = .empty;
+    errdefer {
+        for (sections.items) |section| {
+            allocator.free(section.hunks);
+        }
+        sections.deinit(allocator);
+    }
+
+    var line_start: usize = 0;
+    var current_start: ?usize = null;
+    while (line_start < diff.len) {
+        const line_end = nextLineEnd(diff, line_start);
+        const line = diff[line_start..line_end];
+        if (std.mem.startsWith(u8, line, "diff --git ")) {
+            if (current_start) |start| {
+                try sections.append(allocator, try parseDiffSection(allocator, diff[start..line_start]));
+            }
+            current_start = line_start;
+        }
+        line_start = line_end;
+    }
+
+    if (current_start) |start| {
+        try sections.append(allocator, try parseDiffSection(allocator, diff[start..]));
+    }
+
+    return sections.toOwnedSlice(allocator);
+}
+
+fn freeDiffSections(allocator: std.mem.Allocator, sections: []DiffSection) void {
+    for (sections) |section| {
+        allocator.free(section.hunks);
+    }
+    allocator.free(sections);
+}
+
+fn parseDiffSection(allocator: std.mem.Allocator, section: []const u8) !DiffSection {
+    const path = parseSectionPath(section) orelse return error.InvalidDiff;
+
+    var line_start: usize = 0;
+    var first_hunk_start: ?usize = null;
+    var hunk_count: usize = 0;
+    while (line_start < section.len) {
+        const line_end = nextLineEnd(section, line_start);
+        const line = section[line_start..line_end];
+        if (std.mem.startsWith(u8, line, "@@ ")) {
+            if (first_hunk_start == null) first_hunk_start = line_start;
+            hunk_count += 1;
+        }
+        line_start = line_end;
+    }
+
+    if (first_hunk_start == null) {
+        return .{
+            .path = path,
+            .prelude = "",
+            .hunks = &.{},
+            .body = section,
+        };
+    }
+
+    const prelude = section[0..first_hunk_start.?];
+    var hunks = try allocator.alloc(HunkSection, hunk_count);
+    errdefer allocator.free(hunks);
+
+    var hunk_index: usize = 0;
+    var hunk_start = first_hunk_start.?;
+    line_start = first_hunk_start.? + 1;
+    while (line_start < section.len) {
+        const line_end = nextLineEnd(section, line_start);
+        const line = section[line_start..line_end];
+        if (std.mem.startsWith(u8, line, "@@ ")) {
+            hunks[hunk_index] = .{ .body = section[hunk_start..line_start] };
+            hunk_index += 1;
+            hunk_start = line_start;
+        }
+        line_start = line_end;
+    }
+    hunks[hunk_index] = .{ .body = section[hunk_start..] };
+
+    return .{
+        .path = path,
+        .prelude = prelude,
+        .hunks = hunks,
+        .body = section,
+    };
+}
+
+fn countGeneratedPatches(sections: []const DiffSection) usize {
+    var count: usize = 0;
+    for (sections) |section| {
+        count += if (section.hunks.len == 0) 1 else section.hunks.len;
+    }
+    return count;
+}
+
+fn parseSectionPath(section: []const u8) ?[]const u8 {
+    const first_line_end = std.mem.indexOfScalar(u8, section, '\n') orelse section.len;
+    const first_line = std.mem.trimEnd(u8, section[0..first_line_end], "\r");
+    const prefix = "diff --git a/";
+    if (!std.mem.startsWith(u8, first_line, prefix)) return null;
+
+    const b_marker = " b/";
+    const path_start = std.mem.indexOf(u8, first_line, b_marker) orelse return null;
+    return first_line[path_start + b_marker.len ..];
+}
+
+fn nextLineEnd(source: []const u8, start: usize) usize {
+    const newline = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse return source.len;
+    return newline + 1;
+}
+
+fn writeDiffFence(
+    allocator: std.mem.Allocator,
+    builder: *std.ArrayList(u8),
+    metadata: []const u8,
+    prefix: []const u8,
+    body: []const u8,
+) !void {
+    const fence_len = requiredBacktickFenceLen(prefix, body);
+    try builder.appendNTimes(allocator, '`', fence_len);
+    try builder.writer(allocator).print("diff {s}\n", .{metadata});
+    try builder.writer(allocator).writeAll(prefix);
+    try builder.writer(allocator).writeAll(body);
+    if (!std.mem.endsWith(u8, body, "\n") and !std.mem.endsWith(u8, prefix, "\n")) {
+        try builder.append(allocator, '\n');
+    } else if (!std.mem.endsWith(u8, body, "\n") and body.len != 0) {
+        try builder.append(allocator, '\n');
+    }
+    try builder.appendNTimes(allocator, '`', fence_len);
+    try builder.append(allocator, '\n');
+}
+
+fn requiredBacktickFenceLen(prefix: []const u8, body: []const u8) usize {
+    const max_run = @max(maxBacktickRun(prefix), maxBacktickRun(body));
+    return @max(@as(usize, 3), max_run + 1);
+}
+
+fn maxBacktickRun(source: []const u8) usize {
+    var best: usize = 0;
+    var current: usize = 0;
+    for (source) |char| {
+        if (char == '`') {
+            current += 1;
+            best = @max(best, current);
+        } else {
+            current = 0;
+        }
+    }
+    return best;
+}
+
+fn slugify(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
+    var out: std.ArrayList(u8) = .empty;
+    defer out.deinit(allocator);
+
+    var last_was_dash = false;
+    for (value) |char| {
+        if (std.ascii.isAlphanumeric(char)) {
+            try out.append(allocator, std.ascii.toLower(char));
+            last_was_dash = false;
+            continue;
+        }
+        if (!last_was_dash) {
+            try out.append(allocator, '-');
+            last_was_dash = true;
+        }
+    }
+
+    if (out.items.len == 0) {
+        try out.appendSlice(allocator, "patch");
+    }
+
+    return out.toOwnedSlice(allocator);
+}
+
 fn parsePatchNode(
     allocator: std.mem.Allocator,
     source: []const u8,
```

### Hunk 5

The last internal chunk is the proof point.
It adds a focused test that checks both id generation and the variable-length backtick fence logic for diffs that themselves contain Markdown fences.

`````diff id=src-latch-zig-05 depends-on=src-latch-zig-04
diff --git a/src/latch.zig b/src/latch.zig
index 08ac248f1d52..2ab8428e34f5 100644
--- a/src/latch.zig
+++ b/src/latch.zig
@@ -385,3 +680,42 @@ test "detects dependency cycles" {
 
     try std.testing.expectError(error.DependencyCycle, document.orderedPatchIndices(std.testing.allocator));
 }
+
+test "generate document from unified diff" {
+    const diff =
+        \\diff --git a/src/main.zig b/src/main.zig
+        \\index 1111111..2222222 100644
+        \\--- a/src/main.zig
+        \\+++ b/src/main.zig
+        \\@@ -1,3 +1,4 @@
+        \\ const std = @import("std");
+        \\+const builtin = @import("builtin");
+        \\ const latch = @import("latch.zig");
+        \\ 
+        \\@@ -10,3 +11,4 @@ pub fn main() void {
+        \\     run() catch |err| {
+        \\+        _ = err;
+        \\     };
+        \\ }
+        \\
+        \\diff --git a/README.md b/README.md
+        \\index 3333333..4444444 100644
+        \\--- a/README.md
+        \\+++ b/README.md
+        \\@@ -1,4 +1,5 @@
+        \\ # Latch
+        \\ ```
+        \\+Generated docs.
+        \\ ```
+        \\
+    ;
+
+    const generated = try generateDocumentFromUnifiedDiff(std.testing.allocator, diff);
+    defer std.testing.allocator.free(generated);
+
+    try std.testing.expect(std.mem.indexOf(u8, generated, "```diff id=src-main-zig-01") != null);
+    try std.testing.expect(
+        std.mem.indexOf(u8, generated, "```diff id=src-main-zig-02 depends-on=src-main-zig-01") != null,
+    );
+    try std.testing.expect(std.mem.indexOf(u8, generated, "````diff id=readme-md-01") != null);
+}
`````
