const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const latch = @import("latch.zig");

const skill_markdown = build_options.skill_markdown;
const max_input_bytes = 16 * 1024 * 1024;

pub fn main() void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const backing_allocator, const is_debug = allocator: {
        break :allocator switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var arena_state = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var diagnostics = latch.Diagnostic.init(allocator);

    run(allocator, &diagnostics) catch |err| {
        reportError(err, &diagnostics) catch |report_err| {
            std.debug.panic("failed to report error: {s}", .{@errorName(report_err)});
        };
        std.process.exit(1);
    };
}

fn run(allocator: std.mem.Allocator, diagnostics: *latch.Diagnostic) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "draft")) {
        try runDraft(allocator, args[2..], diagnostics);
        return;
    }
    if (std.mem.eql(u8, args[1], "apply")) {
        try runApply(allocator, args[2..], diagnostics);
        return;
    }
    if (std.mem.eql(u8, args[1], "commit")) {
        try runCommit(allocator, args[2..], diagnostics);
        return;
    }
    if (std.mem.eql(u8, args[1], "show")) {
        try runShow(allocator, args[2..], diagnostics);
        return;
    }
    if (std.mem.eql(u8, args[1], "review")) {
        try runReview(allocator, args[2..], diagnostics);
        return;
    }
    if (std.mem.eql(u8, args[1], "skill")) {
        try runSkill(args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        try printUsage();
        return;
    }

    try printUsage();
    return error.InvalidCommand;
}

fn runDraft(allocator: std.mem.Allocator, args: []const []const u8, diagnostics: *latch.Diagnostic) !void {
    if (args.len == 1 and isHelpFlag(args[0])) {
        try printDraftUsage();
        return;
    }

    var output_path: ?[]const u8 = null;
    var git_spec: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= args.len) return error.MissingOutputPath;
            output_path = args[index];
            continue;
        }
        if (git_spec != null) return error.UnexpectedArgument;
        git_spec = arg;
    }

    const stdin_file = std.fs.File.stdin();
    const stdin_diff = stdin_diff: {
        if (stdin_file.isTty()) break :stdin_diff null;
        const data = try stdin_file.readToEndAlloc(allocator, max_input_bytes);
        if (data.len == 0) {
            allocator.free(data);
            break :stdin_diff null;
        }
        break :stdin_diff data;
    };
    defer if (stdin_diff) |diff| allocator.free(diff);

    const has_stdin_input = stdin_diff != null;
    if (has_stdin_input and git_spec != null) return error.ConflictingDraftInput;

    const generated = generated: {
        if (stdin_diff) |diff| {
            break :generated try latch.generateDocumentFromUnifiedDiffWithDiagnostics(allocator, diff, diagnostics);
        }
        if (git_spec) |spec| {
            break :generated try latch.generateDocumentFromGitSpecWithDiagnostics(allocator, spec, diagnostics);
        }
        break :generated try latch.generateDocumentFromGitDiffWithDiagnostics(allocator, diagnostics);
    };
    defer allocator.free(generated);

    if (output_path) |path| {
        try std.fs.cwd().writeFile(.{
            .sub_path = path,
            .data = generated,
        });

        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        try stdout_writer.interface.print("generated {s}\n", .{path});
        try stdout_writer.interface.flush();
        return;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.writeAll(generated);
    try stdout_writer.interface.flush();
}

fn runApply(allocator: std.mem.Allocator, args: []const []const u8, diagnostics: *latch.Diagnostic) !void {
    if (args.len == 1 and isHelpFlag(args[0])) {
        try printApplyUsage();
        return;
    }

    var target_dir: []const u8 = ".";
    var document_path: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--dir")) {
            index += 1;
            if (index >= args.len) return error.MissingApplyDir;
            target_dir = args[index];
            continue;
        }
        if (document_path != null) return error.UnexpectedArgument;
        document_path = arg;
    }

    var document = try loadApplyDocument(allocator, document_path, diagnostics);
    defer document.deinit();

    const ordered = try document.orderedPatchIndicesWithDiagnostics(allocator, diagnostics);
    defer allocator.free(ordered);

    try latch.applyPatchesWithDiagnostics(allocator, document.patches, ordered, target_dir, diagnostics);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("applied {d} patches to {s}\n", .{ ordered.len, target_dir });
    try stdout_writer.interface.flush();
}

