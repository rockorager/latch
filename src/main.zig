const std = @import("std");
const builtin = @import("builtin");
const latch = @import("latch.zig");

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

    run(allocator) catch |err| {
        reportError(err) catch |report_err| {
            std.debug.panic("failed to report error: {s}", .{@errorName(report_err)});
        };
        std.process.exit(1);
    };
}

fn run(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "draft")) {
        try runDraft(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "apply")) {
        try runApply(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        try printUsage();
        return;
    }

    try printUsage();
    return error.InvalidCommand;
}

fn runDraft(allocator: std.mem.Allocator, args: []const []const u8) !void {
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
        const data = try stdin_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
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
            break :generated try latch.generateDocumentFromUnifiedDiff(allocator, diff);
        }
        if (git_spec) |spec| {
            break :generated try latch.generateDocumentFromGitSpec(allocator, spec);
        }
        break :generated try latch.generateDocumentFromGitDiff(allocator);
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

fn runApply(allocator: std.mem.Allocator, args: []const []const u8) !void {
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

    const path = document_path orelse return error.MissingDocumentPath;

    var document = try latch.loadDocumentFromFile(allocator, path);
    defer document.deinit();

    const ordered = try document.orderedPatchIndices(allocator);
    defer allocator.free(ordered);

    try latch.applyPatches(allocator, document.patches, ordered, target_dir);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("applied {d} patches to {s}\n", .{ ordered.len, target_dir });
    try stdout_writer.interface.flush();
}

fn printUsage() !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.writeAll(
        \\latch: literate patch tooling
        \\
        \\usage:
        \\  latch draft [git-spec] [-o document.latch.md]
        \\  latch apply [--dir path] <document.md>
        \\
        \\draft reads a unified diff from stdin when piped, otherwise uses
        \\git-spec or the current worktree diff.
        \\
    );
    try stderr_writer.interface.flush();
}

fn reportError(err: anyerror) !void {
    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

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

test {
    _ = @import("latch.zig");
}
