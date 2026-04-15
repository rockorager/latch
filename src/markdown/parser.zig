//! A native Markdown parser with an arena-owned node tree backed by borrowed source text.

const std = @import("std");
const uucode = @import("uucode");

pub const ParseError = error{
    InvalidOrderedListStart,
    NestingLimitExceeded,
};

pub const ListDelimiter = enum {
    none,
    bullet,
    period,
    paren,
};

pub const TableAlignment = enum {
    none,
    left,
    center,
    right,
};

pub const HtmlBlockType = enum {
    none,
    raw_tag,
    comment,
    instruction,
    declaration,
    cdata,
    block_tag,
    type7,
};

pub const NodeKind = enum {
    paragraph,
    heading,
    text,
    emphasis,
    strong,
    strikethrough,
    code_span,
    code_block,
    link,
    image,
    table,
    table_head,
    table_body,
    table_row,
    table_cell,
    list,
    list_item,
    block_quote,
    thematic_break,
    soft_break,
    hard_break,
    html_block,
    html_inline,
};

pub const Node = struct {
    kind: NodeKind,
    children: []Node = &.{},
    text: []const u8 = "",
    info: []const u8 = "",
    destination: []const u8 = "",
    title: []const u8 = "",
    level: i64 = 0,
    ordered: bool = false,
    start: i64 = 1,
    tight: bool = true,
    task: bool = false,
    checked: bool = false,
    delimiter: ListDelimiter = .none,
    alignment: TableAlignment = .none,
    html_block_type: HtmlBlockType = .none,
    span_start: i64 = 0,
    span_end: i64 = 0,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    /// Borrowed source text. The caller must keep this buffer alive until
    /// `deinit()` is called on the document.
    source: []const u8,
    children: []Node,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParseOptions = struct {
    autolink_literals: bool = true,
};

const max_nesting = 64;

const Line = struct {
    text: []const u8,
    start_offset: usize,
    end_offset: usize,
    setext_eligible: bool = true,
    block_starter_eligible: bool = true,
};

const Fence = struct {
    indent: usize,
    marker: u8,
    count: usize,
    info: []const u8,
};

const Heading = struct {
    level: i64,
    text: []const u8,
    content_start: usize,
    content_end: usize,
};

const ListMarker = struct {
    ordered: bool,
    start: i64,
    marker: u8,
    indent: usize,
    prefix_end: usize,
    content_indent: usize,
    empty: bool,
    delimiter: ListDelimiter,
};

const TaskMarker = struct {
    checked: bool,
    content: []const u8,
};

const ParsedNode = struct {
    node: ?Node = null,
    consumed: usize,
    had_blank_line: bool = false,
    ends_with_blank_line: bool = false,
};

const HtmlBlockKind = HtmlBlockType;

const TableCellSlice = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

const AutolinkLiteral = struct {
    text: []const u8,
    destination: []const u8,
    consumed: usize,
};

const DelimiterRunInfo = struct {
    count: usize,
    can_open: bool,
    can_close: bool,
};

const DelimiterToken = struct {
    marker: u8,
    length: usize,
    can_open: bool,
    can_close: bool,
    original_can_open: bool,
    original_can_close: bool,
    active: bool = true,
};

const InlinePiece = struct {
    node: Node,
    delimiter: ?DelimiterToken = null,
};

const InlineParseOptions = struct {
    allow_links: bool = true,
};

const ParsedLinkTarget = struct {
    target: LinkTarget,
    consumed: usize,
};

const ParsedLinkDestination = struct {
    destination: []const u8,
    end: usize,
};

const ParseContext = struct {
    allocator: std.mem.Allocator,
    options: ParseOptions,
    phase: ParsePhase = .build_document,
    definitions: std.StringHashMapUnmanaged(LinkTarget) = .empty,

    fn putDefinition(
        self: *ParseContext,
        normalized_label: []const u8,
        target: LinkTarget,
    ) std.mem.Allocator.Error!void {
        if (self.definitions.contains(normalized_label)) return;
        try self.definitions.put(self.allocator, normalized_label, target);
    }

    fn getDefinition(self: *ParseContext, normalized_label: []const u8) ?LinkTarget {
        return self.definitions.get(normalized_label);
    }

    fn collectingDefinitions(self: ParseContext) bool {
        return self.phase == .collect_definitions;
    }
};

const ParsePhase = enum {
    build_document,
    collect_definitions,
};

pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
) (std.mem.Allocator.Error || ParseError)!Document {
    return parseWithOptions(allocator, source, .{});
}

pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: ParseOptions,
) (std.mem.Allocator.Error || ParseError)!Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();
    var context: ParseContext = .{
        .allocator = arena_allocator,
        .options = options,
    };
    const lines = try splitLines(arena_allocator, source);
    var prepass_arena = std.heap.ArenaAllocator.init(allocator);
    defer prepass_arena.deinit();

    var prepass_context: ParseContext = .{
        .allocator = prepass_arena.allocator(),
        .options = options,
        .phase = .collect_definitions,
    };
    _ = try parseBlocks(&prepass_context, lines, 0);

    var definitions = prepass_context.definitions.iterator();
    while (definitions.next()) |entry| {
        const normalized_label = try arena_allocator.dupe(u8, entry.key_ptr.*);
        const destination = try arena_allocator.dupe(u8, entry.value_ptr.destination);
        const title = try arena_allocator.dupe(u8, entry.value_ptr.title);
        try context.putDefinition(normalized_label, .{
            .destination = destination,
            .title = title,
        });
    }

    const children = try parseBlocks(&context, lines, 0);

    return .{
        .arena = arena,
        .source = source,
        .children = children,
    };
}

fn splitLines(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]Line {
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(allocator);

    var start: usize = 0;
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        if (source[index] != '\n') continue;

        var line = source[start..index];
        if (line.len != 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        try lines.append(allocator, .{
            .text = line,
            .start_offset = start,
            .end_offset = start + line.len,
        });
        start = index + 1;
    }

    if (start < source.len) {
        var line = source[start..];
        if (line.len != 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        try lines.append(allocator, .{
            .text = line,
            .start_offset = start,
            .end_offset = start + line.len,
        });
    }

    return lines.toOwnedSlice(allocator);
}

fn parseBlocks(
    context: *ParseContext,
    lines: []const Line,
    depth: usize,
) (std.mem.Allocator.Error || ParseError)![]Node {
    if (depth > max_nesting) return error.NestingLimitExceeded;

    const allocator = context.allocator;
    const collect_definitions_only = context.collectingDefinitions();
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(allocator);

    var index: usize = 0;
    while (index < lines.len) {
        const line = lines[index];
        if (isBlank(line.text)) {
            index += 1;
            continue;
        }

        if (line.block_starter_eligible) {
            if (parseFence(line.text)) |fence| {
                if (collect_definitions_only) {
                    index += codeBlockConsumed(lines[index..], fence);
                } else {
                    const parsed = try parseCodeBlock(allocator, lines[index..], fence);
                    try nodes.append(allocator, parsed.node.?);
                    index += parsed.consumed;
                }
                continue;
            }

            if (parseHeading(line.text)) |heading| {
                if (!collect_definitions_only) {
                    const children = try parseInlines(
                        context,
                        heading.text,
                        line.start_offset + heading.content_start,
                        depth + 1,
                    );
                    try nodes.append(allocator, .{
                        .kind = .heading,
                        .children = children,
                        .level = heading.level,
                        .span_start = @intCast(line.start_offset),
                        .span_end = @intCast(line.start_offset + heading.content_end),
                    });
                }
                index += 1;
                continue;
            }

            if (isThematicBreak(line.text)) {
                if (!collect_definitions_only) {
                    try nodes.append(allocator, .{
                        .kind = .thematic_break,
                        .span_start = @intCast(line.start_offset),
                        .span_end = @intCast(line.end_offset),
                    });
                }
                index += 1;
                continue;
            }

            if (parseHtmlBlockKind(line.text)) |html_kind| {
                if (collect_definitions_only) {
                    index += htmlBlockConsumed(lines[index..], html_kind);
                } else {
                    const parsed = try parseHtmlBlock(allocator, lines[index..], html_kind);
                    try nodes.append(allocator, parsed.node.?);
                    index += parsed.consumed;
                }
                continue;
            }

            if (isIndentedCodeLine(line.text)) {
                if (collect_definitions_only) {
                    index += indentedCodeBlockConsumed(lines[index..]);
                } else {
                    const parsed = try parseIndentedCodeBlock(allocator, lines[index..]);
                    try nodes.append(allocator, parsed.node.?);
                    index += parsed.consumed;
                }
                continue;
            }

            if (isQuoteLine(line.text)) {
                const parsed = try parseBlockQuote(context, lines[index..], depth + 1);
                if (!collect_definitions_only) try nodes.append(allocator, parsed.node.?);
                index += parsed.consumed;
                continue;
            }

            if (try parseListMarker(line.text)) |_| {
                const parsed = try parseList(context, lines[index..], depth + 1);
                if (!collect_definitions_only) try nodes.append(allocator, parsed.node.?);
                index += parsed.consumed;
                continue;
            }

            if (collect_definitions_only) {
                if (try tableConsumed(allocator, lines[index..])) |consumed| {
                    index += consumed;
                    continue;
                }
            } else {
                if (try parseTable(context, lines[index..], depth + 1)) |parsed| {
                    try nodes.append(allocator, parsed.node.?);
                    index += parsed.consumed;
                    continue;
                }
            }
        }

        const parsed = try parseParagraph(context, lines[index..], depth + 1);
        if (!collect_definitions_only) {
            if (parsed.node) |node| {
                const setext_index = parsed.consumed;
                if (setext_index < lines[index..].len) {
                    if (lines[index + setext_index].setext_eligible) {
                        if (parseSetextUnderline(lines[index + setext_index].text)) |level| {
                            try nodes.append(allocator, .{
                                .kind = .heading,
                                .children = node.children,
                                .level = level,
                                .span_start = node.span_start,
                                .span_end = @intCast(lines[index + setext_index].end_offset),
                            });
                            index += parsed.consumed + 1;
                            continue;
                        }
                    }
                }

                try nodes.append(allocator, node);
            }
        }
        index += parsed.consumed;
    }

    if (collect_definitions_only) return &.{};
    return nodes.toOwnedSlice(allocator);
}

fn parseCodeBlock(
    allocator: std.mem.Allocator,
    lines: []const Line,
    fence: Fence,
) std.mem.Allocator.Error!ParsedNode {
    var captured: std.ArrayList([]const u8) = .empty;
    defer captured.deinit(allocator);
    const info = try normalizeTextFragment(allocator, fence.info);

    var index: usize = 1;
    while (index < lines.len) : (index += 1) {
        if (isClosingFence(lines[index].text, fence)) {
            const text = try joinCodeBlockLines(allocator, captured.items);
            return .{
                .node = .{
                    .kind = .code_block,
                    .text = text,
                    .info = info,
                    .span_start = @intCast(lines[0].start_offset),
                    .span_end = @intCast(lines[index].end_offset),
                },
                .consumed = index + 1,
            };
        }
        const stripped = try stripIndentColumns(allocator, lines[index].text, fence.indent);
        try captured.append(allocator, stripped.text);
    }

    const text = try joinCodeBlockLines(allocator, captured.items);
    return .{
        .node = .{
            .kind = .code_block,
            .text = text,
            .info = info,
            .span_start = @intCast(lines[0].start_offset),
            .span_end = @intCast(lines[lines.len - 1].end_offset),
        },
        .consumed = lines.len,
    };
}

fn codeBlockConsumed(lines: []const Line, fence: Fence) usize {
    var index: usize = 1;
    while (index < lines.len) : (index += 1) {
        if (isClosingFence(lines[index].text, fence)) return index + 1;
    }
    return lines.len;
}

fn parseBlockQuote(
    context: *ParseContext,
    lines: []const Line,
    depth: usize,
) (std.mem.Allocator.Error || ParseError)!ParsedNode {
    const allocator = context.allocator;
    var stripped: std.ArrayList(Line) = .empty;
    defer stripped.deinit(allocator);

    var consumed: usize = 0;
    var can_lazy_continue = false;
    while (consumed < lines.len) {
        const line = lines[consumed];
        if (isQuoteLine(line.text)) {
            const indent = leadingIndent(line.text);
            const stripped_text = try stripContainerPrefix(allocator, line.text, indent + 1);
            try stripped.append(allocator, .{
                .text = stripped_text.text,
                .start_offset = line.start_offset,
                .end_offset = line.end_offset,
            });
            can_lazy_continue = try isLazyBlockQuoteContinuation(allocator, stripped_text.text);
            consumed += 1;
            continue;
        }

        if (isBlank(line.text)) break;

        if (!can_lazy_continue) break;
        if (try isBlockStarter(line.text)) break;

        try stripped.append(allocator, .{
            .text = line.text,
            .start_offset = line.start_offset,
            .end_offset = line.end_offset,
            .setext_eligible = false,
        });
        consumed += 1;
    }

    const children = try parseBlocks(context, stripped.items, depth);
    if (context.collectingDefinitions()) {
        return .{
            .consumed = consumed,
        };
    }
    return .{
        .node = .{
            .kind = .block_quote,
            .children = children,
            .span_start = @intCast(lines[0].start_offset),
            .span_end = @intCast(lines[consumed - 1].end_offset),
        },
        .consumed = consumed,
    };
}

fn parseList(
    context: *ParseContext,
    lines: []const Line,
    depth: usize,
) (std.mem.Allocator.Error || ParseError)!ParsedNode {
    const allocator = context.allocator;
    const collect_definitions_only = context.collectingDefinitions();
    const first_marker = (try parseListMarker(lines[0].text)).?;

    var items: std.ArrayList(Node) = .empty;
    defer items.deinit(allocator);

    var tight = true;
    var consumed: usize = 0;
    while (consumed < lines.len) {
        if (consumed != 0 and isThematicBreak(lines[consumed].text)) break;
        const marker = (try parseListMarker(lines[consumed].text)) orelse break;
        if (!sameListGroup(first_marker, marker)) break;

        const parsed = try parseListItem(context, lines[consumed..], marker, depth);
        if (!collect_definitions_only) {
            tight = tight and !parsed.had_blank_line;
            const next_index = consumed + parsed.consumed;
            if (parsed.ends_with_blank_line and next_index < lines.len) {
                const next_marker = try parseListMarker(lines[next_index].text);
                if (next_marker) |list_marker| {
                    if (sameListGroup(first_marker, list_marker)) {
                        tight = false;
                    }
                }
            }
            try items.append(allocator, parsed.node.?);
        }
        consumed += parsed.consumed;
    }

    if (collect_definitions_only) {
        return .{
            .consumed = consumed,
        };
    }

    return .{
        .node = .{
            .kind = .list,
            .children = try items.toOwnedSlice(allocator),
            .ordered = first_marker.ordered,
            .start = first_marker.start,
            .tight = tight,
            .delimiter = first_marker.delimiter,
            .span_start = @intCast(lines[0].start_offset),
            .span_end = @intCast(lines[consumed - 1].end_offset),
        },
        .consumed = consumed,
        .had_blank_line = !tight,
    };
}

fn parseListItem(
    context: *ParseContext,
    lines: []const Line,
    marker: ListMarker,
    depth: usize,
) (std.mem.Allocator.Error || ParseError)!ParsedNode {
    const allocator = context.allocator;
    const collect_definitions_only = context.collectingDefinitions();
    var item_lines: std.ArrayList(Line) = .empty;
    defer item_lines.deinit(allocator);

    const first_line = try stripListItemPrefix(allocator, lines[0].text, marker.prefix_end);
    const task = parseTaskMarker(first_line.text);
    const first_line_offset = first_line.bytes + if (task != null)
        @as(usize, 4)
    else
        @as(usize, 0);
    try item_lines.append(allocator, .{
        .text = if (task) |marker_task| marker_task.content else first_line.text,
        .start_offset = lines[0].start_offset + first_line_offset,
        .end_offset = lines[0].end_offset,
    });

    var consumed: usize = 1;
    var saw_blank = false;
    var internal_blank_line = false;
    var ends_with_blank_line = false;
    var last_nonblank_is_paragraph_like = try isParagraphLikeBlockLine(item_lines.items[0].text);
    while (consumed < lines.len) {
        const line = lines[consumed];
        if (isBlank(line.text)) {
            try item_lines.append(allocator, .{
                .text = "",
                .start_offset = line.start_offset,
                .end_offset = line.end_offset,
            });
            saw_blank = true;
            consumed += 1;
            continue;
        }

        const indent_columns = leadingIndentColumns(line.text);
        if (saw_blank and
            item_lines.items.len == 2 and
            item_lines.items[0].text.len == 0 and
            indent_columns <= marker.content_indent)
        {
            ends_with_blank_line = true;
            break;
        }
        if (saw_blank and indent_columns < marker.content_indent) {
            ends_with_blank_line = true;
            break;
        }
        if (indent_columns < marker.content_indent) {
            if (try isBlockStarter(line.text)) break;
            if (parseSetextUnderline(line.text) != null) break;
        }
        const stripped = try stripIndentColumns(allocator, line.text, marker.content_indent);
        const force_paragraph_text = indent_columns < marker.content_indent and
            ((try isBlockStarter(stripped.text)) or parseSetextUnderline(stripped.text) != null);
        const current_is_paragraph_like = try isParagraphLikeBlockLine(stripped.text);
        try item_lines.append(allocator, .{
            .text = stripped.text,
            .start_offset = line.start_offset + stripped.bytes,
            .end_offset = line.end_offset,
            .block_starter_eligible = !force_paragraph_text,
            .setext_eligible = !force_paragraph_text,
        });
        if (saw_blank and
            (last_nonblank_is_paragraph_like or
                (indent_columns <= marker.content_indent and current_is_paragraph_like)))
        {
            internal_blank_line = true;
        }
        last_nonblank_is_paragraph_like = current_is_paragraph_like;
        saw_blank = false;
        consumed += 1;
    }
    if (saw_blank) ends_with_blank_line = true;

    const children = try parseBlocks(context, item_lines.items, depth);
    if (collect_definitions_only) {
        return .{
            .consumed = consumed,
        };
    }
    const had_blank_line = classifyListItemBlankLines(children, internal_blank_line);
    return .{
        .node = .{
            .kind = .list_item,
            .children = children,
            .task = task != null,
            .checked = if (task) |marker_task| marker_task.checked else false,
            .span_start = @intCast(lines[0].start_offset),
            .span_end = @intCast(lines[consumed - 1].end_offset),
        },
        .consumed = consumed,
        .had_blank_line = had_blank_line,
        .ends_with_blank_line = ends_with_blank_line,
    };
}

fn parseParagraph(
    context: *ParseContext,
    lines: []const Line,
    depth: usize,
) (std.mem.Allocator.Error || ParseError)!ParsedNode {
    const allocator = context.allocator;
    var paragraph_lines: std.ArrayList(Line) = .empty;
    defer paragraph_lines.deinit(allocator);

    var consumed: usize = 0;
    while (consumed < lines.len) : (consumed += 1) {
        const line = lines[consumed];
        if (isBlank(line.text)) break;
        if (consumed != 0 and line.block_starter_eligible and try isParagraphTerminator(line.text)) break;
        if (consumed != 0 and line.setext_eligible and parseSetextUnderline(line.text) != null) break;
        try paragraph_lines.append(allocator, line);
    }

    const definition_lines = try consumeLeadingLinkDefinitions(context, paragraph_lines.items);
    const content_lines = paragraph_lines.items[definition_lines..];
    if (content_lines.len == 0) {
        return .{
            .consumed = consumed,
        };
    }
    if (context.collectingDefinitions()) {
        return .{
            .consumed = consumed,
        };
    }

    const paragraph_text = try joinParagraphLines(allocator, content_lines);
    const first_indent = @min(leadingIndentColumns(content_lines[0].text), @as(usize, 3));
    const first_stripped = if (first_indent == 0)
        StrippedIndent{ .text = content_lines[0].text, .bytes = 0 }
    else
        try stripIndentColumns(allocator, content_lines[0].text, first_indent);
    const children = try parseInlines(
        context,
        paragraph_text,
        content_lines[0].start_offset + first_stripped.bytes,
        depth,
    );

    return .{
        .node = .{
            .kind = .paragraph,
            .children = children,
            .span_start = @intCast(content_lines[0].start_offset),
            .span_end = @intCast(content_lines[content_lines.len - 1].end_offset),
        },
        .consumed = consumed,
    };
}

fn parseTable(
    context: *ParseContext,
    lines: []const Line,
    depth: usize,
) (std.mem.Allocator.Error || ParseError)!?ParsedNode {
    const allocator = context.allocator;
    if (lines.len < 2) return null;

    const header_indent = leadingIndent(lines[0].text);
    const delimiter_indent = leadingIndent(lines[1].text);
    if (header_indent > 3 or delimiter_indent > 3) return null;

    const header_text = lines[0].text[header_indent..];
    const delimiter_text = lines[1].text[delimiter_indent..];

    const header_row = try parseTableRowText(allocator, header_text);
    if (!header_row.has_separator) return null;

    const alignments = try parseTableDelimiterRow(allocator, delimiter_text);
    if (alignments.len == 0 or header_row.cells.len != alignments.len) return null;

    const head_row = try buildTableRow(
        context,
        lines[0],
        header_indent,
        header_row.cells,
        alignments,
        depth,
    );

    const head_rows = try allocator.alloc(Node, 1);
    head_rows[0] = head_row;
    const head: Node = .{
        .kind = .table_head,
        .children = head_rows,
        .span_start = @intCast(lines[0].start_offset),
        .span_end = @intCast(lines[0].end_offset),
    };

    var table_children: std.ArrayList(Node) = .empty;
    defer table_children.deinit(allocator);
    try table_children.append(allocator, head);

    var body_rows: std.ArrayList(Node) = .empty;
    defer body_rows.deinit(allocator);

    var consumed: usize = 2;
    while (consumed < lines.len) {
        const line = lines[consumed];
        if (isBlank(line.text)) break;
        if (try isBlockStarter(line.text)) break;

        const body_indent = leadingIndent(line.text);
        if (body_indent > 3) break;

        const body_text = line.text[body_indent..];
        const row = try parseTableRowText(allocator, body_text);

        const body_row = try buildTableRow(
            context,
            line,
            body_indent,
            row.cells,
            alignments,
            depth,
        );
        try body_rows.append(allocator, body_row);
        consumed += 1;
    }

    if (body_rows.items.len != 0) {
        const body_children = try body_rows.toOwnedSlice(allocator);
        try table_children.append(allocator, .{
            .kind = .table_body,
            .children = body_children,
            .span_start = body_children[0].span_start,
            .span_end = body_children[body_children.len - 1].span_end,
        });
    }

    const children = try table_children.toOwnedSlice(allocator);
    const last = lines[consumed - 1];
    return .{
        .node = .{
            .kind = .table,
            .children = children,
            .span_start = @intCast(lines[0].start_offset),
            .span_end = @intCast(last.end_offset),
        },
        .consumed = consumed,
    };
}

fn tableConsumed(
    allocator: std.mem.Allocator,
    lines: []const Line,
) (std.mem.Allocator.Error || ParseError)!?usize {
    if (lines.len < 2) return null;

    const header_indent = leadingIndent(lines[0].text);
    const delimiter_indent = leadingIndent(lines[1].text);
    if (header_indent > 3 or delimiter_indent > 3) return null;

    const header_text = lines[0].text[header_indent..];
    const delimiter_text = lines[1].text[delimiter_indent..];

    const header_row = try parseTableRowText(allocator, header_text);
    defer allocator.free(header_row.cells);
    if (!header_row.has_separator) return null;

    const alignments = try parseTableDelimiterRow(allocator, delimiter_text);
    defer allocator.free(alignments);
    if (alignments.len == 0 or header_row.cells.len != alignments.len) return null;

    var consumed: usize = 2;
    while (consumed < lines.len) {
        const line = lines[consumed];
        if (isBlank(line.text)) break;
        if (try isBlockStarter(line.text)) break;

        const body_indent = leadingIndent(line.text);
        if (body_indent > 3) break;

        const body_text = line.text[body_indent..];
        const row = try parseTableRowText(allocator, body_text);
        defer allocator.free(row.cells);
        if (row.cells.len == 0) break;
        consumed += 1;
    }

    return consumed;
}

fn buildTableRow(
    context: *ParseContext,
    line: Line,
    indent: usize,
    row_cells: []const TableCellSlice,
    alignments: []const TableAlignment,
    depth: usize,
) (std.mem.Allocator.Error || ParseError)!Node {
    const allocator = context.allocator;
    const cells = try allocator.alloc(Node, alignments.len);

    for (alignments, 0..) |alignment, index| {
        const source_cell = if (index < row_cells.len) row_cells[index] else TableCellSlice{
            .text = "",
            .start = 0,
            .end = 0,
        };
        const cell_text = try unescapeTablePipes(allocator, source_cell.text);
        const inlines = try parseInlines(
            context,
            cell_text,
            line.start_offset + indent + source_cell.start,
            depth + 1,
        );
        cells[index] = .{
            .kind = .table_cell,
            .children = inlines,
            .alignment = alignment,
            .span_start = @intCast(line.start_offset + indent + source_cell.start),
            .span_end = @intCast(line.start_offset + indent + source_cell.end),
        };
    }

    return .{
        .kind = .table_row,
        .children = cells,
        .span_start = @intCast(line.start_offset),
        .span_end = @intCast(line.end_offset),
    };
}

fn parseTableDelimiterRow(
    allocator: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]const TableAlignment {
    const row = try parseTableRowText(allocator, text);
    if (!row.has_separator) return &.{};

    const alignments = try allocator.alloc(TableAlignment, row.cells.len);
    for (row.cells, 0..) |cell, index| {
        alignments[index] = parseTableAlignment(cell.text) orelse return &.{};
    }
    return alignments;
}

fn parseTableAlignment(text: []const u8) ?TableAlignment {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;

    const start_colon = trimmed[0] == ':';
    const end_colon = trimmed[trimmed.len - 1] == ':';
    const body_start: usize = if (start_colon) 1 else 0;
    const body_end: usize = trimmed.len - if (end_colon) @as(usize, 1) else @as(usize, 0);
    if (body_start >= body_end) return null;

    for (trimmed[body_start..body_end]) |byte| {
        if (byte != '-') return null;
    }

    return if (start_colon and end_colon)
        .center
    else if (start_colon)
        .left
    else if (end_colon)
        .right
    else
        .none;
}

fn parseTableRowText(
    allocator: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error!struct {
    cells: []const TableCellSlice,
    has_separator: bool,
} {
    var working = text;
    var offset: usize = 0;

    working = std.mem.trimStart(u8, working, " \t");
    offset = text.len - working.len;
    const leading_trimmed = working;
    working = std.mem.trimEnd(u8, working, " \t");
    const trailing_trimmed_len = leading_trimmed.len - working.len;

    if (working.len == 0) {
        return .{
            .cells = &.{},
            .has_separator = false,
        };
    }

    var inner_start: usize = 0;
    var inner_end: usize = working.len;
    if (working[0] == '|') inner_start += 1;
    if (inner_end > inner_start and working[inner_end - 1] == '|') inner_end -= 1;

    var cells: std.ArrayList(TableCellSlice) = .empty;
    defer cells.deinit(allocator);

    var segment_start = inner_start;
    var index = inner_start;
    var has_separator = inner_start != 0 or inner_end != working.len;
    while (index < inner_end) {
        const byte = working[index];
        if (byte == '\\' and index + 1 < inner_end) {
            index += 2;
            continue;
        }
        if (byte == '`') {
            const tick_count = delimiterRun(working, index, '`');
            if (findClosingRun(working, index + tick_count, '`', tick_count)) |close_index| {
                index = close_index + tick_count;
                continue;
            }
        }
        if (byte == '|') {
            has_separator = true;
            try cells.append(allocator, trimTableCellSlice(working, offset, segment_start, index));
            segment_start = index + 1;
        }
        index += 1;
    }

    try cells.append(allocator, trimTableCellSlice(working, offset, segment_start, inner_end));
    _ = trailing_trimmed_len;

    return .{
        .cells = try cells.toOwnedSlice(allocator),
        .has_separator = has_separator,
    };
}

fn trimTableCellSlice(
    line: []const u8,
    offset: usize,
    raw_start: usize,
    raw_end: usize,
) TableCellSlice {
    var start = raw_start;
    var end = raw_end;
    while (start < end and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
    while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}
    return .{
        .text = line[start..end],
        .start = offset + start,
        .end = offset + end,
    };
}

fn unescapeTablePipes(
    allocator: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, text, "\\|") == null) return text;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\\' and index + 1 < text.len and text[index + 1] == '|') {
            try buffer.append(allocator, '|');
            index += 2;
            continue;
        }
        try buffer.append(allocator, text[index]);
        index += 1;
    }

    return buffer.toOwnedSlice(allocator);
}

