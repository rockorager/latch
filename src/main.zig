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

    if (std.mem.eql(u8, args[1], "generate")) {
        try runGenerate(allocator, args[2..]);
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

fn runGenerate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) return error.MissingOutputPath;

    const output_path = args[0];
    const generated = try latch.generateDocumentFromGitDiff(allocator);
    defer allocator.free(generated);

    try std.fs.cwd().writeFile(.{
        .sub_path = output_path,
        .data = generated,
    });

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("generated {s}\n", .{output_path});
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
    try stderr_writer.interface.writeAll("latch: literate patch proof of concept\n\n");
    try stderr_writer.interface.writeAll("usage:\n");
    try stderr_writer.interface.writeAll("  latch generate <document.latch.md>\n");
    try stderr_writer.interface.writeAll("  latch apply [--dir path] <document.md>\n");
    try stderr_writer.interface.flush();
}

fn reportError(err: anyerror) !void {
    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

    switch (err) {
        error.InvalidCommand => {
            try stderr_writer.interface.writeAll("error: unknown command\n");
            try printUsage();
            return;
        },
        error.MissingDocumentPath => {
            try stderr_writer.interface.writeAll("error: expected a document path\n");
            try printUsage();
            return;
        },
        error.MissingOutputPath => {
            try stderr_writer.interface.writeAll("error: expected an output path\n");
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
