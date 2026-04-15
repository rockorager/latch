const std = @import("std");
const latch = @import("latch.zig");

pub fn main() void {
    run() catch |err| {
        reportError(err) catch |report_err| {
            std.debug.panic("failed to report error: {s}", .{@errorName(report_err)});
        };
        std.process.exit(1);
    };
}

fn run() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "plan")) {
        try runPlan(allocator, args[2..]);
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

fn runPlan(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) return error.MissingDocumentPath;

    var document = try latch.loadDocumentFromFile(allocator, args[0]);
    defer document.deinit();

    const ordered = try document.orderedPatchIndices(allocator);
    defer allocator.free(ordered);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("document: {s}\n", .{args[0]});
    try stdout_writer.interface.print("patches: {d}\n", .{document.patches.len});
    try stdout_writer.interface.writeAll("apply order:\n");
    for (ordered, 0..) |patch_index, order_index| {
        const patch = document.patches[patch_index];
        if (patch.depends_on.len == 0) {
            try stdout_writer.interface.print(
                "  {d}. {s} (depends-on: -, lines: {d}-{d})\n",
                .{ order_index + 1, patch.id, patch.start_line, patch.end_line },
            );
            continue;
        }

        const deps = try std.mem.join(allocator, ",", patch.depends_on);
        defer allocator.free(deps);
        try stdout_writer.interface.print(
            "  {d}. {s} (depends-on: {s}, lines: {d}-{d})\n",
            .{ order_index + 1, patch.id, deps, patch.start_line, patch.end_line },
        );
    }
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
    try stderr_writer.interface.writeAll("  latch plan <document.md>\n");
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
        error.MissingApplyDir => try stderr_writer.interface.writeAll("error: --dir requires a path\n"),
        error.UnexpectedArgument => try stderr_writer.interface.writeAll("error: unexpected extra argument\n"),
        else => try stderr_writer.interface.print("error: {s}\n", .{@errorName(err)}),
    }
    try stderr_writer.interface.flush();
}

test {
    _ = @import("latch.zig");
}
