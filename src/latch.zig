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
    invalid_review_metadata,
    invalid_review_id,
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

pub const ReviewMetadata = struct {
    key: []const u8,
    value: []const u8,
};

pub const Review = struct {
    id: ?[]const u8,
    metadata: []const ReviewMetadata,
    text: []const u8,
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
    additions: usize,
    deletions: usize,
    kind: FileChangeKind,
};

const HunkSection = struct {
    body: []const u8,
};

const FileChangeKind = enum {
    modified,
    created,
    deleted,
};

const DiffLineStats = struct {
    additions: usize = 0,
    deletions: usize = 0,
    kind: FileChangeKind = .modified,
};

const CanonicalDiffBlock = struct {
    text: []const u8,
};

const DiffLineRef = struct {
    block_index: usize,
    line_index: usize,
    text: []const u8,
};

const LineRange = struct {
    block_index: usize,
    start_line: usize,
    end_line: usize,
};

const InitialHeading = struct {
    subject: []const u8,
    body_start: usize,
};

const PathEntry = struct {
    section: *const DiffSection,
    segments: []const []const u8,
};

const TreeLayout = struct {
    max_label_width: usize = 0,
    max_add_digits: usize = 1,
    max_del_digits: usize = 1,
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

pub const ReviewDocument = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    markdown_document: markdown.Document,
    reviews: []Review,

    pub fn deinit(self: *ReviewDocument) void {
        freeReviews(self.allocator, self.reviews);
        self.markdown_document.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
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

pub fn commitDocumentFromFileWithDiagnostics(
    allocator: std.mem.Allocator,
    path: []const u8,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    var document = try loadDocumentFromFileWithDiagnostics(allocator, path, diagnostics);
    defer document.deinit();

    return commitDocumentWithDiagnostics(allocator, &document, diagnostics);
}

pub fn showCommitWithDiagnostics(
    allocator: std.mem.Allocator,
    commit: []const u8,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    const subject = try runGitCapture(
        allocator,
        &.{ "git", "log", "-1", "--format=%s", commit },
        null,
        diagnostics,
    );
    defer allocator.free(subject);

    const body = try runGitCapture(
        allocator,
        &.{ "git", "log", "-1", "--format=%b", commit },
        null,
        diagnostics,
    );
    defer allocator.free(body);

    const parent_spec = try std.fmt.allocPrint(allocator, "{s}^", .{commit});
    defer allocator.free(parent_spec);
    const parent = try runGitCapture(
        allocator,
        &.{ "git", "rev-parse", parent_spec },
        null,
        diagnostics,
    );
    defer allocator.free(parent);

    const trimmed_parent = std.mem.trimEnd(u8, parent, "\r\n");
    const diff = try collectCanonicalCommitDiff(allocator, trimmed_parent, commit, diagnostics);
    defer allocator.free(diff);

    const blocks = try canonicalDiffBlocksFromDiff(allocator, diff, diagnostics);
    defer freeCanonicalDiffBlocks(allocator, blocks);

    var compact_source: std.ArrayList(u8) = .empty;
    defer compact_source.deinit(allocator);
    const trimmed_subject = std.mem.trimEnd(u8, subject, "\r\n");
    try compact_source.writer(allocator).print("# {s}\n\n", .{trimmed_subject});
    try compact_source.appendSlice(allocator, body);
    const owned_source = try compact_source.toOwnedSlice(allocator);
    defer allocator.free(owned_source);

    return expandCompactRecipeWithBlocks(allocator, owned_source, blocks, diagnostics);
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

pub fn loadReviewDocumentFromFile(allocator: std.mem.Allocator, path: []const u8) !ReviewDocument {
    return loadReviewDocumentFromFileWithDiagnostics(allocator, path, null);
}

pub fn loadReviewDocumentFromFileWithDiagnostics(
    allocator: std.mem.Allocator,
    path: []const u8,
    diagnostics: ?*Diagnostic,
) !ReviewDocument {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    errdefer allocator.free(source);
    return parseReviewDocumentWithDiagnostics(allocator, source, diagnostics);
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

pub fn parseReviewDocument(allocator: std.mem.Allocator, owned_source: []u8) !ReviewDocument {
    return parseReviewDocumentWithDiagnostics(allocator, owned_source, null);
}

pub fn parseReviewDocumentWithDiagnostics(
    allocator: std.mem.Allocator,
    owned_source: []u8,
    diagnostics: ?*Diagnostic,
) !ReviewDocument {
    var markdown_document = try markdown.parse(allocator, owned_source);
    errdefer markdown_document.deinit();

    var reviews: std.ArrayList(Review) = .empty;
    errdefer {
        freeReviewMetadata(allocator, reviews.items);
        reviews.deinit(allocator);
    }

    try collectReviewFences(allocator, owned_source, markdown_document.children, &reviews, diagnostics);
    const owned_reviews = try reviews.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .source = owned_source,
        .markdown_document = markdown_document,
        .reviews = owned_reviews,
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

    try writeGeneratedTreeOverview(allocator, &builder, sections);

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

fn commitDocumentWithDiagnostics(
    allocator: std.mem.Allocator,
    document: *const Document,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    const heading = parseInitialHeading(document.source) orelse return error.MissingLatchHeading;

    const ordered = try document.orderedPatchIndicesWithDiagnostics(allocator, diagnostics);
    defer allocator.free(ordered);

    try ensureCleanWorktree(allocator);

    const temp_dir_raw = try runGitCapture(
        allocator,
        &.{ "git", "rev-parse", "--git-path", "latch-tmp" },
        null,
        diagnostics,
    );
    defer allocator.free(temp_dir_raw);
    const temp_dir = std.mem.trimEnd(u8, temp_dir_raw, "\r\n");
    try std.fs.cwd().makePath(temp_dir);

    const nonce = std.crypto.random.int(u64);
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index-{x}", .{ temp_dir, nonce });
    defer allocator.free(index_path);
    defer std.fs.cwd().deleteFile(index_path) catch {};

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("GIT_INDEX_FILE", index_path);

    const read_tree_output = try runGitCapture(allocator, &.{ "git", "read-tree", "HEAD" }, &env_map, diagnostics);
    allocator.free(read_tree_output);

    try applyPatchesToIndexWithDiagnostics(allocator, document.patches, ordered, &env_map, diagnostics);

    const diff = try collectCanonicalIndexDiff(allocator, &env_map, diagnostics);
    defer allocator.free(diff);
    const blocks = try canonicalDiffBlocksFromDiff(allocator, diff, diagnostics);
    defer freeCanonicalDiffBlocks(allocator, blocks);

    const compact_body = try compactDocumentBodyWithBlocks(
        allocator,
        document.source,
        heading.body_start,
        blocks,
        diagnostics,
    );
    defer allocator.free(compact_body);

    const tree = try runGitCapture(allocator, &.{ "git", "write-tree" }, &env_map, diagnostics);
    defer allocator.free(tree);
    const trimmed_tree = std.mem.trimEnd(u8, tree, "\r\n");

    const message_path = try std.fmt.allocPrint(allocator, "{s}/message-{x}", .{ temp_dir, nonce });
    defer allocator.free(message_path);
    defer std.fs.cwd().deleteFile(message_path) catch {};

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);
    try message.writer(allocator).print("{s}\n\n", .{heading.subject});
    try message.appendSlice(allocator, compact_body);
    if (!std.mem.endsWith(u8, compact_body, "\n")) {
        try message.append(allocator, '\n');
    }
    try std.fs.cwd().writeFile(.{ .sub_path = message_path, .data = message.items });

    const commit_id = try runGitCapture(
        allocator,
        &.{ "git", "commit-tree", trimmed_tree, "-p", "HEAD", "-F", message_path },
        null,
        diagnostics,
    );
    errdefer allocator.free(commit_id);
    const trimmed_commit = std.mem.trimEnd(u8, commit_id, "\r\n");
    const update_output = try runGitCapture(
        allocator,
        &.{ "git", "update-ref", "HEAD", trimmed_commit },
        null,
        diagnostics,
    );
    allocator.free(update_output);

    const reset_output = try runGitCapture(allocator, &.{ "git", "reset", "--hard", "HEAD" }, null, diagnostics);
    allocator.free(reset_output);

    return commit_id;
}

fn applyPatchesToIndexWithDiagnostics(
    allocator: std.mem.Allocator,
    patches: []const Patch,
    ordered_indices: []const usize,
    env_map: *const std.process.EnvMap,
    diagnostics: ?*Diagnostic,
) !void {
    for (ordered_indices) |patch_index| {
        const patch = patches[patch_index];
        try runGitWithInputForPatch(
            allocator,
            &.{ "git", "apply", "--cached", "--unsafe-paths", "-" },
            env_map,
            patch,
            diagnostics,
        );
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

fn collectReviewFences(
    allocator: std.mem.Allocator,
    source: []const u8,
    nodes: []const markdown.Node,
    reviews: *std.ArrayList(Review),
    diagnostics: ?*Diagnostic,
) !void {
    for (nodes) |node| {
        if (node.kind == .code_block) {
            if (try parseReviewNode(allocator, source, node, diagnostics)) |review| {
                errdefer allocator.free(review.metadata);
                try reviews.append(allocator, review);
            }
        }
        if (node.children.len != 0) {
            try collectReviewFences(allocator, source, node.children, reviews, diagnostics);
        }
    }
}

fn freeReviewMetadata(allocator: std.mem.Allocator, reviews: []const Review) void {
    for (reviews) |review| {
        allocator.free(review.metadata);
    }
}

fn freeReviews(allocator: std.mem.Allocator, reviews: []const Review) void {
    freeReviewMetadata(allocator, reviews);
    allocator.free(reviews);
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
    return runGitForDiff(
        allocator,
        &.{
            "git",
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--no-renames",
            "--diff-algorithm=histogram",
            "--no-indent-heuristic",
            "--unified=3",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            "HEAD",
        },
        diagnostics,
    );
}

fn collectGitSpecDiff(allocator: std.mem.Allocator, spec: []const u8, diagnostics: ?*Diagnostic) ![]u8 {
    if (looksLikeRevisionRange(spec)) {
        return runGitForDiff(
            allocator,
            &.{
                "git",
                "diff",
                "--no-ext-diff",
                "--no-color",
                "--no-renames",
                "--diff-algorithm=histogram",
                "--no-indent-heuristic",
                "--unified=3",
                "--src-prefix=a/",
                "--dst-prefix=b/",
                spec,
            },
            diagnostics,
        );
    }
    return runGitForDiff(
        allocator,
        &.{
            "git",
            "show",
            "--format=",
            "--no-ext-diff",
            "--no-color",
            "--no-renames",
            "--diff-algorithm=histogram",
            "--no-indent-heuristic",
            "--unified=3",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            spec,
        },
        diagnostics,
    );
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

fn collectCanonicalIndexDiff(
    allocator: std.mem.Allocator,
    env_map: *const std.process.EnvMap,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    return runGitCapture(
        allocator,
        &.{
            "git",
            "diff",
            "--cached",
            "--no-ext-diff",
            "--no-color",
            "--no-renames",
            "--diff-algorithm=histogram",
            "--no-indent-heuristic",
            "--unified=3",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            "HEAD",
        },
        env_map,
        diagnostics,
    );
}

fn collectCanonicalCommitDiff(
    allocator: std.mem.Allocator,
    parent: []const u8,
    commit: []const u8,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    return runGitCapture(
        allocator,
        &.{
            "git",
            "diff-tree",
            "-p",
            "-r",
            "--no-commit-id",
            "--no-ext-diff",
            "--no-color",
            "--no-renames",
            "--diff-algorithm=histogram",
            "--no-indent-heuristic",
            "--unified=3",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            parent,
            commit,
        },
        null,
        diagnostics,
    );
}

fn ensureCleanWorktree(allocator: std.mem.Allocator) !void {
    const unstaged = try runGitExitCode(
        allocator,
        &.{ "git", "diff", "--quiet", "--no-ext-diff", "HEAD", "--" },
        null,
    );
    const staged = try runGitExitCode(
        allocator,
        &.{ "git", "diff", "--cached", "--quiet", "--no-ext-diff", "HEAD", "--" },
        null,
    );
    if (unstaged != 0 or staged != 0) return error.WorktreeNotClean;
}

fn runGitExitCode(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: ?*const std.process.EnvMap,
) !u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .env_map = env_map,
        .max_output_bytes = 128 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| return @intCast(code),
        else => return error.GitDiffFailed,
    }
}

fn runGitCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: ?*const std.process.EnvMap,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .env_map = env_map,
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

fn runGitWithInputForPatch(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: *const std.process.EnvMap,
    patch: Patch,
    diagnostics: ?*Diagnostic,
) !void {
    var child = std.process.Child.init(argv, allocator);
    child.env_map = env_map;
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
            if (code == 0) return;
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

fn canonicalDiffBlocksFromDiff(
    allocator: std.mem.Allocator,
    diff: []const u8,
    diagnostics: ?*Diagnostic,
) ![]CanonicalDiffBlock {
    const sections = try parseDiffSections(allocator, diff, diagnostics);
    defer freeDiffSections(allocator, sections);

    var blocks: std.ArrayList(CanonicalDiffBlock) = .empty;
    errdefer {
        for (blocks.items) |block| {
            allocator.free(block.text);
        }
        blocks.deinit(allocator);
    }

    for (sections) |section| {
        if (section.hunks.len == 0) {
            try blocks.append(allocator, .{ .text = try allocator.dupe(u8, section.body) });
            continue;
        }
        for (section.hunks) |hunk| {
            var block: std.ArrayList(u8) = .empty;
            defer block.deinit(allocator);
            try block.appendSlice(allocator, section.prelude);
            try block.appendSlice(allocator, hunk.body);
            try blocks.append(allocator, .{ .text = try block.toOwnedSlice(allocator) });
        }
    }

    return blocks.toOwnedSlice(allocator);
}

fn freeCanonicalDiffBlocks(allocator: std.mem.Allocator, blocks: []const CanonicalDiffBlock) void {
    for (blocks) |block| {
        allocator.free(block.text);
    }
    allocator.free(blocks);
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
        const stats = countDiffLineStats(section);
        return .{
            .path = path,
            .prelude = "",
            .hunks = &.{},
            .body = section,
            .additions = stats.additions,
            .deletions = stats.deletions,
            .kind = stats.kind,
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

    const stats = countDiffLineStats(section);

    return .{
        .path = path,
        .prelude = prelude,
        .hunks = hunks,
        .body = section,
        .additions = stats.additions,
        .deletions = stats.deletions,
        .kind = stats.kind,
    };
}

fn countDiffLineStats(section: []const u8) DiffLineStats {
    var stats: DiffLineStats = .{};
    var line_start: usize = 0;
    while (line_start < section.len) {
        const line_end = nextLineEnd(section, line_start);
        const line = std.mem.trimEnd(u8, section[line_start..line_end], "\r\n");
        if (std.mem.eql(u8, line, "--- /dev/null") or std.mem.startsWith(u8, line, "new file mode ")) {
            stats.kind = .created;
        } else if (std.mem.eql(u8, line, "+++ /dev/null") or std.mem.startsWith(u8, line, "deleted file mode ")) {
            stats.kind = .deleted;
        } else if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
            stats.additions += 1;
        } else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
            stats.deletions += 1;
        }
        line_start = line_end;
    }
    return stats;
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

fn writeGeneratedTreeOverview(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    sections: []const DiffSection,
) !void {
    var entries = try allocator.alloc(PathEntry, sections.len);
    defer {
        for (entries) |entry| {
            allocator.free(entry.segments);
        }
        allocator.free(entries);
    }

    var total_additions: usize = 0;
    var total_deletions: usize = 0;
    var layout: TreeLayout = .{};

    for (sections, 0..) |*section, index| {
        entries[index] = .{
            .section = section,
            .segments = try splitPathSegments(allocator, section.path),
        };
        total_additions += section.additions;
        total_deletions += section.deletions;
        layout.max_add_digits = @max(layout.max_add_digits, countDecimalDigits(section.additions));
        layout.max_del_digits = @max(layout.max_del_digits, countDecimalDigits(section.deletions));
    }

    std.sort.heap(PathEntry, entries, {}, struct {
        fn lessThan(_: void, lhs: PathEntry, rhs: PathEntry) bool {
            return std.mem.lessThan(u8, lhs.section.path, rhs.section.path);
        }
    }.lessThan);

    computeTreeLayout(entries, 0, 0, &layout);

    try builder.writer(allocator).writeAll(
        \\
        \\## Tree
        \\
        \\```text
        \\.
        \\
    );
    try writeTreeLevel(allocator, builder, entries, 0, "", 0, &layout);
    try builder.writer(allocator).writeAll(
        \\```
        \\
    );
    try builder.writer(allocator).print(
        "{d} {s} changed, {d} insertion{s}(+), {d} deletion{s}(-)\n",
        .{
            sections.len,
            if (sections.len == 1) "file" else "files",
            total_additions,
            if (total_additions == 1) "" else "s",
            total_deletions,
            if (total_deletions == 1) "" else "s",
        },
    );
}

fn splitPathSegments(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var count: usize = 1;
    for (path) |char| {
        if (char == '/') count += 1;
    }

    var segments = try allocator.alloc([]const u8, count);
    var start: usize = 0;
    var index: usize = 0;
    for (path, 0..) |char, i| {
        if (char == '/') {
            segments[index] = path[start..i];
            index += 1;
            start = i + 1;
        }
    }
    segments[index] = path[start..];
    return segments;
}

fn computeTreeLayout(entries: []const PathEntry, depth: usize, prefix_width: usize, layout: *TreeLayout) void {
    var start: usize = 0;
    while (start < entries.len) {
        const name = entries[start].segments[depth];
        var end = start + 1;
        while (end < entries.len and std.mem.eql(u8, entries[end].segments[depth], name)) {
            end += 1;
        }

        if (end - start == 1 and depth + 1 == entries[start].segments.len) {
            const label_width = prefix_width + 4 + name.len;
            layout.max_label_width = @max(layout.max_label_width, label_width);
        } else {
            computeTreeLayout(entries[start..end], depth + 1, prefix_width + 4, layout);
        }
        start = end;
    }
}

fn writeTreeLevel(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    entries: []const PathEntry,
    depth: usize,
    prefix: []const u8,
    prefix_width: usize,
    layout: *const TreeLayout,
) !void {
    var start: usize = 0;
    while (start < entries.len) {
        const name = entries[start].segments[depth];
        var end = start + 1;
        while (end < entries.len and std.mem.eql(u8, entries[end].segments[depth], name)) {
            end += 1;
        }

        const is_last = end == entries.len;
        const connector = if (is_last) "└── " else "├── ";
        if (end - start == 1 and depth + 1 == entries[start].segments.len) {
            try writeTreeLeaf(
                allocator,
                builder,
                prefix,
                connector,
                prefix_width,
                name,
                entries[start].section,
                layout,
            );
        } else {
            try builder.writer(allocator).print("{s}{s}{s}\n", .{ prefix, connector, name });
            const child_prefix = if (is_last) "    " else "│   ";
            const next_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, child_prefix });
            defer allocator.free(next_prefix);
            try writeTreeLevel(
                allocator,
                builder,
                entries[start..end],
                depth + 1,
                next_prefix,
                prefix_width + 4,
                layout,
            );
        }
        start = end;
    }
}

fn writeTreeLeaf(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    prefix: []const u8,
    connector: []const u8,
    prefix_width: usize,
    name: []const u8,
    section: *const DiffSection,
    layout: *const TreeLayout,
) !void {
    try builder.writer(allocator).print("{s}{s}{s}", .{ prefix, connector, name });

    const label_width = prefix_width + 4 + name.len;
    const padding = layout.max_label_width - label_width + 2;
    try builder.appendNTimes(allocator, ' ', padding);

    try builder.append(allocator, '+');
    try builder.appendNTimes(
        allocator,
        ' ',
        layout.max_add_digits - countDecimalDigits(section.additions),
    );
    try builder.writer(allocator).print("{d}", .{section.additions});
    try builder.append(allocator, ' ');
    try builder.append(allocator, '-');
    try builder.appendNTimes(
        allocator,
        ' ',
        layout.max_del_digits - countDecimalDigits(section.deletions),
    );
    try builder.writer(allocator).print("{d}", .{section.deletions});

    switch (section.kind) {
        .created => try builder.writer(allocator).writeAll("  (created)"),
        .deleted => try builder.writer(allocator).writeAll("  (deleted)"),
        .modified => {},
    }
    try builder.append(allocator, '\n');
}

fn countDecimalDigits(value: usize) usize {
    var digits: usize = 1;
    var remaining = value;
    while (remaining >= 10) : (remaining /= 10) {
        digits += 1;
    }
    return digits;
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

fn parseInitialHeading(source: []const u8) ?InitialHeading {
    const line_end_with_newline = nextLineEnd(source, 0);
    const line_end = if (line_end_with_newline > 0 and
        line_end_with_newline <= source.len and
        source[line_end_with_newline - 1] == '\n')
        line_end_with_newline - 1
    else
        line_end_with_newline;
    const line = std.mem.trimEnd(u8, source[0..line_end], "\r");
    if (line.len == 0 or line[0] != '#') return null;
    if (line.len >= 2 and line[1] == '#') return null;
    if (line.len > 1 and line[1] != ' ' and line[1] != '\t') return null;

    var subject = std.mem.trim(u8, line[1..], " \t");
    if (subject.len != 0 and subject[subject.len - 1] == '#') {
        subject = std.mem.trimEnd(u8, subject[0 .. subject.len - 1], " \t");
    }
    if (subject.len == 0) return null;

    var body_start = line_end_with_newline;
    while (body_start < source.len and (source[body_start] == '\n' or source[body_start] == '\r')) {
        body_start += 1;
    }

    return .{ .subject = subject, .body_start = body_start };
}

fn compactDocumentBodyWithBlocks(
    allocator: std.mem.Allocator,
    source: []const u8,
    body_start: usize,
    blocks: []const CanonicalDiffBlock,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    _ = diagnostics;
    var markdown_document = try markdown.parse(allocator, source);
    defer markdown_document.deinit();

    var diff_nodes: std.ArrayList(markdown.Node) = .empty;
    defer diff_nodes.deinit(allocator);
    try collectCodeBlockNodes(allocator, markdown_document.children, "diff", &diff_nodes);

    const lines = try flattenDiffBlockLines(allocator, blocks);
    defer allocator.free(lines);
    const used = try allocator.alloc(bool, lines.len);
    defer allocator.free(used);
    @memset(used, false);

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);

    var cursor = body_start;
    for (diff_nodes.items) |node| {
        const span_start: usize = @intCast(node.span_start);
        const span_end: usize = @intCast(node.span_end);
        if (span_end <= body_start) continue;
        if (span_start < cursor) return error.OverlappingPatchFences;

        try builder.appendSlice(allocator, source[cursor..span_start]);

        const normalized = try ensureTrailingNewline(allocator, node.text);
        defer allocator.free(normalized);
        const ranges = try findLineRangesForText(allocator, normalized, lines, used);
        defer allocator.free(ranges);
        markRangesUsed(lines, used, ranges);

        const range_text = try formatLineRanges(allocator, ranges, blocks);
        defer allocator.free(range_text);
        const ref_info = try compactRefInfo(allocator, node.info, range_text);
        defer allocator.free(ref_info);
        try writeEmptyFenceReplacement(allocator, &builder, ref_info);

        cursor = span_end;
    }

    try builder.appendSlice(allocator, source[cursor..]);
    return builder.toOwnedSlice(allocator);
}

fn expandCompactRecipeWithBlocks(
    allocator: std.mem.Allocator,
    owned_source: []u8,
    blocks: []const CanonicalDiffBlock,
    diagnostics: ?*Diagnostic,
) ![]u8 {
    _ = diagnostics;
    var markdown_document = try markdown.parse(allocator, owned_source);
    defer markdown_document.deinit();

    var ref_nodes: std.ArrayList(markdown.Node) = .empty;
    defer ref_nodes.deinit(allocator);
    try collectCodeBlockNodes(allocator, markdown_document.children, "latch-ref", &ref_nodes);
    if (ref_nodes.items.len == 0) return error.NoLatchRefs;

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);

    var cursor: usize = 0;
    for (ref_nodes.items) |node| {
        const span_start: usize = @intCast(node.span_start);
        const span_end: usize = @intCast(node.span_end);
        if (span_start < cursor) return error.OverlappingPatchFences;
        try builder.appendSlice(allocator, owned_source[cursor..span_start]);

        const parsed = try parseLatchRefInfo(allocator, node.info);
        defer allocator.free(parsed.metadata);
        defer allocator.free(parsed.ranges);

        const body = try materializeRanges(allocator, parsed.ranges, blocks);
        defer allocator.free(body);
        try writeDiffFenceReplacement(allocator, &builder, parsed.metadata, body);

        cursor = span_end;
    }

    try builder.appendSlice(allocator, owned_source[cursor..]);
    return builder.toOwnedSlice(allocator);
}

const ParsedLatchRef = struct {
    metadata: []const u8,
    ranges: []const LineRange,
};

fn collectCodeBlockNodes(
    allocator: std.mem.Allocator,
    nodes: []const markdown.Node,
    language: []const u8,
    output: *std.ArrayList(markdown.Node),
) !void {
    for (nodes) |node| {
        if (node.kind == .code_block) {
            if (codeBlockLanguage(node.info)) |node_language| {
                if (std.mem.eql(u8, node_language, language)) {
                    try output.append(allocator, node);
                }
            }
        }
        if (node.children.len != 0) {
            try collectCodeBlockNodes(allocator, node.children, language, output);
        }
    }
}

fn codeBlockLanguage(info: []const u8) ?[]const u8 {
    var token_iter = std.mem.tokenizeAny(u8, info, " \t\r\n");
    return token_iter.next();
}

fn ensureTrailingNewline(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, text, "\n")) return allocator.dupe(u8, text);
    var buffer = try allocator.alloc(u8, text.len + 1);
    @memcpy(buffer[0..text.len], text);
    buffer[text.len] = '\n';
    return buffer;
}

fn flattenDiffBlockLines(allocator: std.mem.Allocator, blocks: []const CanonicalDiffBlock) ![]DiffLineRef {
    var lines: std.ArrayList(DiffLineRef) = .empty;
    defer lines.deinit(allocator);
    for (blocks, 0..) |block, block_index| {
        var start: usize = 0;
        var line_index: usize = 1;
        while (start < block.text.len) : (line_index += 1) {
            const end = nextLineEnd(block.text, start);
            try lines.append(allocator, .{
                .block_index = block_index,
                .line_index = line_index,
                .text = block.text[start..end],
            });
            start = end;
        }
    }
    return lines.toOwnedSlice(allocator);
}

fn findLineRangesForText(
    allocator: std.mem.Allocator,
    needle: []const u8,
    lines: []const DiffLineRef,
    used: []const bool,
) ![]LineRange {
    if (needle.len == 0) return error.EmptyDiffBody;
    for (lines, 0..) |_, start_index| {
        if (used[start_index]) continue;
        var offset: usize = 0;
        var line_index = start_index;
        var matched_lines: std.ArrayList(DiffLineRef) = .empty;
        defer matched_lines.deinit(allocator);
        while (offset < needle.len and line_index < lines.len and !used[line_index]) : (line_index += 1) {
            const line = lines[line_index].text;
            if (std.mem.startsWith(u8, needle[offset..], line)) {
                try matched_lines.append(allocator, lines[line_index]);
                offset += line.len;
                continue;
            }
            if (std.mem.startsWith(u8, line, "index ")) continue;
            break;
        }
        if (offset == needle.len and matched_lines.items.len != 0) {
            return rangesForLineSpan(allocator, matched_lines.items);
        }
    }
    return error.UnmatchedDiffBody;
}

fn rangesForLineSpan(allocator: std.mem.Allocator, span: []const DiffLineRef) ![]LineRange {
    std.debug.assert(span.len != 0);
    var ranges: std.ArrayList(LineRange) = .empty;
    defer ranges.deinit(allocator);

    var current: LineRange = .{
        .block_index = span[0].block_index,
        .start_line = span[0].line_index,
        .end_line = span[0].line_index,
    };
    for (span[1..]) |line| {
        if (line.block_index == current.block_index and line.line_index == current.end_line + 1) {
            current.end_line = line.line_index;
            continue;
        }
        try ranges.append(allocator, current);
        current = .{
            .block_index = line.block_index,
            .start_line = line.line_index,
            .end_line = line.line_index,
        };
    }
    try ranges.append(allocator, current);
    return ranges.toOwnedSlice(allocator);
}

fn markRangesUsed(lines: []const DiffLineRef, used: []bool, ranges: []const LineRange) void {
    for (lines, 0..) |line, index| {
        for (ranges) |range| {
            if (line.block_index == range.block_index and
                line.line_index >= range.start_line and
                line.line_index <= range.end_line)
            {
                used[index] = true;
                break;
            }
        }
    }
}

fn formatLineRanges(
    allocator: std.mem.Allocator,
    ranges: []const LineRange,
    blocks: []const CanonicalDiffBlock,
) ![]u8 {
    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);
    for (ranges, 0..) |range, index| {
        if (index != 0) try builder.append(allocator, ',');
        const block_line_count = countBlockLines(blocks[range.block_index].text);
        if (range.end_line == block_line_count) {
            try builder.writer(allocator).print("{d}:{d}..$", .{ range.block_index + 1, range.start_line });
        } else {
            try builder.writer(allocator).print(
                "{d}:{d}..{d}",
                .{ range.block_index + 1, range.start_line, range.end_line },
            );
        }
    }
    return builder.toOwnedSlice(allocator);
}

