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
        \\  skill    Print the checked-in Latch Codex skill
        \\
        \\EXAMPLES
        \\  latch draft -o change.latch.md
        \\  latch draft HEAD~1 -o change.latch.md
        \\  git diff | latch draft -o change.latch.md
        \\  latch apply change.latch.md
        \\  latch skill
        \\
        \\LEARN MORE
        \\  latch draft --help
        \\  latch apply --help
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