fn parseHtmlBlock(
    allocator: std.mem.Allocator,
    lines: []const Line,
    kind: HtmlBlockKind,
) std.mem.Allocator.Error!ParsedNode {
    var consumed: usize = 1;

    switch (kind) {
        .none => unreachable,
        .raw_tag => {
            const closing_tag = rawHtmlClosingTag(lines[0].text) orelse "";
            while (consumed < lines.len and !containsHtmlClosingTag(lines[consumed - 1].text, closing_tag)) {
                consumed += 1;
            }
        },
        .comment => {
            while (consumed < lines.len and std.mem.indexOf(u8, lines[consumed - 1].text, "-->") == null) {
                consumed += 1;
            }
        },
        .instruction => {
            while (consumed < lines.len and std.mem.indexOf(u8, lines[consumed - 1].text, "?>") == null) {
                consumed += 1;
            }
        },
        .declaration => {
            while (consumed < lines.len and std.mem.indexOfScalar(u8, lines[consumed - 1].text, '>') == null) {
                consumed += 1;
            }
        },
        .cdata => {
            while (consumed < lines.len and std.mem.indexOf(u8, lines[consumed - 1].text, "]]>") == null) {
                consumed += 1;
            }
        },
        .block_tag => {
            while (consumed < lines.len and !isBlank(lines[consumed].text)) {
                consumed += 1;
            }
        },
        .type7 => {
            while (consumed < lines.len and !isBlank(lines[consumed].text)) {
                consumed += 1;
            }
        },
    }

    var captured: std.ArrayList([]const u8) = .empty;
    defer captured.deinit(allocator);
    for (lines[0..consumed]) |line| {
        try captured.append(allocator, line.text);
    }

    const source = try joinLines(allocator, captured.items);
    const last = lines[consumed - 1];
    return .{
        .node = .{
            .kind = .html_block,
            .text = source,
            .html_block_type = kind,
            .span_start = @intCast(lines[0].start_offset),
            .span_end = @intCast(last.end_offset),
        },
        .consumed = consumed,
    };
}

fn htmlBlockConsumed(lines: []const Line, kind: HtmlBlockKind) usize {
    var consumed: usize = 1;

    switch (kind) {
        .none => unreachable,
        .raw_tag => {
            const closing_tag = rawHtmlClosingTag(lines[0].text) orelse "";
            while (consumed < lines.len and !containsHtmlClosingTag(lines[consumed - 1].text, closing_tag)) {
                consumed += 1;
            }
        },
        .comment => {
            while (consumed < lines.len and std.mem.indexOf(u8, lines[consumed - 1].text, "-->") == null) {
                consumed += 1;
            }
        },
        .instruction => {
            while (consumed < lines.len and std.mem.indexOf(u8, lines[consumed - 1].text, "?>") == null) {
                consumed += 1;
            }
        },
        .declaration => {
            while (consumed < lines.len and std.mem.indexOfScalar(u8, lines[consumed - 1].text, '>') == null) {
                consumed += 1;
            }
        },
        .cdata => {
            while (consumed < lines.len and std.mem.indexOf(u8, lines[consumed - 1].text, "]]>") == null) {
                consumed += 1;
            }
        },
        .block_tag, .type7 => {
            while (consumed < lines.len and !isBlank(lines[consumed].text)) {
                consumed += 1;
            }
        },
    }

    return consumed;
}

fn parseIndentedCodeBlock(
    allocator: std.mem.Allocator,
    lines: []const Line,
) std.mem.Allocator.Error!ParsedNode {
    std.debug.assert(lines.len != 0);
    std.debug.assert(isIndentedCodeLine(lines[0].text));

    var captured: std.ArrayList([]const u8) = .empty;
    defer captured.deinit(allocator);

    var consumed: usize = 0;
    while (consumed < lines.len) {
        const line = lines[consumed];
        if (isBlank(line.text)) {
            const blank_text = if (leadingIndentColumns(line.text) >= 4)
                (try stripIndentColumns(allocator, line.text, 4)).text
            else
                "";
            try captured.append(allocator, blank_text);
            consumed += 1;
            continue;
        }
        if (!isIndentedCodeLine(line.text)) break;

        const stripped = try stripIndentColumns(allocator, line.text, 4);
        try captured.append(allocator, stripped.text);
        consumed += 1;
    }

    while (captured.items.len != 0 and captured.items[captured.items.len - 1].len == 0) {
        _ = captured.pop();
    }

    const text = try joinLines(allocator, captured.items);
    return .{
        .node = .{
            .kind = .code_block,
            .text = text,
            .span_start = @intCast(lines[0].start_offset),
            .span_end = @intCast(lines[consumed - 1].end_offset),
        },
        .consumed = consumed,
    };
}

fn indentedCodeBlockConsumed(lines: []const Line) usize {
    var consumed: usize = 0;
    while (consumed < lines.len) {
        const line = lines[consumed];
        if (isBlank(line.text)) {
            consumed += 1;
            continue;
        }
        if (!isIndentedCodeLine(line.text)) break;
        consumed += 1;
    }
    return consumed;
}

fn parseInlines(
    context: *ParseContext,
    text: []const u8,
    base_offset: usize,
    depth: usize,
) (std.mem.Allocator.Error || ParseError)![]Node {
    return parseInlinesWithOptions(context, text, base_offset, depth, .{});
}

fn parseInlinesWithOptions(
    context: *ParseContext,
    text: []const u8,
    base_offset: usize,
    depth: usize,
    options: InlineParseOptions,
) (std.mem.Allocator.Error || ParseError)![]Node {
    const allocator = context.allocator;
    if (depth > max_nesting) return error.NestingLimitExceeded;

    var pieces: std.ArrayList(InlinePiece) = .empty;
    defer pieces.deinit(allocator);

    var text_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\n') {
            const break_info = classifyLineBreak(text, text_start, index);
            try appendTextRangePiece(
                allocator,
                &pieces,
                text[text_start..break_info.content_end],
                base_offset + text_start,
            );
            try pieces.append(allocator, .{
                .node = .{
                    .kind = break_info.kind,
                    .span_start = @intCast(base_offset + index),
                    .span_end = @intCast(base_offset + index),
                },
            });
            index += 1;
            text_start = index;
            continue;
        }

        if (byte == '\\' and index + 1 < text.len) {
            if (isEscapableAsciiPunctuation(text[index + 1])) {
                try appendTextRangePiece(allocator, &pieces, text[text_start..index], base_offset + text_start);
                try pieces.append(allocator, .{
                    .node = .{
                        .kind = .text,
                        .text = text[index + 1 .. index + 2],
                        .span_start = @intCast(base_offset + index),
                        .span_end = @intCast(base_offset + index + 2),
                    },
                });
                index += 2;
                text_start = index;
                continue;
            }
            index += 1;
            continue;
        }

        if (byte == '!' and index + 1 < text.len and text[index + 1] == '[') {
            if (try parseLinkLikeNode(
                context,
                text,
                index,
                index + 1,
                base_offset + index,
                depth,
                .image,
            )) |parsed| {
                try appendTextRangePiece(allocator, &pieces, text[text_start..index], base_offset + text_start);
                try pieces.append(allocator, .{ .node = parsed.node.? });
                index = parsed.consumed;
                text_start = index;
                continue;
            }
            index += 1;
            continue;
        }

        if (context.options.autolink_literals and options.allow_links and couldStartAutolinkLiteral(byte)) {
            if (try parseAutolinkLiteralNode(context, text, index, base_offset + index)) |parsed| {
                try appendTextRangePiece(allocator, &pieces, text[text_start..index], base_offset + text_start);
                try pieces.append(allocator, .{ .node = parsed.node.? });
                index = parsed.consumed;
                text_start = index;
                continue;
            }
        }

        if (byte == '<') {
            if (options.allow_links) {
                if (try parseAutolinkNode(context, text, index, base_offset + index)) |parsed| {
                    try appendTextRangePiece(allocator, &pieces, text[text_start..index], base_offset + text_start);
                    try pieces.append(allocator, .{ .node = parsed.node.? });
                    index = parsed.consumed;
                    text_start = index;
                    continue;
                }
            }

            if (parseInlineHtmlEnd(text, index)) |end| {
                try appendTextRangePiece(allocator, &pieces, text[text_start..index], base_offset + text_start);
                try pieces.append(allocator, .{
                    .node = .{
                        .kind = .html_inline,
                        .text = text[index..end],
                        .span_start = @intCast(base_offset + index),
                        .span_end = @intCast(base_offset + end),
                    },
                });
                index = end;
                text_start = index;
                continue;
            }
        }

        if (byte == '`') {
            const count = delimiterRun(text, index, '`');
            if (findClosingRun(text, index + count, '`', count)) |close_index| {
                try appendTextRangePiece(allocator, &pieces, text[text_start..index], base_offset + text_start);
                const code_text = try normalizeCodeSpanText(
                    allocator,
                    text[index + count .. close_index],
                );
                try pieces.append(allocator, .{
                    .node = .{
                        .kind = .code_span,
                        .text = code_text,
                        .span_start = @intCast(base_offset + index),
                        .span_end = @intCast(base_offset + close_index + count),
                    },
                });
                index = close_index + count;
                text_start = index;
                continue;
            }
            index += count;
            continue;
        }

        if (options.allow_links and byte == '[') {
            if (try parseLinkLikeNode(
                context,
                text,
                index,
                index,
                base_offset + index,
                depth,
                .link,
            )) |parsed| {
                try appendTextRangePiece(allocator, &pieces, text[text_start..index], base_offset + text_start);
                try pieces.append(allocator, .{ .node = parsed.node.? });
                index = parsed.consumed;
                text_start = index;
                continue;
            }
            index += 1;
            continue;
        }

        if (byte == '~' or byte == '*' or byte == '_') {
            const delimiter = analyzeDelimiterRun(text, index, byte);
            const count = delimiter.count;
            try appendTextRangePiece(allocator, &pieces, text[text_start..index], base_offset + text_start);

            const piece: InlinePiece = .{
                .node = .{
                    .kind = .text,
                    .text = text[index .. index + count],
                    .span_start = @intCast(base_offset + index),
                    .span_end = @intCast(base_offset + index + count),
                },
                .delimiter = if (byte == '~' and count < 2)
                    null
                else if (delimiter.can_open or delimiter.can_close)
                    .{
                        .marker = byte,
                        .length = count,
                        .can_open = delimiter.can_open,
                        .can_close = delimiter.can_close,
                        .original_can_open = delimiter.can_open,
                        .original_can_close = delimiter.can_close,
                    }
                else
                    null,
            };
            try pieces.append(allocator, piece);
            index += count;
            text_start = index;
            continue;
        }

        index += 1;
    }

    try appendTextRangePiece(allocator, &pieces, text[text_start..], base_offset + text_start);
    return resolveInlineDelimiters(allocator, pieces.items);
}