fn countBlockLines(text: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (start < text.len) : (count += 1) {
        start = nextLineEnd(text, start);
    }
    return count;
}

fn compactRefInfo(allocator: std.mem.Allocator, diff_info: []const u8, ranges: []const u8) ![]u8 {
    var token_iter = std.mem.tokenizeAny(u8, diff_info, " \t\r\n");
    const language = token_iter.next() orelse return error.InvalidPatchFence;
    if (!std.mem.eql(u8, language, "diff")) return error.InvalidPatchFence;

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);
    try builder.appendSlice(allocator, "latch-ref");
    while (token_iter.next()) |token| {
        try builder.append(allocator, ' ');
        try builder.appendSlice(allocator, token);
    }
    try builder.writer(allocator).print(" ranges={s}", .{ranges});
    return builder.toOwnedSlice(allocator);
}

fn writeEmptyFenceReplacement(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    info: []const u8,
) !void {
    try builder.writer(allocator).print("```{s}\n```", .{info});
}

fn writeDiffFenceReplacement(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    metadata: []const u8,
    body: []const u8,
) !void {
    const fence_len = requiredBacktickFenceLen("", body);
    try builder.appendNTimes(allocator, '`', fence_len);
    try builder.writer(allocator).print("diff {s}\n", .{metadata});
    try builder.appendSlice(allocator, body);
    if (!std.mem.endsWith(u8, body, "\n")) {
        try builder.append(allocator, '\n');
    }
    try builder.appendNTimes(allocator, '`', fence_len);
}

