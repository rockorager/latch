const std = @import("std");
const ziglint = @import("ziglint");

fn addUucodeImport(
    b: *std.Build,
    root_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "general_category",
            "case_folding_full",
            "grapheme_break",
            "is_emoji_vs_base",
            "lowercase_mapping",
            "uppercase_mapping",
            "wcwidth_standalone",
            "wcwidth_zero_in_grapheme",
        }),
    });
    root_module.addImport("uucode", dep.module("uucode"));
}

fn addSkillOptionsImport(b: *std.Build, root_module: *std.Build.Module) void {
    const skill_markdown = std.fs.cwd().readFileAlloc(b.allocator, "SKILL.md", 1024 * 1024) catch |err| {
        std.debug.panic("failed to read SKILL.md: {s}", .{@errorName(err)});
    };

    const options = b.addOptions();
    options.addOption([]const u8, "skill_markdown", skill_markdown);
    root_module.addOptions("build_options", options);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addUucodeImport(b, exe_module, target, optimize);
    addSkillOptionsImport(b, exe_module);

    const exe = b.addExecutable(.{
        .name = "latch",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addUucodeImport(b, test_module, target, optimize);
    addSkillOptionsImport(b, test_module);
    const exe_tests = b.addTest(.{
        .root_module = test_module,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);

    const lint_step = b.step("lint", "Run ziglint");
    const ziglint_dep = b.dependency("ziglint", .{ .optimize = .ReleaseFast });
    lint_step.dependOn(ziglint.addLint(b, ziglint_dep, &.{ b.path("src"), b.path("build.zig") }));
    test_step.dependOn(lint_step);
}
