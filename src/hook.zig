// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The PostToolUse hook: read the tool payload, check the edited .zig file with zsnag and
//! `zig ast-check`, record what survives to the book, and feed the findings back grouped by
//! priority. Nothing is hidden — the tier only labels urgency.
const std = @import("std");
const vars = @import("vars.zig");
const tier = @import("tier.zig");
const book = @import("book.zig");

/// Claude Code truncates nothing for us; keep the context bounded so a pathological file
/// cannot flood the conversation.
pub const MAX_CONTEXT = 9000;

pub const HINT = "\n\n(Confirm current std APIs against the zephem map before writing them: " ++
    "`$ZEPHEM_HOME/zig-out/bin/zephem look <name>`.)";

pub const Finding = struct {
    rule: []const u8,
    severity: []const u8,
    line: u32,
    col: u32,
    message: []const u8,
};

/// `tool_input.file_path` is the only field we need from the payload.
pub fn filePathFromPayload(arena: std.mem.Allocator, payload: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch return null;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };
    const ti = switch (obj.get("tool_input") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (ti.get("file_path") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// zsnag emits JSONL — a status record, then one object per finding. Lines that aren't
/// objects are skipped.
///
/// `groups` collects the rule groups zsnag reports as having actually run. The caller must
/// prune the book only for those: zsnag exits 0 even when the zephem map failed to load, so
/// "no map findings" and "the map rules never ran" are otherwise indistinguishable.
pub fn parseSnagJson(
    arena: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayList(Finding),
    groups: ?*std.ArrayList([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] != '{') continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        const o = switch (v) {
            .object => |x| x,
            else => continue,
        };
        if (strField(o, "zsnag")) |kind| {
            if (std.mem.eql(u8, kind, "status")) {
                if (groups) |g| switch (o.get("ran") orelse std.json.Value.null) {
                    .array => |arr| for (arr.items) |item| switch (item) {
                        .string => |s| try g.append(arena, s),
                        else => {},
                    },
                    else => {},
                };
                continue;
            }
        }
        try out.append(arena, .{
            .rule = strField(o, "rule") orelse continue,
            .severity = strField(o, "severity") orelse "info",
            .line = intField(o, "line") orelse 0,
            .col = intField(o, "col") orelse 0,
            .message = strField(o, "message") orelse continue,
        });
    }
}

fn strField(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (o.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn intField(o: std.json.ObjectMap, name: []const u8) ?u32 {
    return switch (o.get(name) orelse return null) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null, // zsnag:ok — range-checked
        else => null,
    };
}

/// Parse `zig ast-check` diagnostics: `<file>:<line>:<col>: error: <message>`.
///
/// Split on the ": error: " separator first and take line/col from the RIGHT of the file
/// part, rather than matching `[^:]+` for the filename — a path containing a colon parses
/// correctly this way. `note:` continuation lines are kept as advisory context instead of
/// being dropped.
pub fn parseAstCheck(
    arena: std.mem.Allocator,
    file: []const u8,
    text: []const u8,
    out: *std.ArrayList(Finding),
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) continue;

        // Two guards, because `zig ast-check` ECHOES the offending source line (indented)
        // under each diagnostic, and that echo may itself contain ": error: " — a string
        // literal holding a diagnostic, say. Trimming first and pattern-matching anywhere
        // turned such an echo into a phantom BLOCKING finding.
        //   1. a real diagnostic starts at column 0; the echo and its caret are indented.
        if (line[0] == ' ' or line[0] == '\t') continue;

        const sev: []const u8, const sep: []const u8 = if (std.mem.find(u8, line, ": error: ") != null)
            .{ "error", ": error: " }
        else if (std.mem.find(u8, line, ": note: ") != null)
            .{ "info", ": note: " }
        else
            continue;

        const at = std.mem.find(u8, line, sep).?;
        const loc = line[0..at];
        const msg = line[at + sep.len ..];

        // loc is "<path>:<line>:<col>" — take the last two colon-separated fields.
        const c2 = std.mem.findScalarLast(u8, loc, ':') orelse continue;
        const c1 = std.mem.findScalarLast(u8, loc[0..c2], ':') orelse continue;

        //   2. ast-check only ever reports on the file it was given, so the path must match.
        //      This is what actually kills an unindented echo at column 0.
        if (!std.mem.eql(u8, loc[0..c1], file)) continue;

        const ln = std.fmt.parseInt(u32, loc[c1 + 1 .. c2], 10) catch continue;
        const col = std.fmt.parseInt(u32, loc[c2 + 1 ..], 10) catch continue;

        try out.append(arena, .{
            .rule = book.AST_RULE,
            .severity = sev,
            .line = ln,
            .col = col,
            .message = msg,
        });
    }
}

