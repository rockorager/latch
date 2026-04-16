const std = @import("std");
const builtin = @import("builtin");
const markdown = @import("markdown/parser.zig");

pub const DiagnosticKind = enum {
    no_executable_diffs,
    no_git_diff,
    invalid_diff,
    git_diff_failed,
    duplicate_patch_id,
    unknown_dependency,
    self_dependency,
    dependency_cycle,
    unsupported_metadata,
    missing_patch_id,
    missing_patch_part,
    invalid_patch_part,
    duplicate_patch_part,
    part_dependency_must_be_on_first,
    apply_failed,
    apply_terminated,
};

const DiagnosticFields = struct {
    patch_id: ?[]const u8 = null,
    related_id: ?[]const u8 = null,
    metadata_key: ?[]const u8 = null,
    metadata_value: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    start_line: ?usize = null,
    end_line: ?usize = null,
    part: ?usize = null,
    exit_code: ?u8 = null,
};

pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    kind: ?DiagnosticKind = null,
    patch_id: ?[]const u8 = null,
    related_id: ?[]const u8 = null,
    metadata_key: ?[]const u8 = null,
    metadata_value: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    start_line: ?usize = null,
    end_line: ?usize = null,
    part: ?usize = null,
    exit_code: ?u8 = null,

    pub fn init(allocator: std.mem.Allocator) Diagnostic {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostic) void {
        self.clear();
        self.* = undefined;
    }

    pub fn clear(self: *Diagnostic) void {
        freeOptional(self.allocator, &self.patch_id);
        freeOptional(self.allocator, &self.related_id);
        freeOptional(self.allocator, &self.metadata_key);
        freeOptional(self.allocator, &self.metadata_value);
        freeOptional(self.allocator, &self.detail);
        self.kind = null;
        self.start_line = null;
        self.end_line = null;
        self.part = null;
        self.exit_code = null;
    }

    pub fn isSet(self: *const Diagnostic) bool {
        return self.kind != null;
    }

    fn set(self: *Diagnostic, kind: DiagnosticKind, fields: DiagnosticFields) !void {
        var patch_id = try dupOptionalAlloc(self.allocator, fields.patch_id);
        errdefer freeOptional(self.allocator, &patch_id);
        var related_id = try dupOptionalAlloc(self.allocator, fields.related_id);
        errdefer freeOptional(self.allocator, &related_id);
        var metadata_key = try dupOptionalAlloc(self.allocator, fields.metadata_key);
        errdefer freeOptional(self.allocator, &metadata_key);
        var metadata_value = try dupOptionalAlloc(self.allocator, fields.metadata_value);
        errdefer freeOptional(self.allocator, &metadata_value);
        var detail = try dupOptionalAlloc(self.allocator, fields.detail);
        errdefer freeOptional(self.allocator, &detail);

        self.clear();
        self.kind = kind;
        self.patch_id = patch_id;
        self.related_id = related_id;
        self.metadata_key = metadata_key;
        self.metadata_value = metadata_value;
        self.detail = detail;
        self.start_line = fields.start_line;
        self.end_line = fields.end_line;
        self.part = fields.part;
        self.exit_code = fields.exit_code;
    }

    fn dupOptionalAlloc(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
        if (value) |text| {
            return @as([]const u8, try allocator.dupe(u8, text));
        }
        return null;
    }

    fn freeOptional(allocator: std.mem.Allocator, target: *?[]const u8) void {
        if (target.*) |text| {
            allocator.free(text);
            target.* = null;
        }
    }
};

fn emitDiagnostic(
    comptime format: []const u8,
    args: anytype,
    diagnostics: ?*Diagnostic,
    kind: DiagnosticKind,
    fields: DiagnosticFields,
) !void {
    if (diagnostics) |diagnostic| {
        try diagnostic.set(kind, fields);
        return;
    }
    logError(format, args);
}

pub const Patch = struct {
    id: []const u8,
    depends_on: []const []const u8,
    diff: []const u8,
    info: []const u8,
    start_line: usize,
    end_line: usize,
};

