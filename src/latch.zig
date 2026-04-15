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