fn runCommit(allocator: std.mem.Allocator, args: []const []const u8, diagnostics: *latch.Diagnostic) !void {
    if (args.len == 1 and isHelpFlag(args[0])) {
        try printCommitUsage();
        return;
    }
    if (args.len != 1) return error.MissingDocumentPath;

    const commit_id = try latch.commitDocumentFromFileWithDiagnostics(allocator, args[0], diagnostics);
    defer allocator.free(commit_id);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("committed {s}\n", .{std.mem.trimEnd(u8, commit_id, "\r\n")});
    try stdout_writer.interface.flush();
}

fn runShow(allocator: std.mem.Allocator, args: []const []const u8, diagnostics: *latch.Diagnostic) !void {
    if (args.len == 1 and isHelpFlag(args[0])) {
        try printShowUsage();
        return;
    }
    if (args.len > 1) return error.UnexpectedArgument;

    const commit = if (args.len == 0) "HEAD" else args[0];
    const document = try latch.showCommitWithDiagnostics(allocator, commit, diagnostics);
    defer allocator.free(document);

    const stdout_file = std.fs.File.stdout();
    if (!stdout_file.isTty()) {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = stdout_file.writer(&stdout_buffer);
        try stdout_writer.interface.writeAll(document);
        try stdout_writer.interface.flush();
        return;
    }

    const color = shouldColorShowOutput();
    const rendered = try renderShowMarkdown(allocator, document, color);
    defer allocator.free(rendered);

    const pager = showPager();
    if (pagerDisablesPaging(pager)) {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = stdout_file.writer(&stdout_buffer);
        try stdout_writer.interface.writeAll(rendered);
        try stdout_writer.interface.flush();
        return;
    }

    try pageShowOutput(allocator, pager, rendered);
}

const RenderFence = struct {
    marker: u8,
    count: usize,
    info: []const u8,
};

fn renderShowMarkdown(allocator: std.mem.Allocator, document: []const u8, color: bool) ![]u8 {
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);

    var in_code = false;
    var code_marker: u8 = 0;
    var code_count: usize = 0;
    var code_language: []const u8 = "";

    var line_start: usize = 0;
    while (line_start < document.len) {
        const line_end = nextLineEnd(document, line_start);
        const line = document[line_start..line_end];
        const content = std.mem.trimEnd(u8, line, "\r\n");

        if (in_code) {
            if (isClosingRenderFence(content, code_marker, code_count)) {
                if (std.mem.eql(u8, code_language, "diff")) {
                    try writeDiffPrefix(allocator, &rendered, color);
                }
                try writeStyledLine(allocator, &rendered, line, color, "\x1b[2m");
                in_code = false;
                code_language = "";
            } else if (std.mem.eql(u8, code_language, "diff")) {
                try writeDiffLine(allocator, &rendered, line, color);
            } else if (std.mem.eql(u8, code_language, "review")) {
                try writeStyledLine(allocator, &rendered, line, color, "\x1b[33m");
            } else {
                try rendered.appendSlice(allocator, line);
            }
        } else if (parseRenderFence(content)) |fence| {
            in_code = true;
            code_marker = fence.marker;
            code_count = fence.count;
            code_language = renderFenceLanguage(fence.info);
            if (std.mem.eql(u8, code_language, "diff")) {
                try writeDiffPrefix(allocator, &rendered, color);
            }
            try writeStyledLine(allocator, &rendered, line, color, "\x1b[2m");
        } else if (std.mem.startsWith(u8, content, "# ")) {
            try writeStyledLine(allocator, &rendered, line, color, "\x1b[1;34m");
        } else if (std.mem.startsWith(u8, content, "## ") or std.mem.startsWith(u8, content, "### ")) {
            try writeStyledLine(allocator, &rendered, line, color, "\x1b[1;35m");
        } else {
            try rendered.appendSlice(allocator, line);
        }

        line_start = line_end;
    }

    return rendered.toOwnedSlice(allocator);
}