fn joinParagraphLines(
    allocator: std.mem.Allocator,
    lines: []const Line,
) std.mem.Allocator.Error![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    for (lines, 0..) |line, line_index| {
        const max_indent = if (line_index == 0)
            @min(leadingIndentColumns(line.text), @as(usize, 3))
        else
            leadingIndentColumns(line.text);
        const stripped = if (max_indent == 0)
            StrippedIndent{ .text = line.text, .bytes = 0 }
        else
            try stripIndentColumns(allocator, line.text, max_indent);
        const text = if (line_index + 1 == lines.len)
            std.mem.trimEnd(u8, stripped.text, " \t")
        else
            stripped.text;
        try buffer.appendSlice(allocator, text);
        if (line_index + 1 < lines.len) {
            try buffer.append(allocator, '\n');
        }
    }

    return buffer.toOwnedSlice(allocator);
}

fn classifyLineBreak(
    text: []const u8,
    text_start: usize,
    newline_index: usize,
) struct {
    kind: NodeKind,
    content_end: usize,
} {
    var content_end = newline_index;

    var backslash_run: usize = 0;
    while (content_end > text_start and text[content_end - 1] == '\\') {
        content_end -= 1;
        backslash_run += 1;
    }
    if (backslash_run % 2 == 1) {
        return .{
            .kind = .hard_break,
            .content_end = newline_index - 1,
        };
    }

    content_end = newline_index;
    var trailing_spaces: usize = 0;
    while (content_end > text_start and text[content_end - 1] == ' ') {
        content_end -= 1;
        trailing_spaces += 1;
    }
    if (trailing_spaces >= 2) {
        return .{
            .kind = .hard_break,
            .content_end = content_end,
        };
    }

    content_end = newline_index;
    while (content_end > text_start and (text[content_end - 1] == ' ' or text[content_end - 1] == '\t')) {
        content_end -= 1;
    }

    return .{
        .kind = .soft_break,
        .content_end = content_end,
    };
}

fn parseDelimiterNode(
    context: *ParseContext,
    text: []const u8,
    start: usize,
    span_start: usize,
    depth: usize,
    marker: u8,
    options: InlineParseOptions,
) (std.mem.Allocator.Error || ParseError)!?ParsedNode {
    const opener = analyzeDelimiterRun(text, start, marker);
    if (!opener.can_open) return null;

    const closer = findDelimiterCloser(text, start + opener.count, marker, opener) orelse
        return null;
    const used_count = closer.used_count;
    const inner_start = start + used_count;
    const inner_end = closer.index + closer.count - used_count;

    const inner = try parseInlinesWithOptions(
        context,
        text[inner_start..inner_end],
        span_start + used_count,
        depth + 1,
        options,
    );

    return .{
        .node = .{
            .kind = switch (marker) {
                '~' => .strikethrough,
                else => if (used_count == 2) .strong else .emphasis,
            },
            .children = inner,
            .span_start = @intCast(span_start),
            .span_end = @intCast(span_start + closer.index + closer.count - start),
        },
        .consumed = closer.index + closer.count,
    };
}

fn parseLinkLikeNode(
    context: *ParseContext,
    text: []const u8,
    whole_start: usize,
    start: usize,
    span_start: usize,
    depth: usize,
    kind: NodeKind,
) (std.mem.Allocator.Error || ParseError)!?ParsedNode {
    std.debug.assert(text[start] == '[');

    const label_end = findClosingLinkLabel(text, start) orelse return null;
    const label = text[start + 1 .. label_end];
    const label_span_start = span_start + (start - whole_start) + 1;
    if (kind == .link and try labelContainsLinks(context, label, label_span_start, depth + 1)) {
        return null;
    }
    const label_options: InlineParseOptions = if (kind == .link)
        .{ .allow_links = false }
    else
        .{};

    if (label_end + 1 < text.len and text[label_end + 1] == '(') {
        if (try parseInlineLinkTarget(context.allocator, text, label_end + 2)) |parsed_target| {
            const children = try parseInlinesWithOptions(
                context,
                label,
                label_span_start,
                depth + 1,
                label_options,
            );

            return .{
                .node = .{
                    .kind = kind,
                    .children = children,
                    .destination = parsed_target.target.destination,
                    .title = parsed_target.target.title,
                    .span_start = @intCast(span_start),
                    .span_end = @intCast(span_start + parsed_target.consumed + (label_end + 2) - whole_start + 1),
                },
                .consumed = label_end + 2 + parsed_target.consumed + 1,
            };
        }
    }

    if (try parseReferenceLinkLikeNode(
        context,
        text,
        whole_start,
        label,
        label_end,
        label_span_start,
        span_start,
        depth,
        kind,
    )) |parsed| {
        return parsed;
    }

    return null;
}

fn labelContainsLinks(
    context: *ParseContext,
    label: []const u8,
    span_start: usize,
    depth: usize,
) (std.mem.Allocator.Error || ParseError)!bool {
    const nodes = try parseInlinesWithOptions(
        context,
        label,
        span_start,
        depth,
        .{},
    );
    return nodesContainKind(nodes, .link);
}

fn findClosingLinkLabel(text: []const u8, start: usize) ?usize {
    std.debug.assert(start < text.len);
    std.debug.assert(text[start] == '[');

    var depth: usize = 0;
    var index = start + 1;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\\' and index + 1 < text.len and isEscapableAsciiPunctuation(text[index + 1])) {
            index += 2;
            continue;
        }

        if (byte == '`') {
            const tick_count = delimiterRun(text, index, '`');
            if (findClosingRun(text, index + tick_count, '`', tick_count)) |close_index| {
                index = close_index + tick_count;
                continue;
            }
            index += tick_count;
            continue;
        }

        if (byte == '<') {
            if (findAngleAutolinkEnd(text, index)) |end| {
                index = end;
                continue;
            }
            if (parseInlineHtmlEnd(text, index)) |end| {
                index = end;
                continue;
            }
        }

        if (byte == '[') {
            depth += 1;
            index += 1;
            continue;
        }

        if (byte == ']') {
            if (depth == 0) return index;
            depth -= 1;
            index += 1;
            continue;
        }

        index += 1;
    }

    return null;
}

fn findClosingReferenceLabel(text: []const u8, start: usize) ?usize {
    std.debug.assert(start < text.len);
    std.debug.assert(text[start] == '[');

    var index = start + 1;
    while (index < text.len) {
        if (text[index] == '\\' and index + 1 < text.len and isEscapableAsciiPunctuation(text[index + 1])) {
            index += 2;
            continue;
        }
        if (text[index] == '[') return null;
        if (text[index] == ']') return index;
        index += 1;
    }

    return null;
}

fn parseInlineLinkTarget(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: usize,
) std.mem.Allocator.Error!?ParsedLinkTarget {
    var index = skipLinkWhitespace(text, start);
    if (index >= text.len) return null;
    if (text[index] == ')') {
        return .{
            .target = .{
                .destination = "",
                .title = "",
            },
            .consumed = index - start,
        };
    }
    const parsed_destination = parseLinkDestinationToken(text, index) orelse return null;
    const destination = if (parsed_destination.destination.len == 0)
        ""
    else
        try normalizeTextFragment(allocator, parsed_destination.destination);
    index = parsed_destination.end;

    index = skipLinkWhitespace(text, index);
    if (index >= text.len) return null;
    if (text[index] == ')') {
        return .{
            .target = .{
                .destination = destination,
                .title = "",
            },
            .consumed = index - start,
        };
    }

    const title = parseLinkTitleToken(text, index) orelse return null;
    const normalized_title = try normalizeTextFragment(allocator, title.value);
    index = skipLinkWhitespace(text, title.end);
    if (index >= text.len or text[index] != ')') return null;

    return .{
        .target = .{
            .destination = destination,
            .title = normalized_title,
        },
        .consumed = index - start,
    };
}

fn parseLinkDestinationToken(text: []const u8, start: usize) ?ParsedLinkDestination {
    if (start >= text.len) return null;

    if (text[start] == '<') {
        var index = start + 1;
        while (index < text.len) : (index += 1) {
            switch (text[index]) {
                '>' => return .{
                    .destination = text[start + 1 .. index],
                    .end = index + 1,
                },
                '\n', '\r', '<', '\\' => return null,
                else => {},
            }
        }
        return null;
    }

    const destination_start = start;
    var index = start;
    var paren_depth: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\\' and index + 1 < text.len) {
            index += if (isEscapableAsciiPunctuation(text[index + 1])) 2 else 1;
            continue;
        }
        if (byte == '(') {
            paren_depth += 1;
            index += 1;
            continue;
        }
        if (byte == ')') {
            if (paren_depth == 0) break;
            paren_depth -= 1;
            index += 1;
            continue;
        }
        if (std.ascii.isWhitespace(byte) and paren_depth == 0) break;
        index += 1;
    }

    if (index == destination_start) return null;
    return .{
        .destination = text[destination_start..index],
        .end = index,
    };
}

fn parseReferenceLinkLikeNode(
    context: *ParseContext,
    text: []const u8,
    whole_start: usize,
    label: []const u8,
    label_end: usize,
    label_span_start: usize,
    span_start: usize,
    depth: usize,
    kind: NodeKind,
) (std.mem.Allocator.Error || ParseError)!?ParsedNode {
    const allocator = context.allocator;

    var reference_label = label;
    var consumed = label_end + 1;

    if (label_end + 1 < text.len and text[label_end + 1] == '[') {
        const reference_end = findClosingReferenceLabel(text, label_end + 1) orelse return null;
        reference_label = text[label_end + 2 .. reference_end];
        if (reference_label.len == 0) reference_label = label;
        consumed = reference_end + 1;
    }

    const normalized_label = try normalizeLinkLabel(allocator, reference_label);
    const target = context.getDefinition(normalized_label) orelse return null;
    const label_options: InlineParseOptions = if (kind == .link)
        .{ .allow_links = false }
    else
        .{};
    const children = try parseInlinesWithOptions(
        context,
        label,
        label_span_start,
        depth + 1,
        label_options,
    );

    return .{
        .node = .{
            .kind = kind,
            .children = children,
            .destination = target.destination,
            .title = target.title,
            .span_start = @intCast(span_start),
            .span_end = @intCast(span_start + consumed - whole_start),
        },
        .consumed = consumed,
    };
}

fn parseAutolinkNode(
    context: *ParseContext,
    text: []const u8,
    start: usize,
    span_start: usize,
) std.mem.Allocator.Error!?ParsedNode {
    const allocator = context.allocator;
    const end = findAngleAutolinkEnd(text, start) orelse return null;
    const inner = text[start + 1 .. end - 1];

    var destination = inner;
    if (!isAutolinkUri(inner)) {
        if (!isAutolinkEmail(inner)) return null;
        destination = try std.fmt.allocPrint(allocator, "mailto:{s}", .{inner});
    } else {
        destination = try normalizeAutolinkUriDestination(allocator, inner);
    }

    const children = try allocator.alloc(Node, 1);
    children[0] = .{
        .kind = .text,
        .text = inner,
        .span_start = @intCast(span_start + 1),
        .span_end = @intCast(span_start + 1 + inner.len),
    };

    return .{
        .node = .{
            .kind = .link,
            .children = children,
            .destination = destination,
            .span_start = @intCast(span_start),
            .span_end = @intCast(span_start + end - start),
        },
        .consumed = end,
    };
}

fn findAngleAutolinkEnd(text: []const u8, start: usize) ?usize {
    if (start + 1 >= text.len or text[start] != '<') return null;
    const end = std.mem.indexOfScalarPos(u8, text, start + 1, '>') orelse return null;
    const inner = text[start + 1 .. end];
    if (inner.len == 0) return null;
    if (std.mem.indexOfAny(u8, inner, " \t\r\n<>") != null) return null;
    if (!isAutolinkUri(inner) and !isAutolinkEmail(inner)) return null;
    return end + 1;
}

fn parseAutolinkLiteralNode(
    context: *ParseContext,
    text: []const u8,
    start: usize,
    span_start: usize,
) std.mem.Allocator.Error!?ParsedNode {
    const allocator = context.allocator;
    if (!isAutolinkLiteralStartBoundary(text, start)) return null;

    if (try parseUriLiteral(allocator, text, start)) |literal| {
        return .{
            .node = .{
                .kind = .link,
                .children = try textNodeChildren(allocator, literal.text, span_start),
                .destination = literal.destination,
                .span_start = @intCast(span_start),
                .span_end = @intCast(span_start + literal.text.len),
            },
            .consumed = literal.consumed,
        };
    }

    if (try parseEmailLiteral(allocator, text, start)) |literal| {
        return .{
            .node = .{
                .kind = .link,
                .children = try textNodeChildren(allocator, literal.text, span_start),
                .destination = literal.destination,
                .span_start = @intCast(span_start),
                .span_end = @intCast(span_start + literal.text.len),
            },
            .consumed = literal.consumed,
        };
    }

    return null;
}

fn parseUriLiteral(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: usize,
) std.mem.Allocator.Error!?AutolinkLiteral {
    const remainder = text[start..];

    var requires_prefix = false;
    if (std.ascii.startsWithIgnoreCase(remainder, "http://") or
        std.ascii.startsWithIgnoreCase(remainder, "https://") or
        std.ascii.startsWithIgnoreCase(remainder, "ftp://"))
    {
        requires_prefix = false;
    } else if (std.ascii.startsWithIgnoreCase(remainder, "www.")) {
        requires_prefix = true;
    } else {
        return null;
    }

    var end = start;
    while (end < text.len and !isAutolinkLiteralTerminator(text[end])) : (end += 1) {}
    end = trimUriLiteralEnd(text, start, end);
    if (end <= start) return null;

    const display = text[start..end];
    if (requires_prefix and !hasWwwLiteralHost(display)) return null;
    if (!requires_prefix and !hasUriLiteralBody(display)) return null;

    return .{
        .text = display,
        .destination = if (requires_prefix)
            try std.fmt.allocPrint(allocator, "http://{s}", .{display})
        else
            display,
        .consumed = end,
    };
}

fn parseEmailLiteral(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: usize,
) std.mem.Allocator.Error!?AutolinkLiteral {
    if (!isEmailLiteralStartByte(text[start])) return null;

    var end = start;
    while (end < text.len and isEmailLiteralByte(text[end])) : (end += 1) {}
    if (end == start) return null;

    end = trimEmailLiteralEnd(text, start, end);
    if (end <= start) return null;

    const display = text[start..end];
    if (!isAutolinkEmail(display)) return null;

    return .{
        .text = display,
        .destination = try std.fmt.allocPrint(allocator, "mailto:{s}", .{display}),
        .consumed = end,
    };
}

fn textNodeChildren(
    allocator: std.mem.Allocator,
    text: []const u8,
    span_start: usize,
) std.mem.Allocator.Error![]Node {
    const children = try allocator.alloc(Node, 1);
    children[0] = .{
        .kind = .text,
        .text = text,
        .span_start = @intCast(span_start),
        .span_end = @intCast(span_start + text.len),
    };
    return children;
}

fn couldStartAutolinkLiteral(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

fn isAutolinkLiteralStartBoundary(text: []const u8, start: usize) bool {
    if (start == 0) return true;
    const prev = text[start - 1];
    if (std.ascii.isAlphanumeric(prev)) return false;
    return switch (prev) {
        '_', '@', '/', '\\', '.', '-', '<' => false,
        else => true,
    };
}

fn isAutolinkLiteralTerminator(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '<';
}

fn trimUriLiteralEnd(text: []const u8, start: usize, candidate_end: usize) usize {
    var end = candidate_end;
    while (end > start) {
        const byte = text[end - 1];
        switch (byte) {
            '.', ',', ':', ';', '!', '?', '*', '_', '~' => {
                end -= 1;
                continue;
            },
            ')' => {
                if (countByte(text[start..end], '(') < countByte(text[start..end], ')')) {
                    end -= 1;
                    continue;
                }
            },
            ']' => {
                if (countByte(text[start..end], '[') < countByte(text[start..end], ']')) {
                    end -= 1;
                    continue;
                }
            },
            else => {},
        }
        break;
    }
    if (std.mem.lastIndexOfScalar(u8, text[start..end], '&')) |relative_amp| {
        const amp = start + relative_amp;
        const suffix = text[amp + 1 .. end];
        if (suffix.len != 0 and std.mem.indexOfScalar(u8, suffix, '=') == null) {
            const entity_name = if (suffix[suffix.len - 1] == ';')
                suffix[0 .. suffix.len - 1]
            else
                suffix;
            if (entity_name.len != 0) {
                var all_alpha = true;
                for (entity_name) |byte| {
                    if (!std.ascii.isAlphabetic(byte)) {
                        all_alpha = false;
                        break;
                    }
                }
                if (all_alpha) end = amp;
            }
        }
    }
    return end;
}

fn trimEmailLiteralEnd(text: []const u8, start: usize, candidate_end: usize) usize {
    var end = candidate_end;
    while (end > start) {
        switch (text[end - 1]) {
            '.', ',', ':', ';', '!', '?', ')', ']' => end -= 1,
            else => break,
        }
    }
    return end;
}

fn hasUriLiteralBody(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "/?#@") != null or
        std.mem.indexOfScalar(u8, text, '.') != null;
}

fn hasWwwLiteralHost(text: []const u8) bool {
    if (text.len <= 4) return false;
    return std.mem.indexOfScalarPos(u8, text, 4, '.') != null;
}

fn isEmailLiteralStartByte(byte: u8) bool {
    return isEmailAtomByte(byte) or byte == '_';
}