const PatchFragment = struct {
    id: []const u8,
    part: ?usize,
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
            self.allocator.free(patch.diff);
        }
        self.allocator.free(self.patches);
        self.markdown_document.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
    }

    pub fn orderedPatchIndices(self: *const Document, allocator: std.mem.Allocator) ![]usize {
        return self.orderedPatchIndicesWithDiagnostics(allocator, null);
    }

    pub fn orderedPatchIndicesWithDiagnostics(
        self: *const Document,
        allocator: std.mem.Allocator,
        diagnostics: ?*Diagnostic,
    ) ![]usize {
        var id_to_index: std.StringHashMapUnmanaged(usize) = .empty;
        defer id_to_index.deinit(allocator);

        for (self.patches, 0..) |patch, patch_index| {
            if (id_to_index.contains(patch.id)) {
                try emitDiagnostic(
                    "duplicate patch id '{s}' at lines {d}-{d}",
                    .{ patch.id, patch.start_line, patch.end_line },
                    diagnostics,
                    .duplicate_patch_id,
                    .{
                        .patch_id = patch.id,
                        .start_line = patch.start_line,
                        .end_line = patch.end_line,
                    },
                );
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
                    try emitDiagnostic(
                        "patch '{s}' depends on unknown patch '{s}'",
                        .{ patch.id, dep },
                        diagnostics,
                        .unknown_dependency,
                        .{ .patch_id = patch.id, .related_id = dep },
                    );
                    return error.UnknownDependency;
                }
                if (std.mem.eql(u8, patch.id, dep)) {
                    try emitDiagnostic(
                        "patch '{s}' cannot depend on itself",
                        .{patch.id},
                        diagnostics,
                        .self_dependency,
                        .{ .patch_id = patch.id },
                    );
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
            try emitDiagnostic(
                "patch dependency cycle detected among: {s}",
                .{blocked_ids},
                diagnostics,
                .dependency_cycle,
                .{ .detail = blocked_ids },
            );
            return error.DependencyCycle;
        }

        return ordered.toOwnedSlice(allocator);
    }
};

pub fn generateDocumentFromGitDiff(allocator: std.mem.Allocator) ![]u8 {
    return generateDocumentFromGitDiffWithDiagnostics(allocator, null);
}

pub fn generateDocumentFromGitDiffWithDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    const diff = try collectGitWorktreeDiff(allocator, diagnostics);
    defer allocator.free(diff);

    return generateDocumentFromUnifiedDiffWithDiagnostics(allocator, diff, diagnostics);
}

pub fn generateDocumentFromGitSpec(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    return generateDocumentFromGitSpecWithDiagnostics(allocator, spec, null);
}

pub fn generateDocumentFromGitSpecWithDiagnostics(
    allocator: std.mem.Allocator,
    spec: []const u8,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    const diff = try collectGitSpecDiff(allocator, spec, diagnostics);
    defer allocator.free(diff);

    return generateDocumentFromUnifiedDiffWithDiagnostics(allocator, diff, diagnostics);
}

pub fn loadDocumentFromFile(allocator: std.mem.Allocator, path: []const u8) !Document {
    return loadDocumentFromFileWithDiagnostics(allocator, path, null);
}

pub fn loadDocumentFromFileWithDiagnostics(
    allocator: std.mem.Allocator,
    path: []const u8,
    diagnostics: ?*Diagnostic,
) !Document {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    errdefer allocator.free(source);
    return parseDocumentWithDiagnostics(allocator, source, diagnostics);
}

pub fn parseDocument(allocator: std.mem.Allocator, owned_source: []u8) !Document {
    return parseDocumentWithDiagnostics(allocator, owned_source, null);
}