fn writeDiffLine(
    allocator: std.mem.Allocator,
    rendered: *std.ArrayList(u8),
    line: []const u8,
    color: bool,
) !void {
    try writeDiffPrefix(allocator, rendered, color);
    const content = std.mem.trimEnd(u8, line, "\r\n");
    if (std.mem.startsWith(u8, content, "+") and !std.mem.startsWith(u8, content, "+++")) {
        try writeStyledLine(allocator, rendered, line, color, "\x1b[32m");
    } else if (std.mem.startsWith(u8, content, "-") and !std.mem.startsWith(u8, content, "---")) {
        try writeStyledLine(allocator, rendered, line, color, "\x1b[31m");
    } else if (std.mem.startsWith(u8, content, "@@")) {
        try writeHunkHeaderLine(allocator, rendered, line, color);
    } else if (std.mem.startsWith(u8, content, "diff --git ") or
        std.mem.startsWith(u8, content, "index ") or
        std.mem.startsWith(u8, content, "---") or
        std.mem.startsWith(u8, content, "+++"))
    {
        try writeStyledLine(allocator, rendered, line, color, "\x1b[2m");
    } else {
        try rendered.appendSlice(allocator, line);
    }
}

fn writeDiffPrefix(
    allocator: std.mem.Allocator,
    rendered: *std.ArrayList(u8),
    color: bool,
) !void {
    _ = color;
    try rendered.appendSlice(allocator, "    ");
}

fn writeHunkHeaderLine(
    allocator: std.mem.Allocator,
    rendered: *std.ArrayList(u8),
    line: []const u8,
    color: bool,
) !void {
    if (!color) {
        try rendered.appendSlice(allocator, line);
        return;
    }

    const content = std.mem.trimEnd(u8, line, "\r\n");
    const header_end = findHunkHeaderEnd(content) orelse {
        try writeStyledLine(allocator, rendered, line, color, "\x1b[36m");
        return;
    };

    try rendered.appendSlice(allocator, "\x1b[36m");
    try rendered.appendSlice(allocator, line[0..header_end]);
    try rendered.appendSlice(allocator, "\x1b[0m");
    try rendered.appendSlice(allocator, line[header_end..]);
}

fn findHunkHeaderEnd(content: []const u8) ?usize {
    if (!std.mem.startsWith(u8, content, "@@")) return null;
    const second_marker = std.mem.indexOfPos(u8, content, 2, "@@") orelse return null;
    return second_marker + 2;
}

fn writeStyledLine(
    allocator: std.mem.Allocator,
    rendered: *std.ArrayList(u8),
    line: []const u8,
    color: bool,
    style: []const u8,
) !void {
    if (!color) {
        try rendered.appendSlice(allocator, line);
        return;
    }
    try rendered.appendSlice(allocator, style);
    try rendered.appendSlice(allocator, line);
    try rendered.appendSlice(allocator, "\x1b[0m");
}

fn parseRenderFence(content: []const u8) ?RenderFence {
    const indent = leadingSpaces(content);
    if (indent > 3 or indent >= content.len) return null;
    const marker = content[indent];
    if (marker != '`' and marker != '~') return null;

    var count: usize = 0;
    while (indent + count < content.len and content[indent + count] == marker) {
        count += 1;
    }
    if (count < 3) return null;

    return .{
        .marker = marker,
        .count = count,
        .info = std.mem.trim(u8, content[indent + count ..], " \t"),
    };
}

fn isClosingRenderFence(content: []const u8, marker: u8, count: usize) bool {
    const indent = leadingSpaces(content);
    if (indent > 3 or indent >= content.len) return false;
    if (content[indent] != marker) return false;

    var closing_count: usize = 0;
    while (indent + closing_count < content.len and content[indent + closing_count] == marker) {
        closing_count += 1;
    }
    if (closing_count < count) return false;

    const rest = std.mem.trim(u8, content[indent + closing_count ..], " \t");
    return rest.len == 0;
}

fn renderFenceLanguage(info: []const u8) []const u8 {
    var token_iter = std.mem.tokenizeAny(u8, info, " \t\r\n");
    return token_iter.next() orelse "";
}

fn leadingSpaces(content: []const u8) usize {
    var count: usize = 0;
    while (count < content.len and content[count] == ' ') {
        count += 1;
    }
    return count;
}