fn isEmailLiteralByte(byte: u8) bool {
    return isEmailAtomByte(byte) or byte == '.' or byte == '@';
}

fn countByte(text: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte == needle) count += 1;
    }
    return count;
}

fn consumeLeadingLinkDefinitions(
    context: *ParseContext,
    lines: []const Line,
) std.mem.Allocator.Error!usize {
    var consumed: usize = 0;
    while (consumed < lines.len) {
        const definition_consumed = try parseLinkDefinition(context, lines[consumed..]) orelse break;
        consumed += definition_consumed;
    }
    return consumed;
}

fn parseLinkDefinition(
    context: *ParseContext,
    lines: []const Line,
) std.mem.Allocator.Error!?usize {
    if (lines.len == 0) return null;

    const parsed_label = try parseLinkDefinitionLabel(context.allocator, lines) orelse return null;
    const label = parsed_label.label;
    if (std.mem.trim(u8, label, " \t\r\n").len == 0) return null;

    var best_consumed: usize = 0;
    var best_target: LinkTarget = .{ .destination = "", .title = "" };

    var consumed: usize = parsed_label.consumed;
    while (consumed <= lines.len) : (consumed += 1) {
        if (consumed > parsed_label.consumed) {
            const continuation = lines[consumed - 1];
            if (isBlank(continuation.text)) break;
        }

        const candidate = try joinLinkDefinitionTargetLines(
            context.allocator,
            lines[0..consumed],
            parsed_label,
        );
        const target = (try parseLinkTarget(context.allocator, candidate)) orelse continue;
        best_consumed = consumed;
        best_target = target;
    }

    if (best_consumed == 0) return null;

    const normalized_label = try normalizeLinkLabel(context.allocator, label);
    try context.putDefinition(normalized_label, best_target);
    return best_consumed;
}

const ParsedDefinitionLabel = struct {
    label: []const u8,
    consumed: usize,
    post_colon_offset: usize,
};

fn parseLinkDefinitionLabel(
    allocator: std.mem.Allocator,
    lines: []const Line,
) std.mem.Allocator.Error!?ParsedDefinitionLabel {
    const first_line = lines[0];
    const indent = leadingIndent(first_line.text);
    if (indent > 3 or indent >= first_line.text.len or first_line.text[indent] != '[') return null;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var line_index: usize = 0;
    var segment_start: usize = indent + 1;
    while (line_index < lines.len) : (line_index += 1) {
        const line = lines[line_index].text;
        var index = segment_start;
        while (index < line.len) {
            if (line[index] == '\\' and index + 1 < line.len and isEscapableAsciiPunctuation(line[index + 1])) {
                index += 2;
                continue;
            }
            if (line[index] == '[') return null;
            if (line[index] == ']') {
                if (index + 1 >= line.len or line[index + 1] != ':') return null;
                try buffer.appendSlice(allocator, line[segment_start..index]);
                return .{
                    .label = try buffer.toOwnedSlice(allocator),
                    .consumed = line_index + 1,
                    .post_colon_offset = index + 2,
                };
            }
            index += 1;
        }

        try buffer.appendSlice(allocator, line[segment_start..]);
        if (line_index + 1 < lines.len) {
            try buffer.append(allocator, '\n');
        }
        segment_start = 0;
    }

    return null;
}

fn normalizeLinkLabel(
    allocator: std.mem.Allocator,
    label: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const trimmed = std.mem.trim(u8, label, " \t\r\n");

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var saw_space = false;
    var iterator = uucode.utf8.Iterator.init(trimmed);
    var start: usize = 0;
    while (iterator.next()) |cp| {
        const slice = trimmed[start..iterator.i];
        start = iterator.i;

        if (slice.len == 1 and std.ascii.isWhitespace(slice[0])) {
            saw_space = true;
            continue;
        }
        if (saw_space and buffer.items.len != 0) {
            try buffer.append(allocator, ' ');
        }
        saw_space = false;
        try appendCaseFoldedCodepoints(allocator, &buffer, cp);
    }

    return buffer.toOwnedSlice(allocator);
}

fn isAutolinkUri(text: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return false;
    if (colon < 2 or colon > 32) return false;

    for (text[0..colon], 0..) |byte, index| {
        if (index == 0) {
            if (!std.ascii.isAlphabetic(byte)) return false;
            continue;
        }
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '.' and byte != '-') {
            return false;
        }
    }

    return true;
}

fn isAutolinkEmail(text: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, text, '@') orelse return false;
    if (at == 0 or at + 1 >= text.len) return false;

    for (text[0..at]) |byte| {
        if (!isEmailAtomByte(byte) and byte != '.') return false;
    }

    const domain = text[at + 1 ..];
    if (domain.len == 0 or domain[0] == '.' or domain[domain.len - 1] == '.') return false;
    var saw_dot = false;
    var label_start: usize = 0;
    for (domain, 0..) |byte, index| {
        if (byte == '.') {
            if (index == label_start) return false;
            if (domain[label_start] == '-' or domain[index - 1] == '-') return false;
            saw_dot = true;
            label_start = index + 1;
            continue;
        }
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    }
    if (label_start >= domain.len or domain[label_start] == '-' or domain[domain.len - 1] == '-') return false;
    return saw_dot;
}

fn isEmailAtomByte(byte: u8) bool {
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~' => true,
        else => std.ascii.isAlphanumeric(byte),
    };
}

fn appendAll(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Node),
    items: []const Node,
) std.mem.Allocator.Error!void {
    for (items) |item| {
        try list.append(allocator, item);
    }
}

fn appendTextRange(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Node),
    text: []const u8,
    span_start: usize,
) std.mem.Allocator.Error!void {
    if (text.len == 0) return;
    const normalized = try normalizeTextFragment(allocator, text);
    try list.append(allocator, .{
        .kind = .text,
        .text = normalized,
        .span_start = @intCast(span_start),
        .span_end = @intCast(span_start + text.len),
    });
}

fn appendTextRangePiece(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(InlinePiece),
    text: []const u8,
    span_start: usize,
) std.mem.Allocator.Error!void {
    if (text.len == 0) return;
    const normalized = try normalizeTextFragment(allocator, text);
    try list.append(allocator, .{
        .node = .{
            .kind = .text,
            .text = normalized,
            .span_start = @intCast(span_start),
            .span_end = @intCast(span_start + text.len),
        },
    });
}

fn resolveInlineDelimiters(
    allocator: std.mem.Allocator,
    initial_pieces: []const InlinePiece,
) std.mem.Allocator.Error![]Node {
    var pieces: std.ArrayList(InlinePiece) = .empty;
    defer pieces.deinit(allocator);
    try pieces.appendSlice(allocator, initial_pieces);

    var closer_index: usize = 0;
    while (closer_index < pieces.items.len) {
        const closer_state = pieces.items[closer_index].delimiter orelse {
            closer_index += 1;
            continue;
        };
        if (!closer_state.can_close or !closer_state.active) {
            closer_index += 1;
            continue;
        }

        var opener_index_opt: ?usize = null;
        var opener_state: DelimiterToken = undefined;
        var search_index = closer_index;
        while (search_index > 0) {
            search_index -= 1;
            const candidate = pieces.items[search_index].delimiter orelse continue;
            if (!candidate.active or !candidate.can_open) continue;
            if (candidate.marker != closer_state.marker) continue;

            const used_count = selectDelimiterUseCount(
                closer_state.marker,
                candidate.length,
                closer_state.length,
            );
            if (used_count == 0) continue;
            if (!delimiterRunsCanMatch(
                closer_state.marker,
                .{
                    .count = candidate.length,
                    .can_open = candidate.original_can_open,
                    .can_close = candidate.original_can_close,
                },
                .{
                    .count = closer_state.length,
                    .can_open = closer_state.original_can_open,
                    .can_close = closer_state.original_can_close,
                },
            )) continue;

            opener_index_opt = search_index;
            opener_state = candidate;
            break;
        }

        if (opener_index_opt == null) {
            if (pieces.items[closer_index].delimiter) |*delimiter| {
                delimiter.can_close = false;
                if (!delimiter.can_open) delimiter.active = false;
            }
            closer_index += 1;
            continue;
        }

        const opener_index = opener_index_opt.?;
        const used_count = selectDelimiterUseCount(
            closer_state.marker,
            opener_state.length,
            closer_state.length,
        );

        const opener_piece = pieces.items[opener_index];
        const closer_piece = pieces.items[closer_index];
        var children_pieces: std.ArrayList(InlinePiece) = .empty;
        defer children_pieces.deinit(allocator);

        const opener_remaining = opener_piece.node.text.len - used_count;
        const closer_remaining = closer_piece.node.text.len - used_count;
        const opener_has_leftover = opener_remaining != 0;
        const closer_has_leftover = closer_remaining != 0;
        const inner_delimiter_count = if (opener_has_leftover and closer_has_leftover)
            @min(opener_remaining, closer_remaining)
        else
            0;
        const outer_opener_count = opener_remaining - inner_delimiter_count;
        const outer_closer_count = closer_remaining - inner_delimiter_count;

        var outer_opener: InlinePiece = undefined;
        if (outer_opener_count != 0) {
            outer_opener = sliceInlinePiece(opener_piece, 0, outer_opener_count);
        }

        var inner_opener: InlinePiece = undefined;
        if (inner_delimiter_count != 0) {
            inner_opener = sliceInlinePiece(
                opener_piece,
                outer_opener_count,
                outer_opener_count + inner_delimiter_count,
            );
            try children_pieces.append(allocator, inner_opener);
        }

        try children_pieces.appendSlice(allocator, pieces.items[opener_index + 1 .. closer_index]);

        var inner_closer: InlinePiece = undefined;
        if (inner_delimiter_count != 0) {
            inner_closer = sliceInlinePiece(
                closer_piece,
                used_count,
                used_count + inner_delimiter_count,
            );
            try children_pieces.append(allocator, inner_closer);
        }

        var outer_closer: InlinePiece = undefined;
        if (outer_closer_count != 0) {
            outer_closer = sliceInlinePiece(
                closer_piece,
                used_count + inner_delimiter_count,
                closer_piece.node.text.len,
            );
        }

        const children = try resolveInlineDelimiters(allocator, children_pieces.items);

        var rebuilt: std.ArrayList(InlinePiece) = .empty;
        errdefer rebuilt.deinit(allocator);
        try rebuilt.appendSlice(allocator, pieces.items[0..opener_index]);

        if (outer_opener_count != 0) {
            try rebuilt.append(allocator, outer_opener);
        }

        try rebuilt.append(allocator, .{
            .node = .{
                .kind = switch (closer_state.marker) {
                    '~' => .strikethrough,
                    else => if (used_count == 2) .strong else .emphasis,
                },
                .children = children,
                .span_start = opener_piece.node.span_start,
                .span_end = closer_piece.node.span_end,
            },
        });

        if (outer_closer_count != 0) {
            try rebuilt.append(allocator, outer_closer);
        }

        try rebuilt.appendSlice(allocator, pieces.items[closer_index + 1 ..]);
        pieces.deinit(allocator);
        pieces = rebuilt;
        closer_index = if (opener_index == 0) 0 else opener_index - 1;
    }

    return inlinePiecesToNodes(allocator, pieces.items);
}

fn sliceInlinePiece(piece: InlinePiece, start: usize, end: usize) InlinePiece {
    std.debug.assert(start <= end);
    std.debug.assert(end <= piece.node.text.len);

    var sliced = piece;
    sliced.node.text = piece.node.text[start..end];
    sliced.node.span_start = piece.node.span_start + @as(i64, @intCast(start));
    sliced.node.span_end = piece.node.span_start + @as(i64, @intCast(end));

    if (piece.delimiter) |delimiter| {
        const length = end - start;
        if (length == 0 or (delimiter.marker == '~' and length < 2)) {
            sliced.delimiter = null;
        } else {
            var updated = delimiter;
            updated.length = length;
            sliced.delimiter = updated;
        }
    }

    return sliced;
}

fn inlinePiecesToNodes(
    allocator: std.mem.Allocator,
    pieces: []const InlinePiece,
) std.mem.Allocator.Error![]Node {
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(allocator);

    for (pieces) |piece| {
        if (piece.node.kind == .text and piece.node.text.len == 0) continue;
        try nodes.append(allocator, piece.node);
    }

    return coalesceAdjacentTextNodes(allocator, nodes.items);
}

fn coalesceAdjacentTextNodes(
    allocator: std.mem.Allocator,
    nodes: []const Node,
) std.mem.Allocator.Error![]Node {
    var merged: std.ArrayList(Node) = .empty;
    defer merged.deinit(allocator);

    for (nodes) |node| {
        if (node.kind == .text and merged.items.len != 0 and merged.items[merged.items.len - 1].kind == .text) {
            var combined: std.ArrayList(u8) = .empty;
            defer combined.deinit(allocator);

            try combined.appendSlice(allocator, merged.items[merged.items.len - 1].text);
            try combined.appendSlice(allocator, node.text);
            merged.items[merged.items.len - 1].text = try combined.toOwnedSlice(allocator);
            merged.items[merged.items.len - 1].span_end = node.span_end;
            continue;
        }

        try merged.append(allocator, node);
    }

    return merged.toOwnedSlice(allocator);
}

fn nodesContainKind(nodes: []const Node, kind: NodeKind) bool {
    for (nodes) |node| {
        if (node.kind == kind) return true;
        if (nodesContainKind(node.children, kind)) return true;
    }
    return false;
}

const named_entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "AElig", "Æ" },
    .{ "ClockwiseContourIntegral", "∲" },
    .{ "Dcaron", "Ď" },
    .{ "DifferentialD", "ⅆ" },
    .{ "HilbertSpace", "ℋ" },
    .{ "amp", "&" },
    .{ "auml", "ä" },
    .{ "copy", "©" },
    .{ "frac34", "¾" },
    .{ "gt", ">" },
    .{ "lt", "<" },
    .{ "nbsp", "\u{00A0}" },
    .{ "ngE", "≧̸" },
    .{ "ouml", "ö" },
    .{ "quot", "\"" },
});

fn normalizeTextFragment(
    allocator: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, text, "\\&\x00") == null) return text;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var changed = false;
    var slice_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0) {
            changed = true;
            try buffer.appendSlice(allocator, text[slice_start..index]);
            try appendReplacementCharacter(allocator, &buffer);
            index += 1;
            slice_start = index;
            continue;
        }

        if (text[index] == '\\' and index + 1 < text.len and isEscapableAsciiPunctuation(text[index + 1])) {
            changed = true;
            try buffer.appendSlice(allocator, text[slice_start..index]);
            try buffer.append(allocator, text[index + 1]);
            index += 2;
            slice_start = index;
            continue;
        }

        if (text[index] == '&') {
            if (parseCharacterReference(text, index)) |parsed| {
                changed = true;
                try buffer.appendSlice(allocator, text[slice_start..index]);
                try appendCharacterReferenceValue(allocator, &buffer, parsed);
                index = parsed.end;
                slice_start = index;
                continue;
            }
        }

        index += 1;
    }

    if (!changed) return text;

    try buffer.appendSlice(allocator, text[slice_start..]);
    return buffer.toOwnedSlice(allocator);
}

const ParsedCharacterReference = struct {
    value: Value,
    end: usize,

    const Value = union(enum) {
        named: []const u8,
        codepoint: u21,
    };
};

fn parseCharacterReference(text: []const u8, start: usize) ?ParsedCharacterReference {
    if (start >= text.len or text[start] != '&' or start + 2 >= text.len) return null;

    if (text[start + 1] == '#') {
        return parseNumericCharacterReference(text, start);
    }

    var index = start + 1;
    while (index < text.len and std.ascii.isAlphanumeric(text[index])) : (index += 1) {}
    if (index == start + 1 or index >= text.len or text[index] != ';') return null;

    const name = text[start + 1 .. index];
    const value = named_entities.get(name) orelse return null;
    return .{
        .value = .{ .named = value },
        .end = index + 1,
    };
}

fn parseNumericCharacterReference(text: []const u8, start: usize) ?ParsedCharacterReference {
    if (start + 3 >= text.len or text[start] != '&' or text[start + 1] != '#') return null;

    const hex = text[start + 2] == 'x' or text[start + 2] == 'X';
    const digits_start = if (hex) start + 3 else start + 2;
    if (digits_start >= text.len) return null;

    const max_digits: usize = if (hex) 6 else 7;
    const radix: u32 = if (hex) 16 else 10;
    var value: u32 = 0;
    var digits: usize = 0;
    var index = digits_start;
    while (index < text.len and digits < max_digits) : (index += 1) {
        const digit = if (hex)
            std.fmt.charToDigit(text[index], 16) catch break
        else
            std.fmt.charToDigit(text[index], 10) catch break;
        value = value * radix + digit;
        digits += 1;
    }

    if (digits == 0 or index >= text.len or text[index] != ';') return null;
    if (index + 1 < text.len) {
        const next = text[index + 1];
        if ((hex and std.ascii.isHex(next)) or (!hex and std.ascii.isDigit(next))) return null;
    }

    return .{
        .value = .{ .codepoint = normalizeCharacterReferenceCodepoint(value) },
        .end = index + 1,
    };
}

fn normalizeCharacterReferenceCodepoint(value: u32) u21 {
    if (value == 0 or value > 0x10FFFF) return std.unicode.replacement_character;
    const codepoint: u21 = @intCast(value);
    if (!std.unicode.utf8ValidCodepoint(codepoint)) return std.unicode.replacement_character;
    return codepoint;
}

fn appendCharacterReferenceValue(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    parsed: ParsedCharacterReference,
) std.mem.Allocator.Error!void {
    switch (parsed.value) {
        .named => |value| try buffer.appendSlice(allocator, value),
        .codepoint => |value| {
            var bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(value, &bytes) catch unreachable;
            try buffer.appendSlice(allocator, bytes[0..len]);
        },
    }
}

fn appendReplacementCharacter(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
) std.mem.Allocator.Error!void {
    try buffer.appendSlice(allocator, &std.unicode.replacement_character_utf8);
}

fn appendCaseFoldedCodepoints(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    cp: u21,
) std.mem.Allocator.Error!void {
    var folded_buffer: [1]u21 = undefined;
    const folded = uucode.get(.case_folding_full, cp).with(&folded_buffer, cp);
    for (folded) |folded_cp| {
        try appendCodepointUtf8(allocator, buffer, folded_cp);
    }
}

fn appendCodepointUtf8(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    cp: u21,
) std.mem.Allocator.Error!void {
    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &bytes) catch unreachable;
    try buffer.appendSlice(allocator, bytes[0..len]);
}

fn unescapeAsciiPunctuation(
    allocator: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;

    var needs_copy = false;
    var index: usize = 0;
    while (index + 1 < text.len) : (index += 1) {
        if (text[index] == '\\' and isEscapableAsciiPunctuation(text[index + 1])) {
            needs_copy = true;
            break;
        }
    }
    if (!needs_copy) return text;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    index = 0;
    while (index < text.len) {
        if (text[index] == '\\' and index + 1 < text.len and isEscapableAsciiPunctuation(text[index + 1])) {
            try buffer.append(allocator, text[index + 1]);
            index += 2;
            continue;
        }
        try buffer.append(allocator, text[index]);
        index += 1;
    }

    return buffer.toOwnedSlice(allocator);
}