/// The source line a finding sits on, trimmed — the book's dedup key includes it, so a
/// finding that moves but stays identical is still one finding.
pub fn snippetFor(src: []const u8, line_no: u32) []const u8 {
    if (line_no == 0) return "";
    var n: u32 = 1;
    var start: usize = 0;
    for (src, 0..) |ch, i| {
        if (n == line_no) break;
        if (ch == '\n') {
            n += 1;
            start = i + 1;
        }
    }
    if (n != line_no) return "";
    const end = std.mem.findScalarPos(u8, src, start, '\n') orelse src.len;
    return std.mem.trim(u8, src[start..end], " \t\r");
}

/// Group by tier and render the block Claude sees. Returns null when there is nothing to say.
pub fn renderContext(
    arena: std.mem.Allocator,
    base: []const u8,
    file: []const u8,
    findings: []const Finding,
) !?[]const u8 {
    if (findings.len == 0) return null;

    // Layout is byte-identical to the Nushell original: header, blank line, then tier blocks
    // separated by a blank line. Rows are JOINED by "\n" rather than each carrying a trailing
    // one, so the block does not end with a newline before the separator.
    var w: std.Io.Writer.Allocating = .init(arena);
    try w.writer.print(
        "zsnag + ast-check — findings in {s}, grouped by priority (nothing hidden; lower tiers are informational):\n\n",
        .{base},
    );

    const order = [_]tier.Tier{ .blocking, .caution, .advisory, .expected };
    var first_block = true;
    for (order) |t| {
        var first_row = true;
        for (findings) |f| {
            if (tier.classify(f.severity, file) != t) continue;
            if (first_row) {
                if (!first_block) try w.writer.writeAll("\n\n");
                try w.writer.print("{s}:", .{t.head()});
                first_block = false;
                first_row = false;
            }
            try w.writer.print("\n  [{s}] {s}:{d}:{d}  {s}", .{ f.rule, base, f.line, f.col, f.message });
        }
    }
    return w.written();
}

/// Truncate to at most `max` bytes without splitting a UTF-8 sequence. The tier headers carry
/// `▲ ⚠ ℹ ·` and a filename may be non-ASCII, so a raw byte slice can cut mid-codepoint and
/// produce invalid JSON.
pub fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    // Walk back off any continuation bytes (0b10xxxxxx) to land on a lead byte.
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// Assemble the final context: findings, then any notices, then the hint — bounded by
/// MAX_CONTEXT as a whole.
///
/// The budget is taken from the *findings* only. Notices explain why a check did not run and
/// the hint says how to look an API up; both are short and both are useless to drop, so they
/// are reserved rather than truncated away. Returns null when there is nothing to say.
pub fn compose(arena: std.mem.Allocator, body: []const u8, notices: []const []const u8) !?[]const u8 {
    var extra: usize = HINT.len;
    for (notices) |n| extra += n.len;
    if (body.len == 0 and extra == HINT.len) return null;

    const budget = if (extra >= MAX_CONTEXT) 0 else MAX_CONTEXT - extra;
    var w: std.Io.Writer.Allocating = .init(arena);
    try w.writer.writeAll(truncateUtf8(body, budget));
    for (notices) |n| try w.writer.writeAll(n);
    try w.writer.writeAll(HINT);
    return w.written();
}

/// The PostToolUse response envelope. `hookSpecificOutput.additionalContext` is the modern
/// nested form; a bare top-level `additionalContext` is ignored by current Claude Code.
pub fn renderResponse(arena: std.mem.Allocator, context: []const u8) ![]u8 {
    var root: std.json.ObjectMap = .empty;
    var inner: std.json.ObjectMap = .empty;
    try inner.put(arena, "hookEventName", .{ .string = "PostToolUse" });
    try inner.put(arena, "additionalContext", .{ .string = context });
    try root.put(arena, "hookSpecificOutput", .{ .object = inner });
    return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = root }, .{});
}

/// Collapse findings identical under the BOOK's dedup key — (rule, message, snippet); the
/// file is the same for every finding in one hook run.
///
/// The Nushell original ended `build-recs` with `uniq-by file rule message snippet` and
/// rendered from that. Without it, a duplicate renders twice AND `Book.upsert` bumps `hits`
/// twice within a single batch, corrupting a counter documented as "real recurrences, not
/// repeated saves of a fix".
pub fn dedup(arena: std.mem.Allocator, src: []const u8, items: []const Finding) ![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    for (items) |f| {
        const snip = snippetFor(src, f.line);
        const dup = for (out.items) |seen| {
            if (std.mem.eql(u8, seen.rule, f.rule) and
                std.mem.eql(u8, seen.message, f.message) and
                std.mem.eql(u8, snippetFor(src, seen.line), snip)) break true;
        } else false;
        if (!dup) try out.append(arena, f);
    }
    return out.items;
}

pub fn sortFindings(items: []Finding) void {
    std.mem.sort(Finding, items, {}, struct {
        fn lt(_: void, a: Finding, b: Finding) bool {
            if (a.line != b.line) return a.line < b.line;
            return a.col < b.col;
        }
    }.lt);
}