fn nextLineEnd(source: []const u8, start: usize) usize {
    const newline = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse return source.len;
    return newline + 1;
}

fn shouldColorShowOutput() bool {
    if (std.posix.getenv("NO_COLOR")) |value| {
        return value.len == 0;
    }
    return true;
}

fn showPager() []const u8 {
    if (std.posix.getenv("LATCH_PAGER")) |pager| return pager;
    if (std.posix.getenv("GIT_PAGER")) |pager| return pager;
    if (std.posix.getenv("PAGER")) |pager| return pager;
    return "less -R";
}

fn pagerDisablesPaging(pager: []const u8) bool {
    const trimmed = std.mem.trim(u8, pager, " \t\r\n");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "cat");
}

fn pageShowOutput(allocator: std.mem.Allocator, pager: []const u8, rendered: []const u8) !void {
    var child = std.process.Child.init(&.{ "sh", "-c", pager }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    const stdin = child.stdin.?;
    try stdin.writeAll(rendered);
    stdin.close();
    child.stdin = null;

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }
    return error.PagerFailed;
}

fn runReview(allocator: std.mem.Allocator, args: []const []const u8, diagnostics: *latch.Diagnostic) !void {
    if (args.len == 1 and isHelpFlag(args[0])) {
        try printReviewUsage();
        return;
    }

    var document_path: ?[]const u8 = null;
    var output_json = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            output_json = true;
            continue;
        }
        if (document_path != null) return error.UnexpectedArgument;
        document_path = arg;
    }

    var document = try loadReviewDocument(allocator, document_path, diagnostics);
    defer document.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    if (output_json) {
        try writeReviewsJson(&stdout_writer.interface, document.reviews);
    } else {
        try writeReviewsMarkdown(&stdout_writer.interface, document.reviews);
    }
    try stdout_writer.interface.flush();
}

fn loadApplyDocument(
    allocator: std.mem.Allocator,
    document_path: ?[]const u8,
    diagnostics: *latch.Diagnostic,
) !latch.Document {
    if (document_path) |path| {
        if (std.mem.eql(u8, path, "-")) {
            return loadDocumentFromStdin(allocator, diagnostics, false);
        }
        return latch.loadDocumentFromFileWithDiagnostics(allocator, path, diagnostics);
    }

    const stdin_file = std.fs.File.stdin();
    if (stdin_file.isTty()) return error.MissingDocumentPath;
    return loadDocumentFromStdin(allocator, diagnostics, true);
}

fn loadDocumentFromStdin(
    allocator: std.mem.Allocator,
    diagnostics: *latch.Diagnostic,
    empty_is_missing_path: bool,
) !latch.Document {
    const stdin_file = std.fs.File.stdin();
    const source = try stdin_file.readToEndAlloc(allocator, max_input_bytes);
    errdefer allocator.free(source);

    if (empty_is_missing_path and source.len == 0) return error.MissingDocumentPath;

    return latch.parseDocumentWithDiagnostics(allocator, source, diagnostics);
}

fn loadReviewDocument(
    allocator: std.mem.Allocator,
    document_path: ?[]const u8,
    diagnostics: *latch.Diagnostic,
) !latch.ReviewDocument {
    if (document_path) |path| {
        if (std.mem.eql(u8, path, "-")) {
            return loadReviewDocumentFromStdin(allocator, diagnostics, false);
        }
        return latch.loadReviewDocumentFromFileWithDiagnostics(allocator, path, diagnostics);
    }

    const stdin_file = std.fs.File.stdin();
    if (stdin_file.isTty()) return error.MissingDocumentPath;
    return loadReviewDocumentFromStdin(allocator, diagnostics, true);
}

fn loadReviewDocumentFromStdin(
    allocator: std.mem.Allocator,
    diagnostics: *latch.Diagnostic,
    empty_is_missing_path: bool,
) !latch.ReviewDocument {
    const stdin_file = std.fs.File.stdin();
    const source = try stdin_file.readToEndAlloc(allocator, max_input_bytes);
    errdefer allocator.free(source);

    if (empty_is_missing_path and source.len == 0) return error.MissingDocumentPath;

    return latch.parseReviewDocumentWithDiagnostics(allocator, source, diagnostics);
}

