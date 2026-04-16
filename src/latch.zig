const std = @import("std");
const builtin = @import("builtin");
const markdown = @import("markdown/parser.zig");

pub const Patch = struct {
    id: []const u8,
    depends_on: []const []const u8,
    diff: []const u8,
    info: []const u8,
    start_line: usize,
    end_line: usize,
};

const DiffSection = struct {
    path: []const u8,
    prelude: []const u8,
    hunks: []HunkSection,
    body: []const u8,
};

const HunkSection = struct {
    body: []const u8,
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    markdown_document: markdown.Document,
    patches: []Patch,

    pub fn deinit(self: *Document) void {
        for (self.patches) |patch| {
            self.allocator.free(patch.depends_on);
        }
        self.allocator.free(self.patches);
        self.markdown_document.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
    }

    pub fn orderedPatchIndices(self: *const Document, allocator: std.mem.Allocator) ![]usize {
        var id_to_index: std.StringHashMapUnmanaged(usize) = .empty;
        defer id_to_index.deinit(allocator);

        for (self.patches, 0..) |patch, patch_index| {
            if (id_to_index.contains(patch.id)) {
                logError("duplicate patch id '{s}' at lines {d}-{d}", .{
                    patch.id,
                    patch.start_line,
                    patch.end_line,
                });
                return error.DuplicatePatchId;
            }
            try id_to_index.put(allocator, patch.id, patch_index);
        }

        var in_degree = try allocator.alloc(usize, self.patches.len);
        defer allocator.free(in_degree);
        @memset(in_degree, 0);

        for (self.patches, 0..) |patch, patch_index| {
            in_degree[patch_index] = patch.depends_on.len;
            for (patch.depends_on) |dep| {
                if (!id_to_index.contains(dep)) {
                    logError("patch '{s}' depends on unknown patch '{s}'", .{ patch.id, dep });
                    return error.UnknownDependency;
                }
                if (std.mem.eql(u8, patch.id, dep)) {
                    logError("patch '{s}' cannot depend on itself", .{patch.id});
                    return error.SelfDependency;
                }
            }
        }

        var ready: std.ArrayList(usize) = .empty;
        defer ready.deinit(allocator);
        for (in_degree, 0..) |degree, patch_index| {
            if (degree == 0) try ready.append(allocator, patch_index);
        }

        var ordered: std.ArrayList(usize) = .empty;
        defer ordered.deinit(allocator);

        while (ready.items.len > 0) {
            const next = popLexicographicallySmallest(self.patches, ready.items);
            _ = ready.swapRemove(next.ready_index);
            try ordered.append(allocator, next.patch_index);

            const resolved_id = self.patches[next.patch_index].id;
            for (self.patches, 0..) |patch, patch_index| {
                if (in_degree[patch_index] == 0) continue;
                if (!sliceContains(patch.depends_on, resolved_id)) continue;
                in_degree[patch_index] -= 1;
                if (in_degree[patch_index] == 0) {
                    try ready.append(allocator, patch_index);
                }
            }
        }

        if (ordered.items.len != self.patches.len) {
            var blocked: std.ArrayList([]const u8) = .empty;
            defer blocked.deinit(allocator);
            for (in_degree, 0..) |degree, patch_index| {
                if (degree != 0) try blocked.append(allocator, self.patches[patch_index].id);
            }
            const blocked_ids = try std.mem.join(allocator, ", ", blocked.items);
            defer allocator.free(blocked_ids);
            logError("patch dependency cycle detected among: {s}", .{blocked_ids});
            return error.DependencyCycle;
        }

        return ordered.toOwnedSlice(allocator);
    }
};

pub fn generateDocumentFromGitDiff(allocator: std.mem.Allocator) ![]u8 {
    const diff = try collectGitWorktreeDiff(allocator);
    defer allocator.free(diff);

    return generateDocumentFromUnifiedDiff(allocator, diff);
}

pub fn generateDocumentFromGitSpec(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    const diff = try collectGitSpecDiff(allocator, spec);
    defer allocator.free(diff);

    return generateDocumentFromUnifiedDiff(allocator, diff);
}

pub fn loadDocumentFromFile(allocator: std.mem.Allocator, path: []const u8) !Document {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    errdefer allocator.free(source);
    return parseDocument(allocator, source);
}