pub fn parseDocumentWithDiagnostics(
    allocator: std.mem.Allocator,
    owned_source: []u8,
    diagnostics: ?*Diagnostic,
) !Document {
    var markdown_document = try markdown.parse(allocator, owned_source);
    errdefer markdown_document.deinit();

    var fragments: std.ArrayList(PatchFragment) = .empty;
    defer {
        for (fragments.items) |fragment| allocator.free(fragment.depends_on);
        fragments.deinit(allocator);
    }

    try collectPatchFragments(allocator, owned_source, markdown_document.children, &fragments, diagnostics);
    if (fragments.items.len == 0) {
        try emitDiagnostic("no executable diff fences found", .{}, diagnostics, .no_executable_diffs, .{});
        return error.NoExecutableDiffs;
    }

    const patches = try assemblePatches(allocator, fragments.items, diagnostics);
    errdefer {
        for (patches) |patch| {
            allocator.free(patch.depends_on);
            allocator.free(patch.diff);
        }
        allocator.free(patches);
    }

    return .{
        .allocator = allocator,
        .source = owned_source,
        .markdown_document = markdown_document,
        .patches = patches,
    };
}

pub fn generateDocumentFromUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) ![]u8 {
    return generateDocumentFromUnifiedDiffWithDiagnostics(allocator, diff, null);
}

pub fn generateDocumentFromUnifiedDiffWithDiagnostics(
    allocator: std.mem.Allocator,
    diff: []const u8,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    const sections = try parseDiffSections(allocator, diff, diagnostics);
    defer freeDiffSections(allocator, sections);

    if (sections.len == 0) {
        try emitDiagnostic("no git diff found to generate from", .{}, diagnostics, .no_git_diff, .{});
        return error.NoGitDiff;
    }

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);

    var seen_patch_ids = std.AutoHashMap(u32, usize).init(allocator);
    defer seen_patch_ids.deinit();

    try builder.writer(allocator).print(
        \\# Draft Latch Document
        \\
        \\Use this file to tell the story of the change. Reorder sections into
        \\narrative order, rewrite the headings and prose, and keep the diff
        \\fences executable.
        \\
        \\Start with the clearest explanation of behavior, whether that is
        \\user-facing code, docs, or tests, then move into the internal
        \\machinery. Leave tests or proof points near the end unless they
        \\best explain the change up front. Keep patch ids stable while
        \\moving sections. Refine dependencies only when the narrative no
        \\longer matches the mechanical order.
        \\
        \\To split one logical patch across multiple diff fences, keep the
        \\same id on each fence and add part=1, part=2, and so on. Latch
        \\concatenates those parts before apply; if needed, put depends-on
        \\only on part=1.
        \\
        \\If the diff does not provide suitable context, bring in additional
        \\code context with appropriate non-diff code fences.
        \\
    , .{});

    for (sections) |section| {
        var section_patch_ids: std.ArrayList([]const u8) = .empty;
        defer {
            for (section_patch_ids.items) |patch_id| {
                allocator.free(patch_id);
            }
            section_patch_ids.deinit(allocator);
        }

        if (section.hunks.len == 0) {
            try section_patch_ids.append(
                allocator,
                try allocateGeneratedPatchId(allocator, section.path, section.body, &seen_patch_ids),
            );
        } else {
            for (section.hunks) |hunk| {
                try section_patch_ids.append(
                    allocator,
                    try allocateGeneratedPatchId(
                        allocator,
                        section.path,
                        generatedPatchIdentityBody(hunk.body),
                        &seen_patch_ids,
                    ),
                );
            }
        }

        try builder.writer(allocator).print(
            \\
            \\## {s}
            \\
            \\This section was generated from `{s}`.
            \\
            \\
        ,
            .{ section.path, section.path },
        );

        if (section.hunks.len == 0) {
            const metadata = try std.fmt.allocPrint(allocator, "id={s}", .{section_patch_ids.items[0]});
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
            const metadata = if (hunk_index == 0)
                try std.fmt.allocPrint(allocator, "id={s}", .{section_patch_ids.items[hunk_index]})
            else
                try std.fmt.allocPrint(
                    allocator,
                    "id={s} depends-on={s}",
                    .{ section_patch_ids.items[hunk_index], section_patch_ids.items[hunk_index - 1] },
                );
            defer allocator.free(metadata);

            try builder.writer(allocator).print(
                \\
                \\### Hunk {d}
                \\
                \\This hunk was generated mechanically from `{s}`.
                \\
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
    return applyPatchesWithDiagnostics(allocator, patches, ordered_indices, target_dir, null);
}

pub fn applyPatchesWithDiagnostics(
    allocator: std.mem.Allocator,
    patches: []const Patch,
    ordered_indices: []const usize,
    target_dir: []const u8,
    diagnostics: ?*Diagnostic,
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
                const detail = if (stderr.items.len != 0) stderr.items else stdout.items;
                try emitDiagnostic(
                    "apply patch '{s}' failed with exit code {d}",
                    .{ patch.id, code },
                    diagnostics,
                    .apply_failed,
                    .{
                        .patch_id = patch.id,
                        .exit_code = @intCast(code),
                        .detail = if (detail.len == 0) null else detail,
                    },
                );
            },
            else => {
                const detail = if (stderr.items.len != 0) stderr.items else stdout.items;
                try emitDiagnostic(
                    "apply patch '{s}' terminated unexpectedly",
                    .{patch.id},
                    diagnostics,
                    .apply_terminated,
                    .{
                        .patch_id = patch.id,
                        .detail = if (detail.len == 0) null else detail,
                    },
                );
            },
        }
        return error.ApplyFailed;
    }
}