fn parseLatchRefInfo(allocator: std.mem.Allocator, info: []const u8) !ParsedLatchRef {
    var token_iter = std.mem.tokenizeAny(u8, info, " \t\r\n");
    const language = token_iter.next() orelse return error.InvalidLatchRef;
    if (!std.mem.eql(u8, language, "latch-ref")) return error.InvalidLatchRef;

    var metadata: std.ArrayList(u8) = .empty;
    errdefer metadata.deinit(allocator);
    var parsed_ranges: ?[]LineRange = null;
    errdefer if (parsed_ranges) |ranges| allocator.free(ranges);
    var saw_id = false;

    while (token_iter.next()) |token| {
        const eq_index = std.mem.indexOfScalar(u8, token, '=') orelse return error.InvalidLatchRef;
        const key = token[0..eq_index];
        const value = token[eq_index + 1 ..];
        if (std.mem.eql(u8, key, "ranges")) {
            if (parsed_ranges != null) return error.InvalidLatchRef;
            parsed_ranges = try parseLineRanges(allocator, value);
            continue;
        }
        if (std.mem.eql(u8, key, "id")) saw_id = value.len != 0;
        if (!std.mem.eql(u8, key, "id") and
            !std.mem.eql(u8, key, "depends-on") and
            !std.mem.eql(u8, key, "part"))
        {
            return error.InvalidLatchRef;
        }
        if (metadata.items.len != 0) try metadata.append(allocator, ' ');
        try metadata.appendSlice(allocator, token);
    }

    if (!saw_id or parsed_ranges == null) return error.InvalidLatchRef;
    return .{
        .metadata = try metadata.toOwnedSlice(allocator),
        .ranges = parsed_ranges.?,
    };
}