pub fn parseDocument(allocator: std.mem.Allocator, owned_source: []u8) !Document {
    var markdown_document = try markdown.parse(allocator, owned_source);
    errdefer markdown_document.deinit();

    var patches: std.ArrayList(Patch) = .empty;
    defer {
        for (patches.items) |patch| allocator.free(patch.depends_on);
        patches.deinit(allocator);
    }

    try collectPatches(allocator, owned_source, markdown_document.children, &patches);
    if (patches.items.len == 0) {
        logError("no executable diff fences found", .{});
        return error.NoExecutableDiffs;
    }

    return .{
        .allocator = allocator,
        .source = owned_source,
        .markdown_document = markdown_document,
        .patches = try patches.toOwnedSlice(allocator),
    };
}

pub fn generateDocumentFromUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) ![]u8 {
    const sections = try parseDiffSections(allocator, diff);
    defer freeDiffSections(allocator, sections);

    if (sections.len == 0) {
        logError("no git diff found to generate from", .{});
        return error.NoGitDiff;
    }

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);

    try builder.writer(allocator).print(
        \\# Draft Latch Document
        \\
        \\Use this file to tell the story of the change. Reorder sections into
        \\narrative order, rewrite the headings and prose, and keep the diff
        \\fences executable.
        \\
        \\Move from user-facing behavior to docs and examples, then internal
        \\machinery, and leave tests or proof points near the end. Keep patch
        \\ids stable while moving sections. Refine dependencies only when the
        \\narrative no longer matches the mechanical order.
        \\
        \\If the diff does not provide suitable context, bring in additional
        \\code context with appropriate non-diff code fences.
        \\
    , .{});

    for (sections) |section| {
        const base_slug = try slugify(allocator, section.path);
        defer allocator.free(base_slug);

        try builder.writer(allocator).print(
            \\
            \\## {s}
            \\
            \\This section was generated from `{s}`.
            \\
        ,
            .{ section.path, section.path },
        );

        if (section.hunks.len == 0) {
            const metadata = try std.fmt.allocPrint(allocator, "id={s}-01", .{base_slug});
            defer allocator.free(metadata);
            try writeDiffFence(
                allocator,
                &builder,
                metadata,
                section.body,
                "",
            );
            continue;
        }

        for (section.hunks, 0..) |hunk, hunk_index| {
            const patch_id = try std.fmt.allocPrint(allocator, "{s}-{d:0>2}", .{ base_slug, hunk_index + 1 });
            defer allocator.free(patch_id);

            const metadata = if (hunk_index == 0)
                try std.fmt.allocPrint(allocator, "id={s}", .{patch_id})
            else
                try std.fmt.allocPrint(
                    allocator,
                    "id={s} depends-on={s}-{d:0>2}",
                    .{ patch_id, base_slug, hunk_index },
                );
            defer allocator.free(metadata);

            try builder.writer(allocator).print(
                \\
                \\### Hunk {d}
                \\
                \\This hunk was generated mechanically from `{s}`.
                \\
            ,
                .{ hunk_index + 1, section.path },
            );
            try writeDiffFence(allocator, &builder, metadata, section.prelude, hunk.body);
        }
    }

    return builder.toOwnedSlice(allocator);
}

pub fn applyPatches(
    allocator: std.mem.Allocator,
    patches: []const Patch,
    ordered_indices: []const usize,
    target_dir: []const u8,
) !void {
    for (ordered_indices) |patch_index| {
        const patch = patches[patch_index];
        var child = std.process.Child.init(&.{ "git", "apply", "--unsafe-paths", "-" }, allocator);
        child.cwd = target_dir;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
        }

        {
            const stdin = child.stdin.?;
            try stdin.writeAll(patch.diff);
            if (!std.mem.endsWith(u8, patch.diff, "\n")) {
                try stdin.writeAll("\n");
            }
            stdin.close();
            child.stdin = null;
        }

        var stdout: std.ArrayList(u8) = .empty;
        defer stdout.deinit(allocator);
        var stderr: std.ArrayList(u8) = .empty;
        defer stderr.deinit(allocator);
        try child.collectOutput(allocator, &stdout, &stderr, 128 * 1024);
        const term = try child.wait();

        switch (term) {
            .Exited => |code| {
                if (code == 0) continue;
                logError("apply patch '{s}' failed with exit code {d}", .{ patch.id, code });
            },
            else => {
                logError("apply patch '{s}' terminated unexpectedly", .{patch.id});
            },
        }

        if (stderr.items.len != 0) {
            logError("{s}", .{stderr.items});
        }
        if (stdout.items.len != 0) {
            logError("{s}", .{stdout.items});
        }
        return error.ApplyFailed;
    }
}