fn collectPatchFragments(
    allocator: std.mem.Allocator,
    source: []const u8,
    nodes: []const markdown.Node,
    fragments: *std.ArrayList(PatchFragment),
    diagnostics: ?*Diagnostic,
) !void {
    for (nodes) |node| {
        if (node.kind == .code_block) {
            if (try parsePatchNode(allocator, source, node, diagnostics)) |fragment| {
                try fragments.append(allocator, fragment);
            }
        }
        if (node.children.len != 0) {
            try collectPatchFragments(allocator, source, node.children, fragments, diagnostics);
        }
    }
}

fn assemblePatches(
    allocator: std.mem.Allocator,
    fragments: []const PatchFragment,
    diagnostics: ?*Diagnostic,
) ![]Patch {
    const Group = struct {
        id: []const u8,
        fragment_indices: std.ArrayListUnmanaged(usize) = .empty,
    };

    var groups: std.ArrayList(Group) = .empty;
    defer {
        for (groups.items) |*group| {
            group.fragment_indices.deinit(allocator);
        }
        groups.deinit(allocator);
    }

    var id_to_group: std.StringHashMapUnmanaged(usize) = .empty;
    defer id_to_group.deinit(allocator);

    for (fragments, 0..) |fragment, fragment_index| {
        const gop = try id_to_group.getOrPut(allocator, fragment.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = groups.items.len;
            try groups.append(allocator, .{ .id = fragment.id });
        }
        try groups.items[gop.value_ptr.*].fragment_indices.append(allocator, fragment_index);
    }

    var patches: std.ArrayList(Patch) = .empty;
    defer patches.deinit(allocator);

    for (groups.items) |group| {
        const indices = group.fragment_indices.items;
        const first_fragment = fragments[indices[0]];

        if (indices.len == 1 and first_fragment.part == null) {
            try patches.append(allocator, .{
                .id = first_fragment.id,
                .depends_on = try allocator.dupe([]const u8, first_fragment.depends_on),
                .diff = try allocator.dupe(u8, first_fragment.diff),
                .info = first_fragment.info,
                .start_line = first_fragment.start_line,
                .end_line = first_fragment.end_line,
            });
            continue;
        }

        var any_have_parts = false;
        var all_have_parts = true;
        for (indices) |fragment_index| {
            if (fragments[fragment_index].part) |_| {
                any_have_parts = true;
            } else {
                all_have_parts = false;
            }
        }
        if (!any_have_parts) {
            try emitDiagnostic(
                "duplicate patch id '{s}' appears in multiple diff fences",
                .{group.id},
                diagnostics,
                .duplicate_patch_id,
                .{ .patch_id = group.id },
            );
            return error.DuplicatePatchId;
        }
        if (!all_have_parts) {
            try emitDiagnostic(
                "patch '{s}' is split across multiple fences but missing part=... on at least one fragment",
                .{group.id},
                diagnostics,
                .missing_patch_part,
                .{ .patch_id = group.id },
            );
            return error.MissingPatchPart;
        }

        const count = indices.len;
        const missing_index = std.math.maxInt(usize);
        var ordered_indices = try allocator.alloc(usize, count);
        defer allocator.free(ordered_indices);
        @memset(ordered_indices, missing_index);

        for (indices) |fragment_index| {
            const fragment = fragments[fragment_index];
            const part = fragment.part.?;
            if (part == 0 or part > count) {
                try emitDiagnostic(
                    "patch '{s}' has invalid part={d} at lines {d}-{d}",
                    .{ group.id, part, fragment.start_line, fragment.end_line },
                    diagnostics,
                    .invalid_patch_part,
                    .{
                        .patch_id = group.id,
                        .part = part,
                        .start_line = fragment.start_line,
                        .end_line = fragment.end_line,
                    },
                );
                return error.InvalidPatchPart;
            }
            if (ordered_indices[part - 1] != missing_index) {
                try emitDiagnostic(
                    "patch '{s}' repeats part={d} at lines {d}-{d}",
                    .{ group.id, part, fragment.start_line, fragment.end_line },
                    diagnostics,
                    .duplicate_patch_part,
                    .{
                        .patch_id = group.id,
                        .part = part,
                        .start_line = fragment.start_line,
                        .end_line = fragment.end_line,
                    },
                );
                return error.DuplicatePatchPart;
            }
            ordered_indices[part - 1] = fragment_index;
        }

        for (ordered_indices, 0..) |fragment_index, part_index| {
            if (fragment_index == missing_index) {
                try emitDiagnostic(
                    "patch '{s}' is missing part={d}",
                    .{ group.id, part_index + 1 },
                    diagnostics,
                    .missing_patch_part,
                    .{ .patch_id = group.id, .part = part_index + 1 },
                );
                return error.MissingPatchPart;
            }
            if (part_index != 0 and fragments[fragment_index].depends_on.len != 0) {
                try emitDiagnostic(
                    "patch '{s}' part={d} cannot declare depends-on; use part=1",
                    .{ group.id, part_index + 1 },
                    diagnostics,
                    .part_dependency_must_be_on_first,
                    .{ .patch_id = group.id, .part = part_index + 1 },
                );
                return error.PartDependencyMustBeOnFirst;
            }
        }

        const first_part = fragments[ordered_indices[0]];
        var start_line = first_part.start_line;
        var end_line = first_part.end_line;
        for (ordered_indices[1..]) |fragment_index| {
            const fragment = fragments[fragment_index];
            start_line = @min(start_line, fragment.start_line);
            end_line = @max(end_line, fragment.end_line);
        }
        try patches.append(allocator, .{
            .id = group.id,
            .depends_on = try allocator.dupe([]const u8, first_part.depends_on),
            .diff = try concatenatePatchFragments(allocator, fragments, ordered_indices),
            .info = first_part.info,
            .start_line = start_line,
            .end_line = end_line,
        });
    }

    return patches.toOwnedSlice(allocator);
}

