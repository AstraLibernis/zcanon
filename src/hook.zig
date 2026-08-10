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

/// zsnag emits JSONL — one object per finding. Lines that aren't objects are skipped.
pub fn parseSnagJson(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Finding)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] != '{') continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        const o = switch (v) {
            .object => |x| x,
            else => continue,
        };
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
pub fn parseAstCheck(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Finding)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

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
    try w.writer.writeAll(HINT);

    const out = w.written();
    return if (out.len > MAX_CONTEXT) out[0..MAX_CONTEXT] else out;
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

pub fn sortFindings(items: []Finding) void {
    std.mem.sort(Finding, items, {}, struct {
        fn lt(_: void, a: Finding, b: Finding) bool {
            if (a.line != b.line) return a.line < b.line;
            return a.col < b.col;
        }
    }.lt);
}