fn normalizeAutolinkUriDestination(
    allocator: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    for (text) |byte| {
        if (byte == '\\') {
            try buffer.appendSlice(allocator, "%5C");
        } else {
            try buffer.append(allocator, byte);
        }
    }

    return buffer.toOwnedSlice(allocator);
}

fn normalizeCodeSpanText(
    allocator: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]const u8 {
    var needs_copy = false;
    for (text) |byte| {
        if (byte == '\r' or byte == '\n') {
            needs_copy = true;
            break;
        }
    }

    const normalized = if (needs_copy) normalized: {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);

        var index: usize = 0;
        while (index < text.len) {
            const byte = text[index];
            if (byte == '\r') {
                try buffer.append(allocator, ' ');
                if (index + 1 < text.len and text[index + 1] == '\n') index += 1;
            } else if (byte == '\n') {
                try buffer.append(allocator, ' ');
            } else {
                try buffer.append(allocator, byte);
            }
            index += 1;
        }
        break :normalized try buffer.toOwnedSlice(allocator);
    } else text;

    if (normalized.len >= 2 and
        normalized[0] == ' ' and
        normalized[normalized.len - 1] == ' ' and
        std.mem.trim(u8, normalized, " ").len != 0)
    {
        return normalized[1 .. normalized.len - 1];
    }

    return normalized;
}

fn joinLines(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
) std.mem.Allocator.Error![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    for (lines, 0..) |line, index| {
        try buffer.appendSlice(allocator, line);
        if (index + 1 < lines.len) {
            try buffer.append(allocator, '\n');
        }
    }

    return buffer.toOwnedSlice(allocator);
}

fn joinCodeBlockLines(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
) std.mem.Allocator.Error![]const u8 {
    const joined = try joinLines(allocator, lines);
    if (lines.len == 0 or lines[lines.len - 1].len != 0) return joined;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, joined);
    try buffer.append(allocator, '\n');
    return buffer.toOwnedSlice(allocator);
}

fn trimParagraphLineBreak(line: []const u8) struct { NodeKind, []const u8 } {
    if (std.mem.endsWith(u8, line, "\\")) {
        return .{ .hard_break, line[0 .. line.len - 1] };
    }

    if (line.len >= 2 and line[line.len - 1] == ' ' and line[line.len - 2] == ' ') {
        return .{ .hard_break, std.mem.trimEnd(u8, line[0 .. line.len - 2], " \t") };
    }

    return .{ .soft_break, line };
}

fn parseFence(line: []const u8) ?Fence {
    const indent = leadingIndent(line);
    if (indent > 3 or indent >= line.len) return null;

    const marker = line[indent];
    if (marker != '`' and marker != '~') return null;

    const count = delimiterRun(line, indent, marker);
    if (count < 3) return null;

    const info = std.mem.trim(u8, line[indent + count ..], " \t");
    if (marker == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;

    return .{
        .indent = indent,
        .marker = marker,
        .count = count,
        .info = info,
    };
}

fn isClosingFence(line: []const u8, fence: Fence) bool {
    const indent = leadingIndent(line);
    if (indent > 3 or indent >= line.len) return false;
    if (line[indent] != fence.marker) return false;

    const count = delimiterRun(line, indent, fence.marker);
    if (count < fence.count) return false;
    return std.mem.trim(u8, line[indent + count ..], " \t").len == 0;
}

fn parseHeading(line: []const u8) ?Heading {
    const indent = leadingIndent(line);
    if (indent > 3 or indent >= line.len) return null;
    if (line[indent] != '#') return null;

    const count = delimiterRun(line, indent, '#');
    if (count == 0 or count > 6) return null;
    if (indent + count < line.len and !std.ascii.isWhitespace(line[indent + count])) return null;

    const raw = if (indent + count >= line.len)
        ""
    else
        std.mem.trimStart(u8, line[indent + count ..], " \t");
    const text = trimClosingHeadingHashes(raw);

    return .{
        .level = @intCast(count),
        .text = text,
        .content_start = subsliceOffset(line, raw),
        .content_end = subsliceOffset(line, text) + text.len,
    };
}

fn parseSetextUnderline(line: []const u8) ?i64 {
    const indent = leadingIndent(line);
    if (indent > 3) return null;

    const trimmed = std.mem.trim(u8, line[indent..], " \t");
    if (trimmed.len == 0) return null;

    const byte = trimmed[0];
    if (byte != '=' and byte != '-') return null;
    for (trimmed) |item| {
        if (item != byte) return null;
    }
    return if (byte == '=') 1 else 2;
}

fn trimClosingHeadingHashes(text: []const u8) []const u8 {
    var trimmed = std.mem.trimEnd(u8, text, " \t");
    var hash_start = trimmed.len;
    while (hash_start != 0 and trimmed[hash_start - 1] == '#') {
        hash_start -= 1;
    }
    if (hash_start == trimmed.len) return trimmed;
    if (hash_start == 0) return "";
    if (!std.ascii.isWhitespace(trimmed[hash_start - 1])) return trimmed;

    trimmed = trimmed[0 .. hash_start - 1];
    return std.mem.trimEnd(u8, trimmed, " \t");
}

fn skipLinkWhitespace(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and std.ascii.isWhitespace(text[index])) : (index += 1) {}
    return index;
}

fn parseTaskMarker(text: []const u8) ?TaskMarker {
    if (text.len < 4) return null;
    if (text[0] != '[' or text[2] != ']' or !std.ascii.isWhitespace(text[3])) return null;
    return switch (text[1]) {
        ' ' => .{ .checked = false, .content = text[4..] },
        'x', 'X' => .{ .checked = true, .content = text[4..] },
        else => null,
    };
}

const LinkTarget = struct {
    destination: []const u8,
    title: []const u8,
};

fn parseLinkTarget(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?LinkTarget {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    const parsed_destination = parseLinkDestinationToken(trimmed, 0) orelse
        return null;
    const normalized_destination = if (parsed_destination.destination.len == 0)
        ""
    else
        try normalizeTextFragment(allocator, parsed_destination.destination);

    var index = parsed_destination.end;
    while (index < trimmed.len and std.ascii.isWhitespace(trimmed[index])) : (index += 1) {}
    if (index == trimmed.len) {
        return .{
            .destination = normalized_destination,
            .title = "",
        };
    }
    if (index == parsed_destination.end) return null;

    const title = parseLinkTitleToken(trimmed, index) orelse return null;
    index = title.end;
    while (index < trimmed.len and std.ascii.isWhitespace(trimmed[index])) : (index += 1) {}
    if (index != trimmed.len) return null;

    return .{
        .destination = normalized_destination,
        .title = try normalizeTextFragment(allocator, title.value),
    };
}

fn parseLinkTitleToken(
    text: []const u8,
    start: usize,
) ?struct {
    value: []const u8,
    end: usize,
} {
    if (start >= text.len) return null;

    const opening = text[start];
    const closing: u8 = switch (opening) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };

    var index = start + 1;
    while (index < text.len) {
        if (text[index] == '\\' and index + 1 < text.len) {
            index += if (isEscapableAsciiPunctuation(text[index + 1])) 2 else 1;
            continue;
        }
        if (text[index] == closing) {
            return .{
                .value = text[start + 1 .. index],
                .end = index + 1,
            };
        }
        index += 1;
    }

    return null;
}

fn joinLinkDefinitionTargetLines(
    allocator: std.mem.Allocator,
    lines: []const Line,
    parsed_label: ParsedDefinitionLabel,
) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(lines.len != 0);
    std.debug.assert(lines.len >= parsed_label.consumed);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(
        allocator,
        lines[parsed_label.consumed - 1].text[parsed_label.post_colon_offset..],
    );
    for (lines[parsed_label.consumed..]) |line| {
        try buffer.append(allocator, '\n');
        try buffer.appendSlice(allocator, line.text);
    }

    return buffer.toOwnedSlice(allocator);
}

fn parseHtmlBlockKind(line: []const u8) ?HtmlBlockKind {
    if (leadingIndentColumns(line) > 3) return null;
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (rawHtmlClosingTag(trimmed) != null) return .raw_tag;
    if (std.mem.startsWith(u8, trimmed, "<!--")) return .comment;
    if (std.mem.startsWith(u8, trimmed, "<?")) return .instruction;
    if (std.mem.startsWith(u8, trimmed, "<![CDATA[")) return .cdata;
    if (std.mem.startsWith(u8, trimmed, "<!") and trimmed.len > 2 and std.ascii.isUpper(trimmed[2])) {
        return .declaration;
    }
    if (isHtmlBlockTagStart(trimmed)) return .block_tag;
    if (isHtmlType7BlockStart(trimmed)) return .type7;
    return null;
}

fn rawHtmlClosingTag(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    return if (startsHtmlTagName(trimmed, "pre"))
        "</pre>"
    else if (startsHtmlTagName(trimmed, "script"))
        "</script>"
    else if (startsHtmlTagName(trimmed, "style"))
        "</style>"
    else if (startsHtmlTagName(trimmed, "textarea"))
        "</textarea>"
    else
        null;
}

fn containsHtmlClosingTag(text: []const u8, closing_tag: []const u8) bool {
    if (closing_tag.len == 0 or text.len < closing_tag.len) return false;

    var index: usize = 0;
    while (index + closing_tag.len <= text.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(text[index .. index + closing_tag.len], closing_tag)) {
            return true;
        }
    }
    return false;
}

fn startsHtmlTagName(text: []const u8, tag_name: []const u8) bool {
    if (text.len < tag_name.len + 1 or text[0] != '<') return false;

    var index: usize = 1;
    if (index < text.len and text[index] == '/') index += 1;
    if (index + tag_name.len > text.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[index .. index + tag_name.len], tag_name)) return false;
    if (index + tag_name.len == text.len) return true;

    return switch (text[index + tag_name.len]) {
        ' ', '\t', '\r', '\n', '>', '/' => true,
        else => false,
    };
}

fn isHtmlBlockTagStart(text: []const u8) bool {
    if (text.len < 3 or text[0] != '<') return false;

    var start: usize = 1;
    if (text[start] == '/') start += 1;
    if (start >= text.len or !std.ascii.isAlphabetic(text[start])) return false;

    var end = start;
    while (end < text.len and std.ascii.isAlphabetic(text[end])) : (end += 1) {}
    for (html_block_tag_names) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, text[start..end])) return true;
    }
    return false;
}

fn isHtmlType7BlockStart(text: []const u8) bool {
    if (text.len < 3 or text[0] != '<') return false;
    if (rawHtmlClosingTag(text) != null or isHtmlBlockTagStart(text)) return false;

    var index: usize = 1;
    if (text[index] == '!' or text[index] == '?') return false;
    if (text[index] == '/') index += 1;
    if (index >= text.len or !std.ascii.isAlphabetic(text[index])) return false;

    index += 1;
    while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '-')) : (index += 1) {}
    if (index >= text.len) return false;
    switch (text[index]) {
        ' ', '\t', '\r', '\n', '/', '>' => {},
        else => return false,
    }

    const end = parseInlineHtmlEnd(text, 0) orelse return false;
    return std.mem.trim(u8, text[end..], " \t").len == 0;
}

const html_block_tag_names = [_][]const u8{
    "address", "article",  "aside",   "base",     "basefont", "blockquote", "body",
    "caption", "center",   "col",     "colgroup", "dd",       "details",    "dialog",
    "dir",     "div",      "dl",      "dt",       "fieldset", "figcaption", "figure",
    "footer",  "form",     "frame",   "frameset", "h1",       "h2",         "h3",
    "h4",      "h5",       "h6",      "head",     "header",   "hr",         "html",
    "iframe",  "legend",   "li",      "link",     "main",     "menu",       "menuitem",
    "nav",     "noframes", "ol",      "optgroup", "option",   "p",          "param",
    "search",  "section",  "summary", "table",    "tbody",    "td",         "tfoot",
    "th",      "thead",    "title",   "tr",       "track",    "ul",
};

fn parseInlineHtmlEnd(text: []const u8, start: usize) ?usize {
    if (start + 1 >= text.len) return null;

    const next = text[start + 1];
    if (std.mem.startsWith(u8, text[start..], "<!--")) {
        if (start + 4 < text.len and text[start + 4] == '>') return start + 5;
        if (start + 5 < text.len and text[start + 4] == '-' and text[start + 5] == '>') return start + 6;
        const end = std.mem.indexOfPos(u8, text, start + 4, "-->") orelse return null;
        return end + 3;
    }
    if (std.mem.startsWith(u8, text[start..], "<![CDATA[")) {
        const end = std.mem.indexOfPos(u8, text, start + 9, "]]>") orelse return null;
        return end + 3;
    }
    if (std.mem.startsWith(u8, text[start..], "<?")) {
        const end = std.mem.indexOfPos(u8, text, start + 2, "?>") orelse return null;
        return end + 2;
    }
    if (next == '!') {
        if (start + 2 >= text.len or !std.ascii.isUpper(text[start + 2])) return null;
        const end = std.mem.indexOfScalarPos(u8, text, start + 3, '>') orelse return null;
        return end + 1;
    }
    if (next == '/') {
        return parseClosingInlineHtmlTag(text, start + 2);
    }
    if (std.ascii.isAlphabetic(next)) {
        return parseOpeningInlineHtmlTag(text, start + 1);
    }
    return null;
}

fn parseClosingInlineHtmlTag(text: []const u8, start: usize) ?usize {
    var index = parseInlineHtmlTagName(text, start) orelse return null;
    index = skipInlineHtmlWhitespace(text, index);
    if (index >= text.len or text[index] != '>') return null;
    return index + 1;
}

fn parseOpeningInlineHtmlTag(text: []const u8, start: usize) ?usize {
    var index = parseInlineHtmlTagName(text, start) orelse return null;
    if (index >= text.len) return null;
    if (text[index] == '>') return index + 1;
    if (text[index] == '/' and index + 1 < text.len and text[index + 1] == '>') return index + 2;

    while (true) {
        switch (text[index]) {
            ' ', '\t', '\n', '\r' => index = skipInlineHtmlWhitespace(text, index),
            '>' => return index + 1,
            '/' => if (index + 1 < text.len and text[index + 1] == '>') return index + 2 else return null,
            else => return null,
        }
        if (index >= text.len) return null;
        if (text[index] == '>') return index + 1;
        if (text[index] == '/' and index + 1 < text.len and text[index + 1] == '>') return index + 2;

        index = parseInlineHtmlAttributeName(text, index) orelse return null;
        const after_name = skipInlineHtmlWhitespace(text, index);
        if (after_name < text.len and text[after_name] == '=') {
            index = skipInlineHtmlWhitespace(text, after_name + 1);
            index = parseInlineHtmlAttributeValue(text, index) orelse return null;
        }

        if (index >= text.len) return null;
        if (text[index] == '>') return index + 1;
        if (text[index] == '/' and index + 1 < text.len and text[index + 1] == '>') return index + 2;
    }
}

fn parseInlineHtmlTagName(text: []const u8, start: usize) ?usize {
    if (start >= text.len or !std.ascii.isAlphabetic(text[start])) return null;

    var index = start + 1;
    while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '-')) : (index += 1) {}
    return index;
}

fn parseInlineHtmlAttributeName(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;
    if (!std.ascii.isAlphabetic(text[start]) and text[start] != ':' and text[start] != '_') return null;

    var index = start + 1;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':' or byte == '.') continue;
        break;
    }
    return index;
}

fn parseInlineHtmlAttributeValue(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;

    if (text[start] == '"' or text[start] == '\'') {
        const quote = text[start];
        var index = start + 1;
        while (index < text.len) : (index += 1) {
            if (text[index] == quote) return index + 1;
        }
        return null;
    }

    var index = start;
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            ' ', '\t', '\n', '\r', '"', '\'', '=', '<', '>', '`' => break,
            else => {},
        }
    }
    if (index == start) return null;
    return index;
}

fn skipInlineHtmlWhitespace(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and std.ascii.isWhitespace(text[index])) : (index += 1) {}
    return index;
}