fn concatenatePatchFragments(
    allocator: std.mem.Allocator,
    fragments: []const PatchFragment,
    ordered_indices: []const usize,
) ![]u8 {
    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);

    for (ordered_indices, 0..) |fragment_index, ordered_index| {
        const fragment = fragments[fragment_index];
        try builder.appendSlice(allocator, fragment.diff);
        if (ordered_index + 1 < ordered_indices.len and !std.mem.endsWith(u8, fragment.diff, "\n")) {
            try builder.append(allocator, '\n');
        }
    }

    return builder.toOwnedSlice(allocator);
}

fn collectGitWorktreeDiff(allocator: std.mem.Allocator, diagnostics: ?*Diagnostic) ![]u8 {
    return runGitForDiff(allocator, &.{ "git", "diff", "--no-ext-diff", "HEAD" }, diagnostics);
}

fn collectGitSpecDiff(allocator: std.mem.Allocator, spec: []const u8, diagnostics: ?*Diagnostic) ![]u8 {
    if (looksLikeRevisionRange(spec)) {
        return runGitForDiff(allocator, &.{ "git", "diff", "--no-ext-diff", spec }, diagnostics);
    }
    return runGitForDiff(allocator, &.{ "git", "show", "--format=", "--no-ext-diff", spec }, diagnostics);
}