fn runSkill(args: []const []const u8) !void {
    if (args.len == 1 and isHelpFlag(args[0])) {
        try printSkillUsage();
        return;
    }
    if (args.len != 0) return error.UnexpectedArgument;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try writeSkill(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}

fn writeSkill(writer: anytype) !void {
    try writer.writeAll(skill_markdown);
}

fn writeReviewsMarkdown(writer: anytype, reviews: []const latch.Review) !void {
    if (reviews.len == 0) {
        try writer.writeAll("no reviews found\n");
        return;
    }

    try writer.writeAll("# Reviews\n\n");
    for (reviews, 0..) |review, index| {
        if (review.id) |id| {
            try writer.print(
                "## {d}. `{s}` (lines {d}-{d})\n\n",
                .{ index + 1, id, review.start_line, review.end_line },
            );
        } else {
            try writer.print(
                "## {d}. Global review (lines {d}-{d})\n\n",
                .{ index + 1, review.start_line, review.end_line },
            );
        }

        if (review.metadata.len != 0) {
            try writer.writeAll("metadata:\n");
            for (review.metadata) |entry| {
                try writer.print("- {s}: {s}\n", .{ entry.key, entry.value });
            }
            try writer.writeAll("\n");
        }

        if (review.text.len != 0) {
            try writer.writeAll(review.text);
            if (!std.mem.endsWith(u8, review.text, "\n")) {
                try writer.writeAll("\n");
            }
        }
        try writer.writeAll("\n");
    }
}

fn writeReviewsJson(writer: *std.Io.Writer, reviews: []const latch.Review) !void {
    var jw: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try jw.beginObject();
    try jw.objectField("reviews");
    try jw.beginArray();
    for (reviews) |review| {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(review.id);
        try jw.objectField("start_line");
        try jw.write(review.start_line);
        try jw.objectField("end_line");
        try jw.write(review.end_line);
        try jw.objectField("info");
        try jw.write(review.info);
        try jw.objectField("metadata");
        try jw.beginArray();
        for (review.metadata) |entry| {
            try jw.beginObject();
            try jw.objectField("key");
            try jw.write(entry.key);
            try jw.objectField("value");
            try jw.write(entry.value);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.objectField("body");
        try jw.write(review.text);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try writer.writeAll("\n");
}

fn printUsage() !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.writeAll(
        \\Literate patch tooling
        \\
        \\USAGE
        \\  latch <command> [options]
        \\
        \\COMMANDS
        \\  draft    Generate a Latch draft from stdin, a Git spec, or the
        \\           current worktree diff
        \\  apply    Apply executable diff fences from a Latch document
        \\  commit   Create a Git commit from a Latch document
        \\  show     Reconstruct a Latch document from a compact Latch commit
        \\  review   Extract review fences from a Latch document
        \\  skill    Print the checked-in Latch Codex skill
        \\
        \\EXAMPLES
        \\  latch draft -o change.latch.md
        \\  latch draft HEAD~1 -o change.latch.md
        \\  git diff | latch draft -o change.latch.md
        \\  latch apply change.latch.md
        \\  latch commit change.latch.md
        \\  latch show
        \\  latch review change.latch.md
        \\  latch skill
        \\
        \\LEARN MORE
        \\  latch draft --help
        \\  latch apply --help
        \\  latch commit --help
        \\  latch show --help
        \\  latch review --help
        \\  latch skill --help
        \\
    );
    try stderr_writer.interface.flush();
}

fn printDraftUsage() !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.writeAll(
        \\Generate a Latch draft from a diff
        \\
        \\USAGE
        \\  latch draft [git-spec] [-o document.latch.md]
        \\
        \\OPTIONS
        \\  -o, --output <file>   Write the draft to a file instead of stdout
        \\  -h, --help            Show help for draft
        \\
        \\DETAILS
        \\  Reads a unified diff from stdin when piped, otherwise uses
        \\  git-spec or the current worktree diff.
        \\
        \\EXAMPLES
        \\  latch draft
        \\  latch draft -o change.latch.md
        \\  latch draft HEAD~1 -o change.latch.md
        \\  latch draft main..HEAD
        \\  git diff | latch draft -o change.latch.md
        \\
    );
    try stderr_writer.interface.flush();
}

fn printApplyUsage() !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.writeAll(
        \\Apply executable diff fences from a Latch document
        \\
        \\USAGE
        \\  latch apply [--dir path] [document.md|-]
        \\
        \\OPTIONS
        \\  --dir <path>          Apply patches relative to a target directory
        \\  -h, --help            Show help for apply
        \\
        \\DETAILS
        \\  Reads a Latch document from stdin when piped without a path.
        \\  Use '-' as the document path to read stdin explicitly.
        \\
        \\EXAMPLES
        \\  latch apply change.latch.md
        \\  cat change.latch.md | latch apply
        \\  latch apply --dir /tmp/repo -
        \\
    );
    try stderr_writer.interface.flush();
}