fn collectPatches(
    allocator: std.mem.Allocator,
    source: []const u8,
    nodes: []const markdown.Node,
    patches: *std.ArrayList(Patch),
) !void {
    for (nodes) |node| {
        if (node.kind == .code_block) {
            if (try parsePatchNode(allocator, source, node)) |patch| {
                try patches.append(allocator, patch);
            }
        }
        if (node.children.len != 0) {
            try collectPatches(allocator, source, node.children, patches);
        }
    }
}

fn collectGitWorktreeDiff(allocator: std.mem.Allocator) ![]u8 {
    return runGitForDiff(allocator, &.{ "git", "diff", "--no-ext-diff", "HEAD" });
}

fn collectGitSpecDiff(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    if (looksLikeRevisionRange(spec)) {
        return runGitForDiff(allocator, &.{ "git", "diff", "--no-ext-diff", spec });
    }
    return runGitForDiff(allocator, &.{ "git", "show", "--format=", "--no-ext-diff", spec });
}

fn runGitForDiff(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 16 * 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return result.stdout;
        },
        else => {},
    }

    if (result.stderr.len != 0) {
        logError("{s}", .{result.stderr});
    }
    allocator.free(result.stdout);
    return error.GitDiffFailed;
}

fn looksLikeRevisionRange(spec: []const u8) bool {
    return std.mem.indexOf(u8, spec, "..") != null;
}

fn parseDiffSections(allocator: std.mem.Allocator, diff: []const u8) ![]DiffSection {
    var sections: std.ArrayList(DiffSection) = .empty;
    errdefer {
        for (sections.items) |section| {
            allocator.free(section.hunks);
        }
        sections.deinit(allocator);
    }

    var line_start: usize = 0;
    var current_start: ?usize = null;
    while (line_start < diff.len) {
        const line_end = nextLineEnd(diff, line_start);
        const line = diff[line_start..line_end];
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (current_start) |start| {
                try sections.append(allocator, try parseDiffSection(allocator, diff[start..line_start]));
            }
            current_start = line_start;
        }
        line_start = line_end;
    }

    if (current_start) |start| {
        try sections.append(allocator, try parseDiffSection(allocator, diff[start..]));
    }

    return sections.toOwnedSlice(allocator);
}

fn freeDiffSections(allocator: std.mem.Allocator, sections: []DiffSection) void {
    for (sections) |section| {
        allocator.free(section.hunks);
    }
    allocator.free(sections);
}

fn parseDiffSection(allocator: std.mem.Allocator, section: []const u8) !DiffSection {
    const path = parseSectionPath(section) orelse return error.InvalidDiff;

    var line_start: usize = 0;
    var first_hunk_start: ?usize = null;
    var hunk_count: usize = 0;
    while (line_start < section.len) {
        const line_end = nextLineEnd(section, line_start);
        const line = section[line_start..line_end];
        if (std.mem.startsWith(u8, line, "@@ ")) {
            if (first_hunk_start == null) first_hunk_start = line_start;
            hunk_count += 1;
        }
        line_start = line_end;
    }

    if (first_hunk_start == null) {
        return .{
            .path = path,
            .prelude = "",
            .hunks = &.{},
            .body = section,
        };
    }

    const prelude = section[0..first_hunk_start.?];
    var hunks = try allocator.alloc(HunkSection, hunk_count);
    errdefer allocator.free(hunks);

    var hunk_index: usize = 0;
    var hunk_start = first_hunk_start.?;
    line_start = first_hunk_start.? + 1;
    while (line_start < section.len) {
        const line_end = nextLineEnd(section, line_start);
        const line = section[line_start..line_end];
        if (std.mem.startsWith(u8, line, "@@ ")) {
            hunks[hunk_index] = .{ .body = section[hunk_start..line_start] };
            hunk_index += 1;
            hunk_start = line_start;
        }
        line_start = line_end;
    }
    hunks[hunk_index] = .{ .body = section[hunk_start..] };

    return .{
        .path = path,
        .prelude = prelude,
        .hunks = hunks,
        .body = section,
    };
}