fn runGitForDiff(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    diagnostics: ?*Diagnostic,
) ![]u8 {
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

    try emitDiagnostic(
        "{s}",
        .{result.stderr},
        diagnostics,
        .git_diff_failed,
        .{ .detail = if (result.stderr.len == 0) null else result.stderr },
    );
    allocator.free(result.stdout);
    return error.GitDiffFailed;
}

fn looksLikeRevisionRange(spec: []const u8) bool {
    return std.mem.indexOf(u8, spec, "..") != null;
}

fn parseDiffSections(
    allocator: std.mem.Allocator,
    diff: []const u8,
    diagnostics: ?*Diagnostic,
) ![]DiffSection {
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
                try sections.append(allocator, try parseDiffSection(allocator, diff[start..line_start], diagnostics));
            }
            current_start = line_start;
        }
        line_start = line_end;
    }

    if (current_start) |start| {
        try sections.append(allocator, try parseDiffSection(allocator, diff[start..], diagnostics));
    }

    return sections.toOwnedSlice(allocator);
}

fn freeDiffSections(allocator: std.mem.Allocator, sections: []DiffSection) void {
    for (sections) |section| {
        allocator.free(section.hunks);
    }
    allocator.free(sections);
}

fn parseDiffSection(
    allocator: std.mem.Allocator,
    section: []const u8,
    diagnostics: ?*Diagnostic,
) !DiffSection {
    const path = parseSectionPath(section) orelse {
        const first_line_end = std.mem.indexOfScalar(u8, section, '\n') orelse section.len;
        const first_line = std.mem.trimEnd(u8, section[0..first_line_end], "\r");
        try emitDiagnostic(
            "invalid unified diff section starting with '{s}'",
            .{first_line},
            diagnostics,
            .invalid_diff,
            .{ .detail = first_line },
        );
        return error.InvalidDiff;
    };

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

fn allocateGeneratedPatchId(
    allocator: std.mem.Allocator,
    path: []const u8,
    diff_body: []const u8,
    seen_patch_ids: *std.AutoHashMap(u32, usize),
) ![]u8 {
    const hash = hashGeneratedPatch(path, diff_body);
    const gop = try seen_patch_ids.getOrPut(hash);
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
        return std.fmt.allocPrint(allocator, "{x:0>8}", .{hash});
    }

    gop.value_ptr.* += 1;
    return std.fmt.allocPrint(allocator, "{x:0>8}-{d}", .{ hash, gop.value_ptr.* });
}

fn hashGeneratedPatch(path: []const u8, diff_body: []const u8) u32 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    hasher.update("\n");
    hasher.update(diff_body);
    return @truncate(hasher.final());
}

fn generatedPatchIdentityBody(diff_body: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, diff_body, "@@ ")) return diff_body;
    const first_line_end = nextLineEnd(diff_body, 0);
    return diff_body[@min(first_line_end, diff_body.len)..];
}