fn printCommitUsage() !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.writeAll(
        \\Create a Git commit from a Latch document
        \\
        \\USAGE
        \\  latch commit <document.latch.md>
        \\
        \\OPTIONS
        \\  -h, --help            Show help for commit
        \\
        \\DETAILS
        \\  The document must start with an H1. The H1 text becomes the Git
        \\  commit subject. The commit body stores a compact Latch recipe
        \\  with latch-ref fences; latch show expands those refs back into
        \\  executable diff fences from the commit diff.
        \\
        \\EXAMPLES
        \\  latch commit change.latch.md
        \\
    );
    try stderr_writer.interface.flush();
}

fn printShowUsage() !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.writeAll(
        \\Reconstruct a Latch document from a compact Latch commit
        \\
        \\USAGE
        \\  latch show [commit]
        \\
        \\OPTIONS
        \\  -h, --help            Show help for show
        \\
        \\DETAILS
        \\  Reads latch-ref fences from the commit body, computes the
        \\  canonical parent-to-commit diff, and prints the expanded Latch
        \\  document with executable diff fences. Defaults to HEAD.
        \\  When stdout is a TTY, renders ANSI Markdown/diff output through
        \\  LATCH_PAGER, GIT_PAGER, PAGER, or less -R. Set NO_COLOR to
        \\  disable ANSI color or LATCH_PAGER=cat to skip paging.
        \\
        \\EXAMPLES
        \\  latch show
        \\  latch show HEAD~1
        \\
    );
    try stderr_writer.interface.flush();
}

fn printReviewUsage() !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.writeAll(
        \\Extract review fences from a Latch document
        \\
        \\USAGE
        \\  latch review [--json] [document.md|-]
        \\
        \\OPTIONS
        \\  --json                Write machine-readable JSON
        \\  -h, --help            Show help for review
        \\
        \\DETAILS
        \\  Reads a Latch document from stdin when piped without a path.
        \\  Use '-' as the document path to read stdin explicitly.
        \\  Review fence info strings start with 'review'; id=patch-id
        \\  scopes a comment to a patch.
        \\
        \\EXAMPLES
        \\  latch review change.latch.md
        \\  latch review --json change.latch.md
        \\  cat change.latch.md | latch review
        \\
    );
    try stderr_writer.interface.flush();
}

fn printSkillUsage() !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.writeAll(
        \\Print the checked-in Latch Codex skill
        \\
        \\USAGE
        \\  latch skill
        \\
        \\OPTIONS
        \\  -h, --help            Show help for skill
        \\
        \\DETAILS
        \\  Prints the repository's root SKILL.md to stdout.
        \\
    );
    try stderr_writer.interface.flush();
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn reportError(err: anyerror, diagnostics: *const latch.Diagnostic) !void {
    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

    if (diagnostics.isSet()) {
        try writeDiagnostic(&stderr_writer.interface, diagnostics);
        try stderr_writer.interface.flush();
        return;
    }

    switch (err) {
        error.InvalidCommand => {
            try stderr_writer.interface.writeAll("error: unknown command\n");
            try stderr_writer.interface.flush();
            try printUsage();
            return;
        },
        error.MissingDocumentPath => {
            try stderr_writer.interface.writeAll("error: expected a document path\n");
            try stderr_writer.interface.flush();
            try printUsage();
            return;
        },
        error.MissingOutputPath => {
            try stderr_writer.interface.writeAll("error: -o/--output requires a path\n");
            try stderr_writer.interface.flush();
            try printUsage();
            return;
        },
        error.ConflictingDraftInput => {
            try stderr_writer.interface.writeAll("error: choose stdin or a git-spec, not both\n");
            try stderr_writer.interface.flush();
            try printUsage();
            return;
        },
        error.MissingApplyDir => try stderr_writer.interface.writeAll("error: --dir requires a path\n"),
        error.UnexpectedArgument => try stderr_writer.interface.writeAll("error: unexpected extra argument\n"),
        else => try stderr_writer.interface.print("error: {s}\n", .{@errorName(err)}),
    }
    try stderr_writer.interface.flush();
}