fn isThematicBreak(line: []const u8) bool {
    const indent = leadingIndent(line);
    if (indent > 3) return false;

    const trimmed = std.mem.trim(u8, line[indent..], " \t");
    if (trimmed.len < 3) return false;

    const marker = trimmed[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;

    var marker_count: usize = 0;
    for (trimmed) |byte| {
        if (byte == marker) {
            marker_count += 1;
            continue;
        }
        if (byte != ' ' and byte != '\t') return false;
    }

    return marker_count >= 3;
}

fn isQuoteLine(line: []const u8) bool {
    const indent = leadingIndent(line);
    if (indent > 3 or indent >= line.len) return false;
    return line[indent] == '>';
}

fn parseListMarker(line: []const u8) (std.mem.Allocator.Error || ParseError)!?ListMarker {
    const indent = leadingIndent(line);
    if (indent > 3 or indent >= line.len) return null;

    const byte = line[indent];
    if (byte == '-' or byte == '+' or byte == '*') {
        const prefix_end = indent + 1;
        const content_indent = listContentIndent(line, prefix_end) orelse return null;
        const empty = std.mem.trim(u8, line[prefix_end..], " \t").len == 0;
        return .{
            .ordered = false,
            .start = 1,
            .marker = byte,
            .indent = indent,
            .prefix_end = prefix_end,
            .content_indent = content_indent,
            .empty = empty,
            .delimiter = .bullet,
        };
    }

    if (!std.ascii.isDigit(byte)) return null;
    var index = indent;
    while (index < line.len and std.ascii.isDigit(line[index])) : (index += 1) {}
    if (index - indent > 9) return null;
    if (index >= line.len) return null;
    const delimiter: ListDelimiter = switch (line[index]) {
        '.' => .period,
        ')' => .paren,
        else => return null,
    };
    const prefix_end = index + 1;
    const content_indent = listContentIndent(line, prefix_end) orelse return null;
    const empty = std.mem.trim(u8, line[prefix_end..], " \t").len == 0;

    const value = std.fmt.parseInt(i64, line[indent..index], 10) catch
        return error.InvalidOrderedListStart;
    return .{
        .ordered = true,
        .start = value,
        .marker = line[index],
        .indent = indent,
        .prefix_end = prefix_end,
        .content_indent = content_indent,
        .empty = empty,
        .delimiter = delimiter,
    };
}

fn stripContainerPrefix(
    allocator: std.mem.Allocator,
    line: []const u8,
    prefix_end: usize,
) std.mem.Allocator.Error!StrippedIndent {
    var index = prefix_end;
    var column = visualColumns(line[0..prefix_end]);
    var leading_spaces: usize = 0;

    if (index < line.len) {
        switch (line[index]) {
            ' ' => {
                index += 1;
                column += 1;
            },
            '\t' => {
                const width = tabWidth(column);
                index += 1;
                column += width;
                leading_spaces += width - 1;
            },
            else => {},
        }
    }

    while (index < line.len) {
        switch (line[index]) {
            ' ' => {
                index += 1;
                column += 1;
                leading_spaces += 1;
            },
            '\t' => {
                const width = tabWidth(column);
                index += 1;
                column += width;
                leading_spaces += width;
            },
            else => break,
        }
    }

    if (leading_spaces == 0) {
        return .{
            .text = line[index..],
            .bytes = index,
        };
    }

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    try buffer.ensureUnusedCapacity(allocator, leading_spaces + line.len - index);
    for (0..leading_spaces) |_| {
        buffer.appendAssumeCapacity(' ');
    }
    try buffer.appendSlice(allocator, line[index..]);

    return .{
        .text = try buffer.toOwnedSlice(allocator),
        .bytes = index,
    };
}

fn isBlockStarter(line: []const u8) (std.mem.Allocator.Error || ParseError)!bool {
    if (parseFence(line) != null) return true;
    if (parseHeading(line) != null) return true;
    if (isThematicBreak(line)) return true;
    if (parseHtmlBlockKind(line) != null) return true;
    if (isQuoteLine(line)) return true;
    return (try parseListMarker(line)) != null;
}

fn isParagraphTerminator(line: []const u8) (std.mem.Allocator.Error || ParseError)!bool {
    if (parseFence(line) != null) return true;
    if (parseHeading(line) != null) return true;
    if (isThematicBreak(line)) return true;
    if (parseHtmlBlockKind(line)) |html_kind| {
        if (html_kind != .type7) return true;
    }
    if (isQuoteLine(line)) return true;

    const marker = (try parseListMarker(line)) orelse return false;
    if (marker.empty) return false;
    return !marker.ordered or marker.start == 1;
}

fn sameListGroup(lhs: ListMarker, rhs: ListMarker) bool {
    return lhs.ordered == rhs.ordered and
        lhs.delimiter == rhs.delimiter and
        (lhs.ordered or lhs.marker == rhs.marker);
}

fn isLazyBlockQuoteContinuation(
    allocator: std.mem.Allocator,
    line: []const u8,
) (std.mem.Allocator.Error || ParseError)!bool {
    if (isBlank(line)) return false;

    var current = line;
    var depth: usize = 0;
    while (depth < max_nesting) : (depth += 1) {
        if (isBlank(current)) return false;

        if (isQuoteLine(current)) {
            const indent = leadingIndent(current);
            const stripped = try stripContainerPrefix(allocator, current, indent + 1);
            current = stripped.text;
            continue;
        }

        if (try parseListMarker(current)) |marker| {
            if (marker.empty) return false;
            const stripped = try stripListItemPrefix(allocator, current, marker.prefix_end);
            current = stripped.text;
            continue;
        }

        break;
    }

    return isParagraphLikeBlockLine(current);
}

fn classifyListItemBlankLines(children: []const Node, saw_internal_blank_line: bool) bool {
    if (!saw_internal_blank_line or children.len == 0) return false;
    if (children.len == 1 and children[0].kind == .code_block) return false;
    return true;
}

fn isParagraphLikeBlockLine(line: []const u8) (std.mem.Allocator.Error || ParseError)!bool {
    if (isBlank(line) or isIndentedCodeLine(line)) return false;
    return !(try isBlockStarter(line));
}

fn listContentIndent(line: []const u8, prefix_end: usize) ?usize {
    if (prefix_end >= line.len) return visualColumns(line[0..prefix_end]) + 1;
    if (!std.ascii.isWhitespace(line[prefix_end])) return null;

    const marker_columns = visualColumns(line[0..prefix_end]);
    var content_start = prefix_end;
    while (content_start < line.len and std.ascii.isWhitespace(line[content_start])) : (content_start += 1) {}
    if (content_start >= line.len) return marker_columns + 1;

    const separator_columns = visualColumns(line[prefix_end..content_start]);
    if (separator_columns <= 4) return marker_columns + separator_columns;
    return marker_columns + 1;
}

fn stripListItemPrefix(
    allocator: std.mem.Allocator,
    line: []const u8,
    prefix_end: usize,
) std.mem.Allocator.Error!StrippedIndent {
    if (prefix_end >= line.len) {
        return .{
            .text = "",
            .bytes = prefix_end,
        };
    }

    var index = prefix_end;
    var column = visualColumns(line[0..prefix_end]);
    var separator_columns: usize = 0;
    while (index < line.len) {
        const width = switch (line[index]) {
            ' ' => @as(usize, 1),
            '\t' => tabWidth(column),
            else => break,
        };
        column += width;
        separator_columns += width;
        index += 1;
    }

    if (separator_columns == 0) {
        return .{
            .text = line[index..],
            .bytes = index,
        };
    }

    const stripped_columns = if (index < line.len and separator_columns > 4)
        @as(usize, 1)
    else
        separator_columns;
    const remaining_columns = separator_columns - stripped_columns;
    if (remaining_columns == 0) {
        return .{
            .text = line[index..],
            .bytes = index,
        };
    }

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    try buffer.ensureUnusedCapacity(allocator, remaining_columns + line.len - index);
    for (0..remaining_columns) |_| {
        buffer.appendAssumeCapacity(' ');
    }
    try buffer.appendSlice(allocator, line[index..]);

    return .{
        .text = try buffer.toOwnedSlice(allocator),
        .bytes = index,
    };
}

fn leadingIndent(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and (line[count] == ' ' or line[count] == '\t')) : (count += 1) {}
    return count;
}

fn leadingIndentColumns(line: []const u8) usize {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        switch (line[index]) {
            ' ' => columns += 1,
            '\t' => columns += 4 - (columns % 4),
            else => break,
        }
    }
    return columns;
}

fn visualColumns(text: []const u8) usize {
    var columns: usize = 0;
    for (text) |byte| {
        columns += switch (byte) {
            '\t' => tabWidth(columns),
            else => 1,
        };
    }
    return columns;
}

fn tabWidth(column: usize) usize {
    const remainder = column % 4;
    return if (remainder == 0) 4 else 4 - remainder;
}

const StrippedIndent = struct {
    text: []const u8,
    bytes: usize,
};

fn stripIndentColumns(
    allocator: std.mem.Allocator,
    line: []const u8,
    columns_to_strip: usize,
) std.mem.Allocator.Error!StrippedIndent {
    var total_columns: usize = 0;
    var index: usize = 0;
    var stripped_bytes: ?usize = if (columns_to_strip == 0) 0 else null;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {
        switch (line[index]) {
            ' ' => total_columns += 1,
            '\t' => total_columns += 4 - (total_columns % 4),
            else => unreachable,
        }
        if (stripped_bytes == null and total_columns >= columns_to_strip) {
            stripped_bytes = index + 1;
        }
    }

    const leading_bytes = index;
    const consumed_bytes = stripped_bytes orelse leading_bytes;
    const remaining_columns = total_columns - @min(total_columns, columns_to_strip);
    if (remaining_columns == 0 and consumed_bytes == leading_bytes) {
        return .{
            .text = line[leading_bytes..],
            .bytes = consumed_bytes,
        };
    }

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    try buffer.ensureUnusedCapacity(allocator, remaining_columns + line.len - leading_bytes);
    for (0..remaining_columns) |_| {
        buffer.appendAssumeCapacity(' ');
    }
    try buffer.appendSlice(allocator, line[leading_bytes..]);

    return .{
        .text = try buffer.toOwnedSlice(allocator),
        .bytes = consumed_bytes,
    };
}

fn subsliceOffset(container: []const u8, inner: []const u8) usize {
    if (inner.len == 0) return container.len;
    return @intFromPtr(inner.ptr) - @intFromPtr(container.ptr);
}

fn delimiterRun(text: []const u8, start: usize, byte: u8) usize {
    var count: usize = 0;
    while (start + count < text.len and text[start + count] == byte) : (count += 1) {}
    return count;
}

fn analyzeDelimiterRun(text: []const u8, start: usize, marker: u8) DelimiterRunInfo {
    const count = delimiterRun(text, start, marker);
    const before = previousCodepoint(text, start);
    const after_index = start + count;
    const after = nextCodepoint(text, after_index);

    const before_is_whitespace = before == null or isUnicodeWhitespace(before.?);
    const after_is_whitespace = after == null or isUnicodeWhitespace(after.?);
    const before_is_punctuation = before != null and isUnicodePunctuation(before.?);
    const after_is_punctuation = after != null and isUnicodePunctuation(after.?);

    const left_flanking = !after_is_whitespace and
        (!after_is_punctuation or before_is_whitespace or before_is_punctuation);
    const right_flanking = !before_is_whitespace and
        (!before_is_punctuation or after_is_whitespace or after_is_punctuation);

    return .{
        .count = count,
        .can_open = switch (marker) {
            '*' => left_flanking,
            '_' => left_flanking and (!right_flanking or before_is_punctuation),
            '~' => left_flanking,
            else => false,
        },
        .can_close = switch (marker) {
            '*' => right_flanking,
            '_' => right_flanking and (!left_flanking or after_is_punctuation),
            '~' => right_flanking,
            else => false,
        },
    };
}

fn findDelimiterCloser(
    text: []const u8,
    start: usize,
    marker: u8,
    opener: DelimiterRunInfo,
) ?struct {
    index: usize,
    count: usize,
    used_count: usize,
} {
    var index = start;
    while (index < text.len) {
        if (text[index] == '\\' and index + 1 < text.len and isInlineSpecial(text[index + 1])) {
            index += 2;
            continue;
        }

        if (text[index] == '`') {
            const tick_count = delimiterRun(text, index, '`');
            if (findClosingRun(text, index + tick_count, '`', tick_count)) |close_index| {
                index = close_index + tick_count;
                continue;
            }
            index += tick_count;
            continue;
        }

        if (text[index] == '<') {
            if (parseInlineHtmlEnd(text, index)) |end| {
                index = end;
                continue;
            }
        }

        if (text[index] != marker) {
            index += 1;
            continue;
        }

        const closer = analyzeDelimiterRun(text, index, marker);
        const used_count = selectDelimiterUseCount(marker, opener.count, closer.count);
        if (used_count != 0 and closer.can_close) {
            if (delimiterRunsCanMatch(marker, opener, closer)) {
                return .{
                    .index = index,
                    .count = closer.count,
                    .used_count = used_count,
                };
            }
        }
        index += @max(closer.count, 1);
    }
    return null;
}

fn delimiterRunsCanMatch(marker: u8, opener: DelimiterRunInfo, closer: DelimiterRunInfo) bool {
    if (marker == '~') return true;
    if (!(opener.can_close or closer.can_open)) return true;

    if ((opener.count + closer.count) % 3 != 0) return true;
    return opener.count % 3 == 0 and closer.count % 3 == 0;
}

fn selectDelimiterUseCount(marker: u8, opener_count: usize, closer_count: usize) usize {
    switch (marker) {
        '~' => return if (opener_count >= 2 and closer_count >= 2) 2 else 0,
        '*', '_' => {
            const max_use = @min(@min(opener_count, closer_count), 2);
            if (max_use == 0) return 0;
            if (max_use == 1) return 1;
            if (opener_count >= 3 and closer_count >= 3 and opener_count % 2 == 1 and closer_count % 2 == 1) {
                return 1;
            }
            return 2;
        },
        else => return 0,
    }
}

fn findClosingRun(text: []const u8, start: usize, byte: u8, count: usize) ?usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (text[index] != byte) continue;
        if (delimiterRun(text, index, byte) != count) continue;
        if (index != 0 and text[index - 1] == byte) continue;
        if (index + count < text.len and text[index + count] == byte) continue;
        return index;
    }
    return null;
}

fn previousCodepoint(text: []const u8, end: usize) ?u21 {
    if (end == 0) return null;

    var start = end - 1;
    while (start != 0 and (text[start] & 0b1100_0000) == 0b1000_0000) : (start -= 1) {}
    return std.unicode.utf8Decode(text[start..end]) catch std.unicode.replacement_character;
}

fn nextCodepoint(text: []const u8, start: usize) ?u21 {
    if (start >= text.len) return null;

    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch return std.unicode.replacement_character;
    const end = @min(start + len, text.len);
    return std.unicode.utf8Decode(text[start..end]) catch std.unicode.replacement_character;
}

fn isUnicodeWhitespace(cp: u21) bool {
    if (cp < 128) return std.ascii.isWhitespace(@intCast(cp));
    return switch (uucode.get(.general_category, cp)) {
        .separator_space,
        .separator_line,
        .separator_paragraph,
        => true,
        else => false,
    };
}

fn isUnicodePunctuation(cp: u21) bool {
    if (cp < 128) {
        const byte: u8 = @intCast(cp);
        return !std.ascii.isWhitespace(byte) and !std.ascii.isAlphanumeric(byte);
    }

    return switch (uucode.get(.general_category, cp)) {
        .punctuation_connector,
        .punctuation_dash,
        .punctuation_open,
        .punctuation_close,
        .punctuation_initial_quote,
        .punctuation_final_quote,
        .punctuation_other,
        .symbol_math,
        .symbol_currency,
        .symbol_modifier,
        .symbol_other,
        => true,
        else => false,
    };
}

fn findUnescapedByte(text: []const u8, start: usize, needle: u8) ?usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (text[index] != needle) continue;
        if (index != 0 and text[index - 1] == '\\') continue;
        return index;
    }
    return null;
}

fn isInlineSpecial(byte: u8) bool {
    return switch (byte) {
        '\\', '`', '[', ']', '(', ')', '*', '_', '!', '~' => true,
        else => false,
    };
}

fn isEscapableAsciiPunctuation(byte: u8) bool {
    return (byte >= '!' and byte <= '/') or
        (byte >= ':' and byte <= '@') or
        (byte >= '[' and byte <= '`') or
        (byte >= '{' and byte <= '~');
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn isIndentedCodeLine(line: []const u8) bool {
    return !isBlank(line) and leadingIndentColumns(line) >= 4;
}

test "markdown: parses headings paragraphs and inline nodes" {
    const source =
        \\# Title
        \\
        \\Paragraph with *emphasis*, **strong**, `code`, and [link](https://example.com "site").
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqualStrings(source, document.source);
    try std.testing.expectEqual(@as(usize, 2), document.children.len);

    const heading = document.children[0];
    try std.testing.expectEqual(NodeKind.heading, heading.kind);
    try std.testing.expectEqual(@as(i64, 1), heading.level);
    try std.testing.expectEqual(@as(i64, 0), heading.span_start);
    try std.testing.expectEqual(@as(i64, 7), heading.span_end);
    try std.testing.expectEqual(@as(usize, 1), heading.children.len);
    try std.testing.expectEqual(NodeKind.text, heading.children[0].kind);
    try std.testing.expectEqualStrings("Title", heading.children[0].text);

    const paragraph = document.children[1];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(NodeKind.emphasis, paragraph.children[1].kind);
    try std.testing.expectEqualStrings("emphasis", paragraph.children[1].children[0].text);
    try std.testing.expectEqual(NodeKind.strong, paragraph.children[3].kind);
    try std.testing.expectEqualStrings("strong", paragraph.children[3].children[0].text);
    try std.testing.expectEqual(NodeKind.code_span, paragraph.children[5].kind);
    try std.testing.expectEqualStrings("code", paragraph.children[5].text);
    try std.testing.expectEqual(NodeKind.link, paragraph.children[7].kind);
    try std.testing.expectEqualStrings("https://example.com", paragraph.children[7].destination);
    try std.testing.expectEqualStrings("site", paragraph.children[7].title);
    try std.testing.expectEqualStrings("link", paragraph.children[7].children[0].text);
}

test "markdown: parses block quotes lists and code fences" {
    const source =
        \\> Quoted text
        \\
        \\1) first
        \\2) second
        \\
        \\```mu
        \\const x = 1;
        \\```
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 3), document.children.len);

    const quote = document.children[0];
    try std.testing.expectEqual(NodeKind.block_quote, quote.kind);
    try std.testing.expectEqual(@as(usize, 1), quote.children.len);
    try std.testing.expectEqual(NodeKind.paragraph, quote.children[0].kind);

    const list = document.children[1];
    try std.testing.expectEqual(NodeKind.list, list.kind);
    try std.testing.expect(list.ordered);
    try std.testing.expectEqual(ListDelimiter.paren, list.delimiter);
    try std.testing.expectEqual(@as(i64, 1), list.start);
    try std.testing.expectEqual(@as(usize, 2), list.children.len);
    try std.testing.expectEqual(NodeKind.list_item, list.children[0].kind);

    const code_block = document.children[2];
    try std.testing.expectEqual(NodeKind.code_block, code_block.kind);
    try std.testing.expectEqualStrings("mu", code_block.info);
    try std.testing.expectEqualStrings("const x = 1;", code_block.text);
}

test "markdown: parses indented code blocks" {
    const source =
        \\    const x = 1;
        \\        const y = 2;
        \\
        \\after
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);

    const code_block = document.children[0];
    try std.testing.expectEqual(NodeKind.code_block, code_block.kind);
    try std.testing.expectEqualStrings("const x = 1;\n    const y = 2;", code_block.text);

    const paragraph = document.children[1];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqualStrings("after", paragraph.children[0].text);
}

test "markdown: treats tab indentation as indented code" {
    const source = "\tfoo\tbaz\t\tbim";

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const code_block = document.children[0];
    try std.testing.expectEqual(NodeKind.code_block, code_block.kind);
    try std.testing.expectEqualStrings("foo\tbaz\t\tbim", code_block.text);
}

test "markdown: preserves residual spaces on blank indented code lines" {
    const source =
        \\    chunk1
        \\      
        \\      chunk2
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const code_block = document.children[0];
    try std.testing.expectEqual(NodeKind.code_block, code_block.kind);
    try std.testing.expectEqualStrings("chunk1\n  \n  chunk2", code_block.text);
}

test "markdown: indented html-looking lines stay indented code" {
    const source =
        \\    <a/>
        \\    *hi*
        \\
        \\    - one
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const code_block = document.children[0];
    try std.testing.expectEqual(NodeKind.code_block, code_block.kind);
    try std.testing.expectEqualStrings("<a/>\n*hi*\n\n- one", code_block.text);
}

test "markdown: parses indented code blocks inside list items" {
    const source =
        \\- item
        \\
        \\      const nested = true;
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const list = document.children[0];
    try std.testing.expectEqual(NodeKind.list, list.kind);
    try std.testing.expectEqual(@as(usize, 1), list.children.len);
    try std.testing.expect(!list.tight);

    const item = list.children[0];
    try std.testing.expectEqual(NodeKind.list_item, item.kind);
    try std.testing.expectEqual(@as(usize, 2), item.children.len);
    try std.testing.expectEqual(NodeKind.paragraph, item.children[0].kind);
    try std.testing.expectEqual(NodeKind.code_block, item.children[1].kind);
    try std.testing.expectEqualStrings("const nested = true;", item.children[1].text);
}

test "markdown: keeps tab-indented continuation paragraphs inside list items" {
    const source = "  - foo\n\n\tbar";

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const list = document.children[0];
    try std.testing.expectEqual(NodeKind.list, list.kind);
    try std.testing.expectEqual(@as(usize, 1), list.children.len);
    const item = list.children[0];
    try std.testing.expectEqual(NodeKind.list_item, item.kind);
    try std.testing.expectEqual(@as(usize, 2), item.children.len);
    try std.testing.expectEqual(NodeKind.paragraph, item.children[0].kind);
    try std.testing.expectEqual(NodeKind.paragraph, item.children[1].kind);
    try std.testing.expectEqualStrings("bar", item.children[1].children[0].text);
}