fn parseLineRanges(allocator: std.mem.Allocator, text: []const u8) ![]LineRange {
    var ranges: std.ArrayList(LineRange) = .empty;
    errdefer ranges.deinit(allocator);

    var iter = std.mem.splitScalar(u8, text, ',');
    while (iter.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t\r\n");
        if (item.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse return error.InvalidLatchRefRange;
        const dots = std.mem.indexOf(u8, item[colon + 1 ..], "..") orelse return error.InvalidLatchRefRange;
        const range_start = colon + 1;
        const range_mid = range_start + dots;
        const range_end = range_mid + 2;

        const block_number = try std.fmt.parseInt(usize, item[0..colon], 10);
        const start_line = try std.fmt.parseInt(usize, item[range_start..range_mid], 10);
        const end_line = if (std.mem.eql(u8, item[range_end..], "$"))
            std.math.maxInt(usize)
        else
            try std.fmt.parseInt(usize, item[range_end..], 10);
        if (block_number == 0 or start_line == 0) return error.InvalidLatchRefRange;
        if (end_line != std.math.maxInt(usize) and end_line < start_line) return error.InvalidLatchRefRange;
        try ranges.append(allocator, .{
            .block_index = block_number - 1,
            .start_line = start_line,
            .end_line = end_line,
        });
    }

    if (ranges.items.len == 0) return error.InvalidLatchRefRange;
    return ranges.toOwnedSlice(allocator);
}

fn materializeRanges(
    allocator: std.mem.Allocator,
    ranges: []const LineRange,
    blocks: []const CanonicalDiffBlock,
) ![]u8 {
    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);
    for (ranges) |range| {
        if (range.block_index >= blocks.len) return error.InvalidLatchRefRange;
        const text = blocks[range.block_index].text;
        const line_count = countBlockLines(text);
        const end_line = if (range.end_line == std.math.maxInt(usize)) line_count else range.end_line;
        if (range.start_line == 0 or range.start_line > end_line or end_line > line_count) {
            return error.InvalidLatchRefRange;
        }
        const slice = lineRangeSlice(text, range.start_line, end_line) orelse return error.InvalidLatchRefRange;
        try builder.appendSlice(allocator, slice);
    }
    return builder.toOwnedSlice(allocator);
}