fn parseSectionPath(section: []const u8) ?[]const u8 {
    const first_line_end = std.mem.indexOfScalar(u8, section, '\n') orelse section.len;
    const first_line = std.mem.trimEnd(u8, section[0..first_line_end], "\r");
    const prefix = "diff --git a/";
    if (!std.mem.startsWith(u8, first_line, prefix)) return null;

    const b_marker = " b/";
    const path_start = std.mem.indexOf(u8, first_line, b_marker) orelse return null;
    return first_line[path_start + b_marker.len ..];
}

fn nextLineEnd(source: []const u8, start: usize) usize {
    const newline = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse return source.len;
    return newline + 1;
}

fn writeDiffFence(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    metadata: []const u8,
    prefix: []const u8,
    body: []const u8,
) !void {
    const fence_len = requiredBacktickFenceLen(prefix, body);
    try builder.appendNTimes(allocator, '`', fence_len);
    try builder.writer(allocator).print("diff {s}\n", .{metadata});
    try builder.writer(allocator).writeAll(prefix);
    try builder.writer(allocator).writeAll(body);
    if (!std.mem.endsWith(u8, body, "\n") and !std.mem.endsWith(u8, prefix, "\n")) {
        try builder.append(allocator, '\n');
    } else if (!std.mem.endsWith(u8, body, "\n") and body.len != 0) {
        try builder.append(allocator, '\n');
    }
    try builder.appendNTimes(allocator, '`', fence_len);
    try builder.append(allocator, '\n');
}

fn requiredBacktickFenceLen(prefix: []const u8, body: []const u8) usize {
    const max_run = @max(maxBacktickRun(prefix), maxBacktickRun(body));
    return @max(@as(usize, 3), max_run + 1);
}

fn maxBacktickRun(source: []const u8) usize {
    var best: usize = 0;
    var current: usize = 0;
    for (source) |char| {
        if (char == '`') {
            current += 1;
            best = @max(best, current);
        } else {
            current = 0;
        }
    }
    return best;
}

fn slugify(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var last_was_dash = false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try out.append(allocator, std.ascii.toLower(char));
            last_was_dash = false;
            continue;
        }
        if (!last_was_dash) {
            try out.append(allocator, '-');
            last_was_dash = true;
        }
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "patch");
    }

    return out.toOwnedSlice(allocator);
}

fn parsePatchNode(
    allocator: std.mem.Allocator,
    source: []const u8,
    node: markdown.Node,
) !?Patch {
    var token_iter = std.mem.tokenizeAny(u8, node.info, " \t\r\n");
    const language = token_iter.next() orelse return null;
    if (!std.mem.eql(u8, language, "diff")) return null;

    const span_start: usize = @intCast(node.span_start);
    const span_end: usize = @intCast(node.span_end);
    const start_line = lineNumberForOffset(source, span_start);
    const end_line = lineNumberForOffset(source, if (span_end == 0) 0 else span_end - 1);

    var id: ?[]const u8 = null;
    var depends_on: std.ArrayList([]const u8) = .empty;
    defer depends_on.deinit(allocator);

    while (token_iter.next()) |token| {
        const eq_index = std.mem.indexOfScalar(u8, token, '=') orelse {
            logError("unsupported diff metadata '{s}' at lines {d}-{d}; expected key=value", .{
                token,
                start_line,
                end_line,
            });
            return error.UnsupportedMetadata;
        };

        const key = token[0..eq_index];
        const value = token[eq_index + 1 ..];
        if (std.mem.eql(u8, key, "id")) {
            id = value;
            continue;
        }
        if (std.mem.eql(u8, key, "depends-on")) {
            var dep_iter = std.mem.splitScalar(u8, value, ',');
            while (dep_iter.next()) |dep_raw| {
                const dep = std.mem.trim(u8, dep_raw, " \t\r\n");
                if (dep.len != 0) try depends_on.append(allocator, dep);
            }
            continue;
        }

        logError("unsupported diff metadata key '{s}' at lines {d}-{d}", .{
            key,
            start_line,
            end_line,
        });
        return error.UnsupportedMetadata;
    }

    if (id == null or id.?.len == 0) {
        logError("patch at lines {d}-{d} is missing id=...", .{ start_line, end_line });
        return error.MissingPatchId;
    }

    return .{
        .id = id.?,
        .depends_on = try depends_on.toOwnedSlice(allocator),
        .diff = node.text,
        .info = node.info,
        .start_line = start_line,
        .end_line = end_line,
    };
}