test "markdown: keeps nested code indentation from tab-indented list continuations" {
    const source = "- foo\n\n\t\tbar";

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const list = document.children[0];
    try std.testing.expectEqual(NodeKind.list, list.kind);
    const item = list.children[0];
    try std.testing.expectEqual(@as(usize, 2), item.children.len);
    try std.testing.expectEqual(NodeKind.code_block, item.children[1].kind);
    try std.testing.expectEqualStrings("  bar", item.children[1].text);
}

test "markdown: ordered lists starting above one do not interrupt paragraphs" {
    const source =
        \\Paragraph
        \\2. still paragraph
        \\
        \\1. actual list
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 3), paragraph.children.len);
    try std.testing.expectEqualStrings("Paragraph", paragraph.children[0].text);
    try std.testing.expectEqual(NodeKind.soft_break, paragraph.children[1].kind);
    try std.testing.expectEqualStrings("2. still paragraph", paragraph.children[2].text);

    const list = document.children[1];
    try std.testing.expectEqual(NodeKind.list, list.kind);
    try std.testing.expect(list.ordered);
    try std.testing.expectEqual(@as(i64, 1), list.start);
}

test "markdown: ordered list markers longer than nine digits stay paragraphs" {
    const source = "1234567890. not ok";

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqualStrings("1234567890. not ok", paragraph.children[0].text);
}

test "markdown: list items do not absorb unindented block starters" {
    const source =
        \\- item
        \\continued
        \\
        \\> outside quote
        \\
        \\1. outside list
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 3), document.children.len);

    const list = document.children[0];
    try std.testing.expectEqual(NodeKind.list, list.kind);
    try std.testing.expectEqual(@as(usize, 1), list.children.len);

    const item = list.children[0];
    try std.testing.expectEqual(NodeKind.list_item, item.kind);
    try std.testing.expectEqual(@as(usize, 1), item.children.len);

    const paragraph = item.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 3), paragraph.children.len);
    try std.testing.expectEqualStrings("item", paragraph.children[0].text);
    try std.testing.expectEqual(NodeKind.soft_break, paragraph.children[1].kind);
    try std.testing.expectEqualStrings("continued", paragraph.children[2].text);

    const quote = document.children[1];
    try std.testing.expectEqual(NodeKind.block_quote, quote.kind);
    try std.testing.expectEqualStrings("outside quote", quote.children[0].children[0].text);

    const ordered = document.children[2];
    try std.testing.expectEqual(NodeKind.list, ordered.kind);
    try std.testing.expect(ordered.ordered);
    try std.testing.expectEqual(@as(i64, 1), ordered.start);
}

test "markdown: parses block quote lazy continuation" {
    const source =
        \\> Quoted
        \\continued
        \\
        \\outside
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);

    const quote = document.children[0];
    try std.testing.expectEqual(NodeKind.block_quote, quote.kind);
    try std.testing.expectEqual(@as(usize, 1), quote.children.len);

    const paragraph = quote.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 3), paragraph.children.len);
    try std.testing.expectEqualStrings("Quoted", paragraph.children[0].text);
    try std.testing.expectEqual(NodeKind.soft_break, paragraph.children[1].kind);
    try std.testing.expectEqualStrings("continued", paragraph.children[2].text);

    const outside = document.children[1];
    try std.testing.expectEqual(NodeKind.paragraph, outside.kind);
    try std.testing.expectEqualStrings("outside", outside.children[0].text);
}

test "markdown: strips tabs after block quote markers" {
    const source = ">\tquoted";

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const quote = document.children[0];
    try std.testing.expectEqual(NodeKind.block_quote, quote.kind);
    try std.testing.expectEqual(@as(usize, 1), quote.children.len);
    try std.testing.expectEqualStrings("quoted", quote.children[0].children[0].text);
}

test "markdown: parses setext headings task list items and strikethrough" {
    const source =
        \\Title
        \\=====
        \\
        \\- [x] done ~~now~~
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);

    const heading = document.children[0];
    try std.testing.expectEqual(NodeKind.heading, heading.kind);
    try std.testing.expectEqual(@as(i64, 1), heading.level);
    try std.testing.expectEqual(@as(i64, 0), heading.span_start);
    try std.testing.expectEqual(@as(i64, 11), heading.span_end);

    const list = document.children[1];
    try std.testing.expectEqual(NodeKind.list, list.kind);
    try std.testing.expectEqual(@as(usize, 1), list.children.len);
    try std.testing.expect(list.tight);

    const item = list.children[0];
    try std.testing.expect(item.task);
    try std.testing.expect(item.checked);
    try std.testing.expectEqual(@as(usize, 1), item.children.len);

    const paragraph = item.children[0];
    try std.testing.expectEqual(@as(usize, 2), paragraph.children.len);
    try std.testing.expectEqualStrings("done ", paragraph.children[0].text);
    try std.testing.expectEqual(NodeKind.strikethrough, paragraph.children[1].kind);
    try std.testing.expectEqualStrings("now", paragraph.children[1].children[0].text);
}

test "markdown: thematic breaks interrupt sibling list items" {
    const source =
        \\* Foo
        \\* * *
        \\* Bar
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 3), document.children.len);

    const first_list = document.children[0];
    try std.testing.expectEqual(NodeKind.list, first_list.kind);
    try std.testing.expectEqual(@as(usize, 1), first_list.children.len);
    try std.testing.expectEqualStrings("Foo", first_list.children[0].children[0].children[0].text);

    try std.testing.expectEqual(NodeKind.thematic_break, document.children[1].kind);

    const second_list = document.children[2];
    try std.testing.expectEqual(NodeKind.list, second_list.kind);
    try std.testing.expectEqual(@as(usize, 1), second_list.children.len);
    try std.testing.expectEqualStrings("Bar", second_list.children[0].children[0].children[0].text);
}

test "markdown: block quotes allow lazy continuation through setext markers" {
    const source =
        \\> foo
        \\bar
        \\===
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const quote = document.children[0];
    try std.testing.expectEqual(NodeKind.block_quote, quote.kind);
    try std.testing.expectEqual(@as(usize, 1), quote.children.len);

    const paragraph = quote.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 5), paragraph.children.len);
    try std.testing.expectEqualStrings("foo", paragraph.children[0].text);
    try std.testing.expectEqual(NodeKind.soft_break, paragraph.children[1].kind);
    try std.testing.expectEqualStrings("bar", paragraph.children[2].text);
    try std.testing.expectEqual(NodeKind.soft_break, paragraph.children[3].kind);
    try std.testing.expectEqualStrings("===", paragraph.children[4].text);
}

test "markdown: unquoted blank lines split adjacent block quotes" {
    const source =
        \\> foo
        \\
        \\> bar
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);
    try std.testing.expectEqual(NodeKind.block_quote, document.children[0].kind);
    try std.testing.expectEqual(NodeKind.block_quote, document.children[1].kind);
    try std.testing.expectEqualStrings("foo", document.children[0].children[0].children[0].text);
    try std.testing.expectEqualStrings("bar", document.children[1].children[0].children[0].text);
}

test "markdown: accepts tabs after heading and list markers" {
    const source = "#\tTabbed Heading\n\n1)\tfirst\n-\tbullet";

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 3), document.children.len);

    const heading = document.children[0];
    try std.testing.expectEqual(NodeKind.heading, heading.kind);
    try std.testing.expectEqualStrings("Tabbed Heading", heading.children[0].text);

    const ordered = document.children[1];
    try std.testing.expectEqual(NodeKind.list, ordered.kind);
    try std.testing.expect(ordered.ordered);
    try std.testing.expectEqual(@as(usize, 1), ordered.children.len);
    try std.testing.expectEqualStrings("first", ordered.children[0].children[0].children[0].text);

    const bullet = document.children[2];
    try std.testing.expectEqual(NodeKind.list, bullet.kind);
    try std.testing.expectEqual(@as(usize, 1), bullet.children.len);
    try std.testing.expectEqualStrings("bullet", bullet.children[0].children[0].children[0].text);
}

test "markdown: parses empty list items" {
    const source =
        \\-
        \\- second
        \\
        \\1.
        \\2. next
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);

    const bullet = document.children[0];
    try std.testing.expectEqual(NodeKind.list, bullet.kind);
    try std.testing.expectEqual(@as(usize, 2), bullet.children.len);
    try std.testing.expectEqual(@as(usize, 0), bullet.children[0].children.len);
    try std.testing.expectEqual(NodeKind.paragraph, bullet.children[1].children[0].kind);
    try std.testing.expectEqualStrings("second", bullet.children[1].children[0].children[0].text);

    const ordered = document.children[1];
    try std.testing.expectEqual(NodeKind.list, ordered.kind);
    try std.testing.expect(ordered.ordered);
    try std.testing.expectEqual(@as(usize, 2), ordered.children.len);
    try std.testing.expectEqual(@as(usize, 0), ordered.children[0].children.len);
    try std.testing.expectEqual(NodeKind.paragraph, ordered.children[1].children[0].kind);
    try std.testing.expectEqualStrings("next", ordered.children[1].children[0].children[0].text);
}

test "markdown: parses raw html blocks and inline html" {
    const source =
        \\<div class="note">
        \\raw
        \\</div>
        \\
        \\Inline <span data-x="1">html</span> here.
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);

    const block = document.children[0];
    try std.testing.expectEqual(NodeKind.html_block, block.kind);
    try std.testing.expectEqual(HtmlBlockType.block_tag, block.html_block_type);
    try std.testing.expectEqualStrings("<div class=\"note\">\nraw\n</div>", block.text);

    const paragraph = document.children[1];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(NodeKind.text, paragraph.children[0].kind);
    try std.testing.expectEqualStrings("Inline ", paragraph.children[0].text);
    try std.testing.expectEqual(NodeKind.html_inline, paragraph.children[1].kind);
    try std.testing.expectEqualStrings("<span data-x=\"1\">", paragraph.children[1].text);
    try std.testing.expectEqual(NodeKind.text, paragraph.children[2].kind);
    try std.testing.expectEqualStrings("html", paragraph.children[2].text);
    try std.testing.expectEqual(NodeKind.html_inline, paragraph.children[3].kind);
    try std.testing.expectEqualStrings("</span>", paragraph.children[3].text);
}

test "markdown: parses type7 html blocks without interrupting paragraphs" {
    const source =
        \\<a href="/bar\\/)">
        \\
        \\prefix <del>inline</del>
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);

    const block = document.children[0];
    try std.testing.expectEqual(NodeKind.html_block, block.kind);
    try std.testing.expectEqual(HtmlBlockType.type7, block.html_block_type);
    try std.testing.expectEqualStrings("<a href=\"/bar\\\\/)\">", block.text);

    const paragraph = document.children[1];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(NodeKind.text, paragraph.children[0].kind);
    try std.testing.expectEqualStrings("prefix ", paragraph.children[0].text);
    try std.testing.expectEqual(NodeKind.html_inline, paragraph.children[1].kind);
    try std.testing.expectEqualStrings("<del>", paragraph.children[1].text);
}

test "markdown: parses raw html tag blocks across blank lines" {
    const source =
        \\<script>
        \\if (x < 1) {
        \\
        \\  // not markdown
        \\}
        \\</script>
        \\
        \\after
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);

    const block = document.children[0];
    try std.testing.expectEqual(NodeKind.html_block, block.kind);
    try std.testing.expectEqualStrings(
        "<script>\nif (x < 1) {\n\n  // not markdown\n}\n</script>",
        block.text,
    );

    const paragraph = document.children[1];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqualStrings("after", paragraph.children[0].text);
}

test "markdown: parses reference links and autolinks" {
    const source =
        \\[ref]: https://example.com "site"
        \\
        \\Use [ref], [text][ref], [ref][], <https://ziglang.org>, and <user@example.com>.
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 11), paragraph.children.len);

    try std.testing.expectEqualStrings("Use ", paragraph.children[0].text);

    const shortcut = paragraph.children[1];
    try std.testing.expectEqual(NodeKind.link, shortcut.kind);
    try std.testing.expectEqualStrings("https://example.com", shortcut.destination);
    try std.testing.expectEqualStrings("site", shortcut.title);
    try std.testing.expectEqualStrings("ref", shortcut.children[0].text);

    const full = paragraph.children[3];
    try std.testing.expectEqual(NodeKind.link, full.kind);
    try std.testing.expectEqualStrings("https://example.com", full.destination);
    try std.testing.expectEqualStrings("text", full.children[0].text);

    const collapsed = paragraph.children[5];
    try std.testing.expectEqual(NodeKind.link, collapsed.kind);
    try std.testing.expectEqualStrings("https://example.com", collapsed.destination);
    try std.testing.expectEqualStrings("ref", collapsed.children[0].text);

    const uri = paragraph.children[7];
    try std.testing.expectEqual(NodeKind.link, uri.kind);
    try std.testing.expectEqualStrings("https://ziglang.org", uri.destination);
    try std.testing.expectEqualStrings("https://ziglang.org", uri.children[0].text);

    const email = paragraph.children[9];
    try std.testing.expectEqual(NodeKind.link, email.kind);
    try std.testing.expectEqualStrings("mailto:user@example.com", email.destination);
    try std.testing.expectEqualStrings("user@example.com", email.children[0].text);
}

test "markdown: parses multiline reference definitions and paren titles" {
    const source =
        \\[Ref Label]: <https://example.com/docs>
        \\  (Docs Title)
        \\
        \\See [ref label] and [Shown][REF LABEL].
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 5), paragraph.children.len);

    const shortcut = paragraph.children[1];
    try std.testing.expectEqual(NodeKind.link, shortcut.kind);
    try std.testing.expectEqualStrings("https://example.com/docs", shortcut.destination);
    try std.testing.expectEqualStrings("Docs Title", shortcut.title);
    try std.testing.expectEqualStrings("ref label", shortcut.children[0].text);

    const full = paragraph.children[3];
    try std.testing.expectEqual(NodeKind.link, full.kind);
    try std.testing.expectEqualStrings("https://example.com/docs", full.destination);
    try std.testing.expectEqualStrings("Docs Title", full.title);
    try std.testing.expectEqualStrings("Shown", full.children[0].text);
    try std.testing.expectEqualStrings(".", paragraph.children[4].text);
}

test "markdown: resolves reference links defined later in the document" {
    const source =
        \\[foo]
        \\
        \\[foo]: /bar\* "ti\*tle"
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 1), paragraph.children.len);

    const link = paragraph.children[0];
    try std.testing.expectEqual(NodeKind.link, link.kind);
    try std.testing.expectEqualStrings("/bar*", link.destination);
    try std.testing.expectEqualStrings("ti*tle", link.title);
    try std.testing.expectEqualStrings("foo", link.children[0].text);
}

test "markdown: parses reference definition destinations with balanced parens" {
    const source =
        \\[ref]: https://example.com/a(b)c "site"
        \\
        \\Use [ref].
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 3), paragraph.children.len);

    const link = paragraph.children[1];
    try std.testing.expectEqual(NodeKind.link, link.kind);
    try std.testing.expectEqualStrings("https://example.com/a(b)c", link.destination);
    try std.testing.expectEqualStrings("site", link.title);
    try std.testing.expectEqualStrings("ref", link.children[0].text);
    try std.testing.expectEqualStrings(".", paragraph.children[2].text);
}

test "markdown: parses multiline reference definitions with empty destinations" {
    const source =
        \\[foo]:
        \\      <>
        \\           'the title'
        \\
        \\[foo]
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 1), paragraph.children.len);

    const link = paragraph.children[0];
    try std.testing.expectEqual(NodeKind.link, link.kind);
    try std.testing.expectEqualStrings("", link.destination);
    try std.testing.expectEqualStrings("the title", link.title);
}

test "markdown: rejects reference definitions without title whitespace" {
    const source =
        \\[foo]: <bar>(baz)
        \\
        \\[foo]
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);
    try std.testing.expectEqual(NodeKind.paragraph, document.children[0].kind);
    try std.testing.expectEqual(NodeKind.paragraph, document.children[1].kind);
    for (document.children[0].children) |child| {
        try std.testing.expect(child.kind != .link);
    }
    try std.testing.expectEqualStrings("[foo]", document.children[1].children[0].text);
}

test "markdown: unescapes text links autolinks and fenced code info" {
    const source =
        \\Escaped \*text\* and \#hash.
        \\
        \\[x](/bar\* "ti\*tle")
        \\
        \\<https://example.com?find=\*>
        \\
        \\``` foo\+bar
        \\ok
        \\```
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 4), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 1), paragraph.children.len);
    try std.testing.expectEqual(NodeKind.text, paragraph.children[0].kind);
    try std.testing.expectEqualStrings("Escaped *text* and #hash.", paragraph.children[0].text);

    const link_paragraph = document.children[1];
    const link = link_paragraph.children[0];
    try std.testing.expectEqual(NodeKind.link, link.kind);
    try std.testing.expectEqualStrings("/bar*", link.destination);
    try std.testing.expectEqualStrings("ti*tle", link.title);

    const autolink_paragraph = document.children[2];
    const autolink = autolink_paragraph.children[0];
    try std.testing.expectEqual(NodeKind.link, autolink.kind);
    try std.testing.expectEqualStrings("https://example.com?find=%5C*", autolink.destination);
    try std.testing.expectEqualStrings("https://example.com?find=\\*", autolink.children[0].text);

    const code_block = document.children[3];
    try std.testing.expectEqual(NodeKind.code_block, code_block.kind);
    try std.testing.expectEqualStrings("foo+bar", code_block.info);
}

test "markdown: strips opening fence indentation from fenced code content" {
    const source =
        \\ ```
        \\ aaa
        \\aaa
        \\```
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const code_block = document.children[0];
    try std.testing.expectEqual(NodeKind.code_block, code_block.kind);
    try std.testing.expectEqualStrings("aaa\naaa", code_block.text);
}

test "markdown: backtick fences reject info strings containing backticks" {
    const source =
        \\``` ```
        \\aaa
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(NodeKind.code_span, paragraph.children[0].kind);
}

test "markdown: decodes character references outside code and raw html" {
    const source =
        \\&ouml; &#35; &#0; &MadeUpEntity;
        \\
        \\[foo](/f&ouml;&ouml; "f&ouml;&ouml;")
        \\
        \\``` f&ouml;&ouml;
        \\ok
        \\```
        \\
        \\`f&ouml;&ouml;`
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 4), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 1), paragraph.children.len);
    try std.testing.expectEqualStrings("ö # � &MadeUpEntity;", paragraph.children[0].text);

    const link = document.children[1].children[0];
    try std.testing.expectEqual(NodeKind.link, link.kind);
    try std.testing.expectEqualStrings("/föö", link.destination);
    try std.testing.expectEqualStrings("föö", link.title);

    const code_block = document.children[2];
    try std.testing.expectEqual(NodeKind.code_block, code_block.kind);
    try std.testing.expectEqualStrings("föö", code_block.info);

    const code_span = document.children[3].children[0];
    try std.testing.expectEqual(NodeKind.code_span, code_span.kind);
    try std.testing.expectEqualStrings("f&ouml;&ouml;", code_span.text);
}