fn writeDiagnostic(writer: anytype, diagnostics: *const latch.Diagnostic) !void {
    switch (diagnostics.kind.?) {
        .no_executable_diffs => try writer.writeAll("error: no executable diff fences found\n"),
        .no_git_diff => try writer.writeAll("error: no git diff found to generate from\n"),
        .invalid_diff => try writer.print(
            "error: invalid unified diff section starting with '{s}'\n",
            .{diagnostics.detail.?},
        ),
        .git_diff_failed => {
            try writer.writeAll("error: failed to collect git diff\n");
            if (diagnostics.detail) |detail| {
                try writer.print("{s}\n", .{detail});
            }
        },
        .duplicate_patch_id => {
            if (diagnostics.start_line) |start_line| {
                try writer.print(
                    "error: duplicate patch id '{s}' at lines {d}-{d}\n",
                    .{ diagnostics.patch_id.?, start_line, diagnostics.end_line.? },
                );
            } else {
                try writer.print("error: duplicate patch id '{s}'\n", .{diagnostics.patch_id.?});
            }
        },
        .unknown_dependency => try writer.print(
            "error: patch '{s}' depends on unknown patch '{s}'\n",
            .{ diagnostics.patch_id.?, diagnostics.related_id.? },
        ),
        .self_dependency => try writer.print(
            "error: patch '{s}' cannot depend on itself\n",
            .{diagnostics.patch_id.?},
        ),
        .dependency_cycle => try writer.print(
            "error: patch dependency cycle detected among: {s}\n",
            .{diagnostics.detail.?},
        ),
        .unsupported_metadata => {
            if (diagnostics.metadata_key) |metadata_key| {
                try writer.print(
                    "error: unsupported diff metadata key '{s}' at lines {d}-{d}\n",
                    .{ metadata_key, diagnostics.start_line.?, diagnostics.end_line.? },
                );
            } else {
                try writer.print(
                    "error: unsupported diff metadata '{s}' at lines {d}-{d}; expected key=value\n",
                    .{ diagnostics.metadata_value.?, diagnostics.start_line.?, diagnostics.end_line.? },
                );
            }
        },
        .missing_patch_id => try writer.print(
            "error: patch at lines {d}-{d} is missing id=...\n",
            .{ diagnostics.start_line.?, diagnostics.end_line.? },
        ),
        .missing_patch_part => {
            if (diagnostics.part) |part| {
                try writer.print(
                    "error: patch '{s}' is missing part={d}\n",
                    .{ diagnostics.patch_id.?, part },
                );
            } else {
                try writer.print(
                    "error: patch '{s}' is split across multiple fences but missing " ++
                        "part=... on at least one fragment\n",
                    .{diagnostics.patch_id.?},
                );
            }
        },
        .invalid_patch_part => {
            if (diagnostics.metadata_value) |value| {
                try writer.print(
                    "error: patch part '{s}' at lines {d}-{d} is not a valid integer\n",
                    .{ value, diagnostics.start_line.?, diagnostics.end_line.? },
                );
            } else if (diagnostics.start_line) |start_line| {
                try writer.print(
                    "error: patch '{s}' has invalid part={d} at lines {d}-{d}\n",
                    .{
                        diagnostics.patch_id orelse "<unknown>",
                        diagnostics.part.?,
                        start_line,
                        diagnostics.end_line.?,
                    },
                );
            } else {
                try writer.print(
                    "error: patch '{s}' has invalid part={d}\n",
                    .{ diagnostics.patch_id orelse "<unknown>", diagnostics.part.? },
                );
            }
        },
        .duplicate_patch_part => try writer.print(
            "error: patch '{s}' repeats part={d} at lines {d}-{d}\n",
            .{ diagnostics.patch_id.?, diagnostics.part.?, diagnostics.start_line.?, diagnostics.end_line.? },
        ),
        .part_dependency_must_be_on_first => try writer.print(
            "error: patch '{s}' part={d} cannot declare depends-on; use part=1\n",
            .{ diagnostics.patch_id.?, diagnostics.part.? },
        ),
        .invalid_review_metadata => try writer.print(
            "error: invalid review metadata '{s}' at lines {d}-{d}; expected key=value\n",
            .{ diagnostics.metadata_value.?, diagnostics.start_line.?, diagnostics.end_line.? },
        ),
        .invalid_review_id => try writer.print(
            "error: review fence at lines {d}-{d} has empty id=...\n",
            .{ diagnostics.start_line.?, diagnostics.end_line.? },
        ),
        .apply_failed => {
            try writer.print(
                "error: apply patch '{s}' failed with exit code {d}\n",
                .{ diagnostics.patch_id.?, diagnostics.exit_code.? },
            );
            if (diagnostics.detail) |detail| {
                try writer.print("{s}\n", .{detail});
            }
        },
        .apply_terminated => {
            try writer.print("error: apply patch '{s}' terminated unexpectedly\n", .{diagnostics.patch_id.?});
            if (diagnostics.detail) |detail| {
                try writer.print("{s}\n", .{detail});
            }
        },
    }
}