fn parsePatchNode(
    allocator: std.mem.Allocator,
    source: []const u8,
    node: markdown.Node,
    diagnostics: ?*Diagnostic,
) !?PatchFragment {
    var token_iter = std.mem.tokenizeAny(u8, node.info, " \t\r\n");
    const language = token_iter.next() orelse return null;
    if (!std.mem.eql(u8, language, "diff")) return null;

    const span_start: usize = @intCast(node.span_start);
    const span_end: usize = @intCast(node.span_end);
    const start_line = lineNumberForOffset(source, span_start);
    const end_line = lineNumberForOffset(source, if (span_end == 0) 0 else span_end - 1);

    var id: ?[]const u8 = null;
    var part: ?usize = null;
    var depends_on: std.ArrayList([]const u8) = .empty;
    defer depends_on.deinit(allocator);

    while (token_iter.next()) |token| {
        const eq_index = std.mem.indexOfScalar(u8, token, '=') orelse {
            try emitDiagnostic(
                "unsupported diff metadata '{s}' at lines {d}-{d}; expected key=value",
                .{ token, start_line, end_line },
                diagnostics,
                .unsupported_metadata,
                .{
                    .metadata_value = token,
                    .start_line = start_line,
                    .end_line = end_line,
                },
            );
            return error.UnsupportedMetadata;
        };

        const key = token[0..eq_index];
        const value = token[eq_index + 1 ..];
        if (std.mem.eql(u8, key, "id")) {
            id = value;
            continue;
        }
        if (std.mem.eql(u8, key, "part")) {
            part = std.fmt.parseInt(usize, value, 10) catch {
                try emitDiagnostic(
                    "patch part '{s}' at lines {d}-{d} is not a valid integer",
                    .{ value, start_line, end_line },
                    diagnostics,
                    .invalid_patch_part,
                    .{
                        .patch_id = id,
                        .metadata_value = value,
                        .start_line = start_line,
                        .end_line = end_line,
                    },
                );
                return error.InvalidPatchPart;
            };
            if (part.? == 0) {
                try emitDiagnostic(
                    "patch at lines {d}-{d} has invalid part=0",
                    .{ start_line, end_line },
                    diagnostics,
                    .invalid_patch_part,
                    .{
                        .patch_id = id,
                        .part = 0,
                        .start_line = start_line,
                        .end_line = end_line,
                    },
                );
                return error.InvalidPatchPart;
            }
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

        try emitDiagnostic(
            "unsupported diff metadata key '{s}' at lines {d}-{d}",
            .{ key, start_line, end_line },
            diagnostics,
            .unsupported_metadata,
            .{
                .metadata_key = key,
                .metadata_value = value,
                .start_line = start_line,
                .end_line = end_line,
            },
        );
        return error.UnsupportedMetadata;
    }

    if (id == null or id.?.len == 0) {
        try emitDiagnostic(
            "patch at lines {d}-{d} is missing id=...",
            .{ start_line, end_line },
            diagnostics,
            .missing_patch_id,
            .{ .start_line = start_line, .end_line = end_line },
        );
        return error.MissingPatchId;
    }

    return .{
        .id = id.?,
        .part = part,
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

test "combines split patch parts into one executable patch" {
    const source =
        \\# Split patch
        \\
        \\```diff id=core part=2
        \\+hello world
        \\```
        \\
        \\Some explanation in between.
        \\
        \\```diff id=core part=1 depends-on=setup
        \\diff --git a/example.txt b/example.txt
        \\--- a/example.txt
        \\+++ b/example.txt
        \\@@ -1 +1 @@
        \\-hello
        \\```
        \\
        \\```diff id=setup
        \\diff --git a/example.txt b/example.txt
        \\--- a/example.txt
        \\+++ b/example.txt
        \\@@ -0,0 +1 @@
        \\+hello
        \\```
        \\
    ;

    const owned = try std.testing.allocator.dupe(u8, source);
    var document = try parseDocument(std.testing.allocator, owned);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.patches.len);
    try std.testing.expectEqualStrings("core", document.patches[0].id);
    try std.testing.expectEqual(@as(usize, 1), document.patches[0].depends_on.len);
    try std.testing.expectEqualStrings("setup", document.patches[0].depends_on[0]);
    try std.testing.expectEqualStrings(
        \\diff --git a/example.txt b/example.txt
        \\--- a/example.txt
        \\+++ b/example.txt
        \\@@ -1 +1 @@
        \\-hello
        \\+hello world
    ,
        document.patches[0].diff,
    );
}

test "rejects depends-on on non-first split part" {
    const source =
        \\```diff id=core part=1
        \\diff --git a/example.txt b/example.txt
        \\--- a/example.txt
        \\+++ b/example.txt
        \\@@ -1 +1 @@
        \\-hello
        \\```
        \\
        \\```diff id=core part=2 depends-on=setup
        \\+hello world
        \\```
        \\
    ;

    const owned = try std.testing.allocator.dupe(u8, source);
    try std.testing.expectError(error.PartDependencyMustBeOnFirst, parseDocument(std.testing.allocator, owned));
    std.testing.allocator.free(owned);
}

test "records diagnostic for split patch dependency error" {
    const source =
        \\```diff id=core part=1
        \\diff --git a/example.txt b/example.txt
        \\--- a/example.txt
        \\+++ b/example.txt
        \\@@ -1 +1 @@
        \\-hello
        \\```
        \\
        \\```diff id=core part=2 depends-on=setup
        \\+hello world
        \\```
        \\
    ;

    const owned = try std.testing.allocator.dupe(u8, source);
    var diagnostics = Diagnostic.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(
        error.PartDependencyMustBeOnFirst,
        parseDocumentWithDiagnostics(std.testing.allocator, owned, &diagnostics),
    );
    std.testing.allocator.free(owned);

    try std.testing.expectEqual(DiagnosticKind.part_dependency_must_be_on_first, diagnostics.kind.?);
    try std.testing.expectEqualStrings("core", diagnostics.patch_id.?);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.part.?);
}

test "records diagnostic for invalid unified diff" {
    const diff =
        \\diff --git broken
        \\@@ -1 +1 @@
        \\-hello
        \\+hello world
        \\
    ;

    var diagnostics = Diagnostic.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(
        error.InvalidDiff,
        generateDocumentFromUnifiedDiffWithDiagnostics(std.testing.allocator, diff, &diagnostics),
    );

    try std.testing.expectEqual(DiagnosticKind.invalid_diff, diagnostics.kind.?);
    try std.testing.expectEqualStrings("diff --git broken", diagnostics.detail.?);
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

    const owned = try std.testing.allocator.dupe(u8, generated);
    var document = try parseDocument(std.testing.allocator, owned);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 3), document.patches.len);
    try std.testing.expectEqual(@as(usize, 0), document.patches[0].depends_on.len);
    try std.testing.expectEqual(@as(usize, 1), document.patches[1].depends_on.len);
    try std.testing.expectEqual(@as(usize, 0), document.patches[2].depends_on.len);
    try std.testing.expectEqualStrings(document.patches[0].id, document.patches[1].depends_on[0]);
    try std.testing.expectEqual(@as(usize, 8), document.patches[0].id.len);
    try std.testing.expectEqual(@as(usize, 8), document.patches[1].id.len);
    try std.testing.expectEqual(@as(usize, 8), document.patches[2].id.len);
    try std.testing.expect(std.mem.indexOf(u8, generated, "```diff id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "````diff id=") != null);
}

test "detects git revision ranges" {
    try std.testing.expect(looksLikeRevisionRange("HEAD~2..HEAD"));
    try std.testing.expect(looksLikeRevisionRange("main...feature"));
    try std.testing.expect(!looksLikeRevisionRange("HEAD~2"));
    try std.testing.expect(!looksLikeRevisionRange("feature-branch"));
}

test "disambiguates duplicate generated patch ids" {
    const diff =
        \\diff --git a/example.txt b/example.txt
        \\index 1111111..2222222 100644
        \\--- a/example.txt
        \\+++ b/example.txt
        \\@@ -1 +1 @@
        \\-hello
        \\+hello world
        \\@@ -10 +10 @@
        \\-hello
        \\+hello world
        \\
    ;

    const generated = try generateDocumentFromUnifiedDiff(std.testing.allocator, diff);
    defer std.testing.allocator.free(generated);

    const owned = try std.testing.allocator.dupe(u8, generated);
    var document = try parseDocument(std.testing.allocator, owned);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.patches.len);
    try std.testing.expectEqual(@as(usize, 1), document.patches[1].depends_on.len);
    try std.testing.expectEqualStrings(document.patches[0].id, document.patches[1].depends_on[0]);
    try std.testing.expectEqual(@as(usize, 8), document.patches[0].id.len);
    try std.testing.expect(std.mem.startsWith(u8, document.patches[1].id, document.patches[0].id));
    try std.testing.expect(std.mem.endsWith(u8, document.patches[1].id, "-2"));
}