test "markdown: parses inline links with nested parens and images" {
    const source =
        \\See [deep](https://example.com/a(b)c "site") and ![alt](<https://example.com/img(test).png> 'img').
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 5), paragraph.children.len);

    const link = paragraph.children[1];
    try std.testing.expectEqual(NodeKind.link, link.kind);
    try std.testing.expectEqualStrings("https://example.com/a(b)c", link.destination);
    try std.testing.expectEqualStrings("site", link.title);
    try std.testing.expectEqualStrings("deep", link.children[0].text);

    const image = paragraph.children[3];
    try std.testing.expectEqual(NodeKind.image, image.kind);
    try std.testing.expectEqualStrings("https://example.com/img(test).png", image.destination);
    try std.testing.expectEqualStrings("img", image.title);
    try std.testing.expectEqualStrings("alt", image.children[0].text);
    try std.testing.expectEqualStrings(".", paragraph.children[4].text);
}

test "markdown: parses empty inline link destinations and rejects invalid angle forms" {
    const source =
        \\[link]()
        \\
        \\[link](<>)
        \\
        \\[bad](<foo
        \\bar>)
        \\
        \\[bad](<foo\>)
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 4), document.children.len);

    try std.testing.expectEqual(NodeKind.link, document.children[0].children[0].kind);
    try std.testing.expectEqualStrings("", document.children[0].children[0].destination);

    try std.testing.expectEqual(NodeKind.link, document.children[1].children[0].kind);
    try std.testing.expectEqualStrings("", document.children[1].children[0].destination);

    try std.testing.expectEqual(NodeKind.paragraph, document.children[2].kind);
    try std.testing.expect(!nodesContainKind(document.children[2].children, .link));
    try std.testing.expectEqual(NodeKind.paragraph, document.children[3].kind);
    try std.testing.expect(!nodesContainKind(document.children[3].children, .link));
}

test "markdown: parses nested brackets in link and image labels" {
    const source =
        \\See [outer [inner]](https://example.com) and ![image [alt]](img.png).
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 5), paragraph.children.len);

    const link = paragraph.children[1];
    try std.testing.expectEqual(NodeKind.link, link.kind);
    try std.testing.expectEqualStrings("https://example.com", link.destination);
    try std.testing.expectEqualStrings("outer [inner]", link.children[0].text);

    const image = paragraph.children[3];
    try std.testing.expectEqual(NodeKind.image, image.kind);
    try std.testing.expectEqualStrings("img.png", image.destination);
    try std.testing.expectEqualStrings("image [alt]", image.children[0].text);
    try std.testing.expectEqualStrings(".", paragraph.children[4].text);
}

test "markdown: outer links are rejected when their labels contain links" {
    const source =
        \\[foo [bar](/uri)](/uri)
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 3), paragraph.children.len);
    try std.testing.expectEqualStrings("[foo ", paragraph.children[0].text);
    try std.testing.expectEqual(NodeKind.link, paragraph.children[1].kind);
    try std.testing.expectEqualStrings("/uri", paragraph.children[1].destination);
    try std.testing.expectEqualStrings("bar", paragraph.children[1].children[0].text);
    try std.testing.expectEqualStrings("](/uri)", paragraph.children[2].text);
}

test "markdown: link labels ignore closing brackets inside inline html" {
    const source =
        \\See [a <span data-x="]">tag</span>](https://example.com).
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 3), paragraph.children.len);

    const link = paragraph.children[1];
    try std.testing.expectEqual(NodeKind.link, link.kind);
    try std.testing.expectEqualStrings("https://example.com", link.destination);
    try std.testing.expectEqual(@as(usize, 4), link.children.len);
    try std.testing.expectEqualStrings("a ", link.children[0].text);
    try std.testing.expectEqual(NodeKind.html_inline, link.children[1].kind);
    try std.testing.expectEqualStrings("<span data-x=\"]\">", link.children[1].text);
    try std.testing.expectEqualStrings("tag", link.children[2].text);
    try std.testing.expectEqualStrings("</span>", link.children[3].text);
    try std.testing.expectEqualStrings(".", paragraph.children[2].text);
}

test "markdown: inline html respects greater-than inside quoted attributes" {
    const source =
        \\Inline <span data-x=">">html</span> and [a <span data-x=">">tag</span>](https://example.com).
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);

    try std.testing.expectEqual(NodeKind.html_inline, paragraph.children[1].kind);
    try std.testing.expectEqualStrings("<span data-x=\">\">", paragraph.children[1].text);
    try std.testing.expectEqualStrings("html", paragraph.children[2].text);
    try std.testing.expectEqualStrings("</span>", paragraph.children[3].text);

    const link = paragraph.children[5];
    try std.testing.expectEqual(NodeKind.link, link.kind);
    try std.testing.expectEqualStrings("https://example.com", link.destination);
    try std.testing.expectEqual(NodeKind.html_inline, link.children[1].kind);
    try std.testing.expectEqualStrings("<span data-x=\">\">", link.children[1].text);
    try std.testing.expectEqualStrings("tag", link.children[2].text);
    try std.testing.expectEqualStrings("</span>", link.children[3].text);
    try std.testing.expectEqualStrings(".", paragraph.children[6].text);
}

test "markdown: parses multiline inline html tags with quoted attributes" {
    const source =
        \\<a foo="bar" bam = 'baz <em>"</em>'
        \\_boolean zoop:33=zoop:33 />
    ;

    try std.testing.expectEqual(source.len, parseInlineHtmlEnd(source, 0).?);

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 1), paragraph.children.len);
    try std.testing.expectEqual(NodeKind.html_inline, paragraph.children[0].kind);
    try std.testing.expectEqualStrings(source, paragraph.children[0].text);
}

test "markdown: blockquote html blocks remain raw html blocks" {
    const source =
        \\<strong> <title> <style> <em>
        \\
        \\<blockquote>
        \\  <xmp> is disallowed.  <XMP> is also disallowed.
        \\</blockquote>
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);
    try std.testing.expectEqual(NodeKind.paragraph, document.children[0].kind);
    try std.testing.expectEqual(NodeKind.html_block, document.children[1].kind);
    try std.testing.expectEqualStrings(
        "<blockquote>\n  <xmp> is disallowed.  <XMP> is also disallowed.\n</blockquote>",
        document.children[1].text,
    );
}

test "markdown: parses gfm tables" {
    const source =
        \\| Name | Score | Notes |
        \\| :--- | ---: | :---: |
        \\| Ada | 10 | `x|y` |
        \\| Bob | 7 |
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const table = document.children[0];
    try std.testing.expectEqual(NodeKind.table, table.kind);
    try std.testing.expectEqual(@as(usize, 2), table.children.len);

    const head = table.children[0];
    try std.testing.expectEqual(NodeKind.table_head, head.kind);
    try std.testing.expectEqual(@as(usize, 1), head.children.len);

    const header_row = head.children[0];
    try std.testing.expectEqual(NodeKind.table_row, header_row.kind);
    try std.testing.expectEqual(@as(usize, 3), header_row.children.len);
    try std.testing.expectEqual(NodeKind.table_cell, header_row.children[0].kind);
    try std.testing.expectEqual(TableAlignment.left, header_row.children[0].alignment);
    try std.testing.expectEqualStrings("Name", header_row.children[0].children[0].text);
    try std.testing.expectEqual(TableAlignment.right, header_row.children[1].alignment);
    try std.testing.expectEqual(TableAlignment.center, header_row.children[2].alignment);

    const body = table.children[1];
    try std.testing.expectEqual(NodeKind.table_body, body.kind);
    try std.testing.expectEqual(@as(usize, 2), body.children.len);

    const first_row = body.children[0];
    try std.testing.expectEqual(NodeKind.table_row, first_row.kind);
    try std.testing.expectEqual(NodeKind.code_span, first_row.children[2].children[0].kind);
    try std.testing.expectEqualStrings("x|y", first_row.children[2].children[0].text);

    const second_row = body.children[1];
    try std.testing.expectEqual(@as(usize, 3), second_row.children.len);
    try std.testing.expectEqual(@as(usize, 0), second_row.children[2].children.len);
}

test "markdown: parses gfm autolink literals" {
    const source =
        \\Visit https://example.com/path(a), www.ziglang.org/docs, and user.name@example.com.
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 7), paragraph.children.len);

    try std.testing.expectEqualStrings("Visit ", paragraph.children[0].text);

    const uri = paragraph.children[1];
    try std.testing.expectEqual(NodeKind.link, uri.kind);
    try std.testing.expectEqualStrings("https://example.com/path(a)", uri.destination);
    try std.testing.expectEqualStrings("https://example.com/path(a)", uri.children[0].text);

    const www = paragraph.children[3];
    try std.testing.expectEqual(NodeKind.link, www.kind);
    try std.testing.expectEqualStrings("http://www.ziglang.org/docs", www.destination);
    try std.testing.expectEqualStrings("www.ziglang.org/docs", www.children[0].text);

    const email = paragraph.children[5];
    try std.testing.expectEqual(NodeKind.link, email.kind);
    try std.testing.expectEqualStrings("mailto:user.name@example.com", email.destination);
    try std.testing.expectEqualStrings("user.name@example.com", email.children[0].text);
    try std.testing.expectEqualStrings(".", paragraph.children[6].text);
}

test "markdown: respects delimiter flanking rules" {
    const source =
        \\foo_bar_baz and _emphasis_ plus **strong** and ~~strike~~.
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 7), paragraph.children.len);
    try std.testing.expectEqualStrings("foo_bar_baz and ", paragraph.children[0].text);

    const emphasis = paragraph.children[1];
    try std.testing.expectEqual(NodeKind.emphasis, emphasis.kind);
    try std.testing.expectEqualStrings("emphasis", emphasis.children[0].text);

    const strong = paragraph.children[3];
    try std.testing.expectEqual(NodeKind.strong, strong.kind);
    try std.testing.expectEqualStrings("strong", strong.children[0].text);

    const strike = paragraph.children[5];
    try std.testing.expectEqual(NodeKind.strikethrough, strike.kind);
    try std.testing.expectEqualStrings("strike", strike.children[0].text);
    try std.testing.expectEqualStrings(".", paragraph.children[6].text);
}

test "markdown: normalizes code span spaces" {
    const source =
        \\Use `` code `` and `  `.
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 5), paragraph.children.len);

    const trimmed = paragraph.children[1];
    try std.testing.expectEqual(NodeKind.code_span, trimmed.kind);
    try std.testing.expectEqualStrings("code", trimmed.text);

    const spaces = paragraph.children[3];
    try std.testing.expectEqual(NodeKind.code_span, spaces.kind);
    try std.testing.expectEqualStrings("  ", spaces.text);
    try std.testing.expectEqualStrings(".", paragraph.children[4].text);
}

test "markdown: code spans match exact backtick runs" {
    const source =
        \\` `` `
        \\
        \\`  ``  `
        \\
        \\` foo `` bar `
        \\
        \\`foo``bar``
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 4), document.children.len);

    try std.testing.expectEqualStrings("``", document.children[0].children[0].text);
    try std.testing.expectEqualStrings(" `` ", document.children[1].children[0].text);
    try std.testing.expectEqualStrings("foo `` bar", document.children[2].children[0].text);

    const final_paragraph = document.children[3];
    try std.testing.expectEqual(NodeKind.paragraph, final_paragraph.kind);
    try std.testing.expectEqualStrings("`foo", final_paragraph.children[0].text);
    try std.testing.expectEqual(NodeKind.code_span, final_paragraph.children[1].kind);
    try std.testing.expectEqualStrings("bar", final_paragraph.children[1].text);
}

test "markdown: parses mixed triple delimiter runs" {
    const source =
        \\***triple*** and ****quad****
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);

    const paragraph = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, paragraph.kind);
    try std.testing.expectEqual(@as(usize, 3), paragraph.children.len);

    const triple = paragraph.children[0];
    try std.testing.expectEqual(NodeKind.emphasis, triple.kind);
    try std.testing.expectEqual(@as(usize, 1), triple.children.len);
    try std.testing.expectEqual(NodeKind.strong, triple.children[0].kind);
    try std.testing.expectEqualStrings("triple", triple.children[0].children[0].text);

    const quad = paragraph.children[2];
    try std.testing.expectEqual(NodeKind.strong, quad.kind);
    try std.testing.expectEqual(@as(usize, 1), quad.children.len);
    try std.testing.expectEqual(NodeKind.strong, quad.children[0].kind);
    try std.testing.expectEqualStrings("quad", quad.children[0].children[0].text);
}

test "markdown: preserves rule-of-three delimiter cases" {
    const source =
        \\*foo**bar*
        \\
        \\foo******bar*********baz
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);

    const first = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, first.kind);
    try std.testing.expectEqual(@as(usize, 1), first.children.len);
    try std.testing.expectEqual(NodeKind.emphasis, first.children[0].kind);
    try std.testing.expectEqualStrings("foo**bar", first.children[0].children[0].text);

    const second = document.children[1];
    try std.testing.expectEqual(NodeKind.paragraph, second.kind);
    try std.testing.expectEqual(@as(usize, 3), second.children.len);
    try std.testing.expectEqualStrings("foo", second.children[0].text);
    try std.testing.expectEqual(NodeKind.strong, second.children[1].kind);
    try std.testing.expectEqual(NodeKind.strong, second.children[1].children[0].kind);
    try std.testing.expectEqual(NodeKind.strong, second.children[1].children[0].children[0].kind);
    try std.testing.expectEqualStrings(
        "bar",
        second.children[1].children[0].children[0].children[0].text,
    );
    try std.testing.expectEqualStrings("***baz", second.children[2].text);
}

test "markdown: resolves unicode reference labels with case folding" {
    const source =
        \\[ΑΓΩ]: /φου
        \\
        \\[αγω]
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    const link = document.children[0].children[0];
    try std.testing.expectEqual(NodeKind.link, link.kind);
    try std.testing.expectEqualStrings("/φου", link.destination);
}

test "markdown: parses multiline reference definitions and rejects nested reference labels" {
    const source =
        \\[
        \\foo
        \\]: /url
        \\
        \\[Baz][Foo]
        \\
        \\[foo][ref[bar]]
        \\
        \\[ref[bar]]: /uri
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 3), document.children.len);

    const resolved = document.children[0].children[0];
    try std.testing.expectEqual(NodeKind.link, resolved.kind);
    try std.testing.expectEqualStrings("/url", resolved.destination);

    try std.testing.expectEqualStrings("[foo][ref[bar]]", document.children[1].children[0].text);
    try std.testing.expectEqualStrings("[ref[bar]]: /uri", document.children[2].children[0].text);
}

test "markdown: treats unicode whitespace and letters in delimiter flanking" {
    const source =
        \\* a *
        \\
        \\пристаням_стремятся_
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    const first = document.children[0];
    try std.testing.expectEqual(NodeKind.paragraph, first.kind);
    try std.testing.expectEqual(@as(usize, 1), first.children.len);
    try std.testing.expectEqualStrings("* a *", first.children[0].text);

    const second = document.children[1];
    try std.testing.expectEqual(NodeKind.paragraph, second.kind);
    try std.testing.expectEqual(@as(usize, 1), second.children.len);
    try std.testing.expectEqualStrings("пристаням_стремятся_", second.children[0].text);
}

test "markdown: bullet lists with different markers split" {
    const source =
        \\- foo
        \\- bar
        \\+ baz
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);
    try std.testing.expectEqual(NodeKind.list, document.children[0].kind);
    try std.testing.expectEqual(NodeKind.list, document.children[1].kind);
    try std.testing.expectEqual(@as(usize, 2), document.children[0].children.len);
    try std.testing.expectEqual(@as(usize, 1), document.children[1].children.len);
}

test "markdown: empty list markers do not interrupt paragraphs" {
    const source =
        \\foo
        \\*
        \\
        \\foo
        \\1.
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.children.len);
    try std.testing.expectEqual(NodeKind.paragraph, document.children[0].kind);
    try std.testing.expectEqual(NodeKind.paragraph, document.children[1].kind);
    try std.testing.expectEqualStrings("*", document.children[0].children[2].text);
    try std.testing.expectEqualStrings("1.", document.children[1].children[2].text);
}

test "markdown: blank lines between list items make lists loose" {
    const source =
        \\- a
        \\
        \\- b
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.children.len);
    try std.testing.expectEqual(NodeKind.list, document.children[0].kind);
    try std.testing.expect(!document.children[0].tight);
}

test "markdown: nested blank lines do not loosen outer lists" {
    const source =
        \\- a
        \\  - b
        \\
        \\    c
        \\- d
    ;

    var document = try parse(std.testing.allocator, source);
    defer document.deinit();

    const list = document.children[0];
    try std.testing.expectEqual(NodeKind.list, list.kind);
    try std.testing.expect(list.tight);
    try std.testing.expectEqual(@as(usize, 2), list.children.len);

    const nested = list.children[0].children[1];
    try std.testing.expectEqual(NodeKind.list, nested.kind);
    try std.testing.expect(!nested.tight);
}

test "markdown: block quote lazy continuation stops at code and fences" {
    {
        const source =
            \\>     foo
            \\    bar
        ;

        var document = try parse(std.testing.allocator, source);
        defer document.deinit();

        try std.testing.expectEqual(@as(usize, 2), document.children.len);
        try std.testing.expectEqual(NodeKind.block_quote, document.children[0].kind);
        try std.testing.expectEqual(NodeKind.code_block, document.children[1].kind);
    }

    {
        const source =
            \\> ```
            \\foo
            \\```
        ;

        var document = try parse(std.testing.allocator, source);
        defer document.deinit();

        try std.testing.expectEqual(@as(usize, 3), document.children.len);
        try std.testing.expectEqual(NodeKind.block_quote, document.children[0].kind);
        try std.testing.expectEqual(NodeKind.paragraph, document.children[1].kind);
        try std.testing.expectEqual(NodeKind.code_block, document.children[2].kind);
    }
}

test "markdown: tables accept outer-pipe single cells and pipe-free body rows" {
    {
        const source =
            \\| f\|oo |
            \\| ----- |
            \\| bar |
        ;

        var document = try parse(std.testing.allocator, source);
        defer document.deinit();

        try std.testing.expectEqual(@as(usize, 1), document.children.len);
        try std.testing.expectEqual(NodeKind.table, document.children[0].kind);
    }

    {
        const source =
            \\| abc | def |
            \\| --- | --- |
            \\bar
        ;

        var document = try parse(std.testing.allocator, source);
        defer document.deinit();

        const table = document.children[0];
        try std.testing.expectEqual(NodeKind.table, table.kind);
        try std.testing.expectEqual(@as(usize, 2), table.children.len);
        try std.testing.expectEqual(@as(usize, 1), table.children[1].children.len);
        try std.testing.expectEqual(@as(usize, 0), table.children[1].children[0].children[1].children.len);
    }
}