const ReadySelection = struct {
    ready_index: usize,
    patch_index: usize,
};

fn popLexicographicallySmallest(patches: []const Patch, ready: []const usize) ReadySelection {
    var best: ReadySelection = .{
        .ready_index = 0,
        .patch_index = ready[0],
    };

    for (ready[1..], 1..) |patch_index, ready_index| {
        if (std.mem.order(u8, patches[patch_index].id, patches[best.patch_index].id) == .lt) {
            best = .{
                .ready_index = ready_index,
                .patch_index = patch_index,
            };
        }
    }

    return best;
}

fn sliceContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn lineNumberForOffset(source: []const u8, offset: usize) usize {
    const limit = @min(offset, source.len);
    var line: usize = 1;
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (source[index] == '\n') line += 1;
    }
    return line;
}

fn logError(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.log.err(format, args);
}

test "orders by dependency then id" {
    const source =
        \\# Story first
        \\
        \\~~~diff id=tests depends-on=core
        \\diff --git a/example.txt b/example.txt
        \\--- a/example.txt
        \\+++ b/example.txt
        \\@@ -1 +1 @@
        \\-hello
        \\+hello world
        \\~~~
        \\
        \\Some prose between related patches.
        \\
        \\~~~diff id=core
        \\diff --git a/example.txt b/example.txt
        \\--- a/example.txt
        \\+++ b/example.txt
        \\@@ -1 +1 @@
        \\-hello
        \\+hello there
        \\~~~
        \\
    ;

    const owned = try std.testing.allocator.dupe(u8, source);
    var document = try parseDocument(std.testing.allocator, owned);
    defer document.deinit();

    const ordered = try document.orderedPatchIndices(std.testing.allocator);
    defer std.testing.allocator.free(ordered);

    try std.testing.expectEqualStrings("core", document.patches[ordered[0]].id);
    try std.testing.expectEqualStrings("tests", document.patches[ordered[1]].id);
}

test "requires patch ids" {
    const source =
        \\~~~diff
        \\diff --git a/example.txt b/example.txt
        \\~~~
        \\
    ;

    const owned = try std.testing.allocator.dupe(u8, source);
    try std.testing.expectError(error.MissingPatchId, parseDocument(std.testing.allocator, owned));
    std.testing.allocator.free(owned);
}

test "detects dependency cycles" {
    const source =
        \\~~~diff id=a depends-on=b
        \\diff --git a/example.txt b/example.txt
        \\~~~
        \\
        \\~~~diff id=b depends-on=a
        \\diff --git a/example.txt b/example.txt
        \\~~~
        \\
    ;

    const owned = try std.testing.allocator.dupe(u8, source);
    var document = try parseDocument(std.testing.allocator, owned);
    defer document.deinit();

    try std.testing.expectError(error.DependencyCycle, document.orderedPatchIndices(std.testing.allocator));
}

test "generate document from unified diff" {
    const diff =
        \\diff --git a/src/main.zig b/src/main.zig
        \\index 1111111..2222222 100644
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1,3 +1,4 @@
        \\ const std = @import("std");
        \\+const builtin = @import("builtin");
        \\ const latch = @import("latch.zig");
        \\ 
        \\@@ -10,3 +11,4 @@ pub fn main() void {
        \\     run() catch |err| {
        \\+        _ = err;
        \\     };
        \\ }
        \\
        \\diff --git a/README.md b/README.md
        \\index 3333333..4444444 100644
        \\--- a/README.md
        \\+++ b/README.md
        \\@@ -1,4 +1,5 @@
        \\ # Latch
        \\ ```
        \\+Generated docs.
        \\ ```
        \\
    ;

    const generated = try generateDocumentFromUnifiedDiff(std.testing.allocator, diff);
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated, "```diff id=src-main-zig-01") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, generated, "```diff id=src-main-zig-02 depends-on=src-main-zig-01") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, generated, "````diff id=readme-md-01") != null);
}

test "detects git revision ranges" {
    try std.testing.expect(looksLikeRevisionRange("HEAD~2..HEAD"));
    try std.testing.expect(looksLikeRevisionRange("main...feature"));
    try std.testing.expect(!looksLikeRevisionRange("HEAD~2"));
    try std.testing.expect(!looksLikeRevisionRange("feature-branch"));
}