test {
    _ = @import("latch.zig");
}

test "skill command prints embedded skill markdown" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try writeSkill(&writer.writer);

    const output = try writer.toOwnedSlice();
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(skill_markdown, output);
}

test "review markdown output lists review metadata and body" {
    const metadata = [_]latch.ReviewMetadata{
        .{ .key = "id", .value = "core" },
        .{ .key = "reviewer", .value = "tim@timculverhouse.com" },
    };
    const reviews = [_]latch.Review{.{
        .id = "core",
        .metadata = &metadata,
        .text = "Please mention the unsupported key.",
        .info = "review id=core reviewer=tim@timculverhouse.com",
        .start_line = 3,
        .end_line = 5,
    }};

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try writeReviewsMarkdown(&writer.writer, &reviews);

    const output = try writer.toOwnedSlice();
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(
        \\# Reviews
        \\
        \\## 1. `core` (lines 3-5)
        \\
        \\metadata:
        \\- id: core
        \\- reviewer: tim@timculverhouse.com
        \\
        \\Please mention the unsupported key.
        \\
        \\
    , output);
}

test "show renderer indents diff blocks without color" {
    const source =
        \\# Title
        \\
        \\```diff id=core
        \\diff --git a/file b/file
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\```
        \\
    ;

    const rendered = try renderShowMarkdown(std.testing.allocator, source, false);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "# Title\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "    ```diff id=core") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "    diff --git a/file b/file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "    -old") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "    ```\n") != null);
}

test "show renderer colors diff lines" {
    const source =
        \\# Title
        \\
        \\```diff id=core
        \\@@ -1 +1 @@ fn main()
        \\-old
        \\+new
        \\```
        \\
    ;

    const rendered = try renderShowMarkdown(std.testing.allocator, source, true);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1;34m# Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "    \x1b[36m@@ -1 +1 @@\x1b[0m fn main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "    \x1b[31m-old") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "    \x1b[32m+new") != null);
}

test "review json output includes reviews array" {
    const metadata = [_]latch.ReviewMetadata{.{ .key = "reviewer", .value = "tim" }};
    const reviews = [_]latch.Review{.{
        .id = null,
        .metadata = &metadata,
        .text = "Start with behavior.",
        .info = "review reviewer=tim",
        .start_line = 1,
        .end_line = 3,
    }};

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try writeReviewsJson(&writer.writer, &reviews);

    const output = try writer.toOwnedSlice();
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"reviews\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Start with behavior.") != null);
}