fn lineRangeSlice(text: []const u8, start_line: usize, end_line: usize) ?[]const u8 {
    var current_line: usize = 1;
    var line_start: usize = 0;
    var start_offset: ?usize = null;
    var end_offset: ?usize = null;
    while (line_start < text.len) : (current_line += 1) {
        const line_end = nextLineEnd(text, line_start);
        if (current_line == start_line) start_offset = line_start;
        if (current_line == end_line) {
            end_offset = line_end;
            break;
        }
        line_start = line_end;
    }
    if (start_offset == null or end_offset == null) return null;
    return text[start_offset.?..end_offset.?];
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

fn parseReviewNode(
    allocator: std.mem.Allocator,
    source: []const u8,
    node: markdown.Node,
    diagnostics: ?*Diagnostic,
) !?Review {
    var token_iter = std.mem.tokenizeAny(u8, node.info, " \t\r\n");
    const language = token_iter.next() orelse return null;
    if (!std.mem.eql(u8, language, "review")) return null;

    const span_start: usize = @intCast(node.span_start);
    const span_end: usize = @intCast(node.span_end);
    const start_line = lineNumberForOffset(source, span_start);
    const end_line = lineNumberForOffset(source, if (span_end == 0) 0 else span_end - 1);

    var id: ?[]const u8 = null;
    var metadata: std.ArrayList(ReviewMetadata) = .empty;
    defer metadata.deinit(allocator);

    while (token_iter.next()) |token| {
        const eq_index = std.mem.indexOfScalar(u8, token, '=') orelse {
            try emitDiagnostic(
                "invalid review metadata '{s}' at lines {d}-{d}; expected key=value",
                .{ token, start_line, end_line },
                diagnostics,
                .invalid_review_metadata,
                .{
                    .metadata_value = token,
                    .start_line = start_line,
                    .end_line = end_line,
                },
            );
            return error.InvalidReviewMetadata;
        };

        const key = token[0..eq_index];
        const value = token[eq_index + 1 ..];
        if (std.mem.eql(u8, key, "id")) {
            if (value.len == 0) {
                try emitDiagnostic(
                    "review fence at lines {d}-{d} has empty id=...",
                    .{ start_line, end_line },
                    diagnostics,
                    .invalid_review_id,
                    .{ .start_line = start_line, .end_line = end_line },
                );
                return error.InvalidReviewId;
            }
            id = value;
        }
        try metadata.append(allocator, .{ .key = key, .value = value });
    }

    return .{
        .id = id,
        .metadata = try metadata.toOwnedSlice(allocator),
        .text = node.text,
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

test "compact recipe stores line ranges and expands diff fences" {
    const block_text =
        \\diff --git a/file.txt b/file.txt
        \\index 1111111..2222222 100644
        \\--- a/file.txt
        \\+++ b/file.txt
        \\@@ -1,3 +1,4 @@
        \\ a
        \\-b
        \\+bee
        \\ c
        \\+d
        \\
    ;
    const blocks = [_]CanonicalDiffBlock{.{ .text = block_text }};
    const source =
        \\# Split test
        \\
        \\First half.
        \\
        \\```diff id=core part=1
        \\diff --git a/file.txt b/file.txt
        \\index 1111111..2222222 100644
        \\--- a/file.txt
        \\+++ b/file.txt
        \\@@ -1,3 +1,4 @@
        \\ a
        \\-b
        \\```
        \\
        \\Second half.
        \\
        \\```diff id=core part=2
        \\+bee
        \\ c
        \\+d
        \\```
        \\
    ;

    const heading = parseInitialHeading(source).?;
    try std.testing.expectEqualStrings("Split test", heading.subject);

    const compact = try compactDocumentBodyWithBlocks(
        std.testing.allocator,
        source,
        heading.body_start,
        &blocks,
        null,
    );
    defer std.testing.allocator.free(compact);

    try std.testing.expect(std.mem.indexOf(u8, compact, "```latch-ref id=core part=1 ranges=1:1..7") != null);
    try std.testing.expect(std.mem.indexOf(u8, compact, "```latch-ref id=core part=2 ranges=1:8..$") != null);

    const compact_source = try std.fmt.allocPrint(std.testing.allocator, "# {s}\n\n{s}", .{ heading.subject, compact });
    defer std.testing.allocator.free(compact_source);
    const expanded = try expandCompactRecipeWithBlocks(std.testing.allocator, compact_source, &blocks, null);
    defer std.testing.allocator.free(expanded);

    try std.testing.expect(std.mem.indexOf(u8, expanded, "```diff id=core part=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "```diff id=core part=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "+bee\n c\n+d\n```") != null);
}

test "extracts review fences without executable diffs" {
    const source =
        \\# Review pass
        \\
        \\```review reviewer=tim@timculverhouse.com
        \\Start the story with behavior.
        \\```
        \\
        \\```review id=core reviewer=tim@timculverhouse.com topic=diagnostics
        \\Can this mention the unsupported key?
        \\```
        \\
    ;

    const owned = try std.testing.allocator.dupe(u8, source);
    var document = try parseReviewDocument(std.testing.allocator, owned);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.reviews.len);
    try std.testing.expectEqual(@as(?[]const u8, null), document.reviews[0].id);
    try std.testing.expectEqualStrings("Start the story with behavior.", document.reviews[0].text);
    try std.testing.expectEqual(@as(usize, 3), document.reviews[0].start_line);
    try std.testing.expectEqual(@as(usize, 5), document.reviews[0].end_line);

    try std.testing.expectEqualStrings("core", document.reviews[1].id.?);
    try std.testing.expectEqual(@as(usize, 3), document.reviews[1].metadata.len);
    try std.testing.expectEqualStrings("id", document.reviews[1].metadata[0].key);
    try std.testing.expectEqualStrings("core", document.reviews[1].metadata[0].value);
    try std.testing.expectEqualStrings("topic", document.reviews[1].metadata[2].key);
    try std.testing.expectEqualStrings("diagnostics", document.reviews[1].metadata[2].value);
}

test "review fences can contain nested code fences" {
    const source =
        \\````review id=impl
        \\Try this shape:
        \\
        \\```zig
        \\try run();
        \\```
        \\````
        \\
    ;

    const owned = try std.testing.allocator.dupe(u8, source);
    var document = try parseReviewDocument(std.testing.allocator, owned);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.reviews.len);
    try std.testing.expectEqualStrings("impl", document.reviews[0].id.?);
    try std.testing.expect(std.mem.indexOf(u8, document.reviews[0].text, "```zig\ntry run();\n```") != null);
}

test "rejects malformed review metadata during review extraction" {
    const source =
        \\```review id
        \\Please scope this comment.
        \\```
        \\
    ;

    const owned = try std.testing.allocator.dupe(u8, source);
    var diagnostics = Diagnostic.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(
        error.InvalidReviewMetadata,
        parseReviewDocumentWithDiagnostics(std.testing.allocator, owned, &diagnostics),
    );
    std.testing.allocator.free(owned);

    try std.testing.expectEqual(DiagnosticKind.invalid_review_metadata, diagnostics.kind.?);
    try std.testing.expectEqualStrings("id", diagnostics.metadata_value.?);
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

test "preserves hard tabs in diff context lines" {
    const source =
        "```diff id=tabs\n" ++
        "diff --git a/a.rs b/a.rs\n" ++
        "--- a/a.rs\n" ++
        "+++ b/a.rs\n" ++
        "@@ -1,4 +1,4 @@\n" ++
        " fn main() {\n" ++
        " \tlet keep = 1;\n" ++
        "-\tlet x = 1;\n" ++
        "+\tlet x = 2;\n" ++
        " }\n" ++
        "```\n";

    const owned = try std.testing.allocator.dupe(u8, source);
    var document = try parseDocument(std.testing.allocator, owned);
    defer document.deinit();

    const expected_diff =
        "diff --git a/a.rs b/a.rs\n" ++
        "--- a/a.rs\n" ++
        "+++ b/a.rs\n" ++
        "@@ -1,4 +1,4 @@\n" ++
        " fn main() {\n" ++
        " \tlet keep = 1;\n" ++
        "-\tlet x = 1;\n" ++
        "+\tlet x = 2;\n" ++
        " }";

    try std.testing.expectEqual(@as(usize, 1), document.patches.len);
    try std.testing.expectEqualStrings(expected_diff, document.patches[0].diff);
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
    try std.testing.expect(std.mem.indexOf(u8, generated, "## Tree\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "├── README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "└── src\n    └── main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "2 files changed, 3 insertions(+), 0 deletions(-)") != null);
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

test "generate document includes created and deleted markers in tree overview" {
    const diff =
        \\diff --git a/LICENSE b/LICENSE
        \\new file mode 100644
        \\index 0000000..1111111
        \\--- /dev/null
        \\+++ b/LICENSE
        \\@@ -0,0 +1,2 @@
        \\+MIT License
        \\+Copyright (c) 2026 Tim Culverhouse
        \\
        \\diff --git a/src/old.zig b/src/old.zig
        \\deleted file mode 100644
        \\index 2222222..0000000
        \\--- a/src/old.zig
        \\+++ /dev/null
        \\@@ -1,2 +0,0 @@
        \\-const old = true;
        \\-pub fn old() void {}
        \\
    ;

    const generated = try generateDocumentFromUnifiedDiff(std.testing.allocator, diff);
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated, "├── LICENSE") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "(created)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "└── src\n    └── old.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "(deleted)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "2 files changed, 2 insertions(+), 2 deletions(-)") != null);
}
