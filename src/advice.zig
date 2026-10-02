// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The skill's "your most repeated mistakes" section, written from the book.
//!
//! The hook corrects a mistake after it is made; this puts the ones actually made most often
//! in front of the model before it writes. The installed SKILL.md carries a marked block that
//! `zcanon setup` fills and the hook refreshes whenever the book changes, so the list tracks
//! the mistakes as they happen, not a guess made once.
//!
//! What is listed: warn/error mistakes made at least `min_count` times, grouped by the advice
//! that prevents them (all shadowing errors are one line), most frequent first. What is not:
//!   - advisories (`info`: R007's casts, the compiler's "declared here" notes), which are
//!     reminders, not mistakes;
//!   - errors from an edit in progress (a name used before the edit that defines it, a file
//!     created by the next edit, half-written syntax). They clear on their own, and advice
//!     against them would be noise.
const std = @import("std");
const book = @import("book.zig");

pub const begin_marker = "<!-- zcanon:mistakes -->";
pub const end_marker = "<!-- /zcanon:mistakes -->";
pub const min_count = 2;
pub const max_items = 10;

const Kind = enum { advice, in_progress };

/// Hand-written advice for the compiler's own diagnostics, matched by a substring of the
/// pattern. zsnag's messages need none: each already says what to do.
const Known = struct { needle: []const u8, kind: Kind, title: []const u8 = "", text: []const u8 = "" };

const known = [_]Known{
    .{ .needle = "shadows declaration of", .kind = .advice, .title = "Shadowing", .text = "Zig rejects a local, parameter or capture that reuses any name in scope, including the file's top-level functions, constants and imports. Check the file's top-level names before naming a local (`dot_git`, not `git`)." },
    .{ .needle = "unused function parameter", .kind = .advice, .title = "Unused parameter", .text = "An error, not a warning. Name it `_`, or add `_ = name;` if it must keep its name." },
    .{ .needle = "unused local", .kind = .advice, .title = "Unused local", .text = "An error. Delete it, or `_ = x;` while the code is in progress." },
    .{ .needle = "unused capture", .kind = .advice, .title = "Unused capture", .text = "An error. Capture `|_|`, or drop the capture." },
    .{ .needle = "is never mutated", .kind = .advice, .title = "`var` never mutated", .text = "An error. Declare it `const`." },
    .{ .needle = "switch must handle all possibilities", .kind = .advice, .title = "Non-exhaustive switch", .text = "Cover every tag or add `else`; after adding an enum tag, update every switch on it." },
    .{ .needle = "unreachable else prong", .kind = .advice, .title = "Needless `else` prong", .text = "`else` on a switch that already covers every case is an error. Remove it." },
    .{ .needle = "declarations are not allowed between container fields", .kind = .advice, .title = "Declaration between fields", .text = "In a struct, all fields come first, then the declarations (`fn`, `const`). Never interleave them." },
    .{ .needle = "argument(s), found", .kind = .advice, .title = "Wrong argument count", .text = "Look the signature up (`zephem map doc <path>`) before calling; 0.16 added `io` or allocator parameters to many calls." },
    .{ .needle = "has no member named", .kind = .advice, .title = "Nonexistent std/module member", .text = "`zephem map find` the name before writing it; a name from memory may not exist in this Zig." },
    .{ .needle = "no field named", .kind = .advice, .title = "Nonexistent field", .text = "`zephem map show` the type and use a field it lists, not one from memory." },
    .{ .needle = "expected type", .kind = .advice, .title = "Type mismatch", .text = "Check the parameter's real type in the map before passing a value; 0.16 moved many APIs to `std.Io` types." },
    .{ .needle = "is not marked", .kind = .advice, .title = "Missing `pub`", .text = "A declaration used from another file must be `pub`." },
    .{ .needle = "duplicate struct member name", .kind = .advice, .title = "Duplicate member", .text = "A field and a declaration cannot share a name in one struct." },
    .{ .needle = "string literal contains invalid byte", .kind = .advice, .title = "Raw control byte in a string", .text = "A literal tab or newline cannot go inside a \"…\" string: write `\\t`/`\\n`, or use a `\\\\` multiline string." },
    // An edit in progress, not a misunderstanding.
    .{ .needle = "use of undeclared identifier", .kind = .in_progress },
    .{ .needle = "unable to load", .kind = .in_progress },
    .{ .needle = "unable to open", .kind = .in_progress },
    .{ .needle = "no module named", .kind = .in_progress },
    .{ .needle = "expected expression", .kind = .in_progress },
    .{ .needle = "expected statement", .kind = .in_progress },
};

pub const Item = struct {
    title: []const u8,
    text: []const u8,
    count: u64,
    last_ts: []const u8,
};

fn isCompiler(rule: []const u8) bool {
    return std.mem.eql(u8, rule, book.AST_RULE) or std.mem.eql(u8, rule, book.COMPILE_RULE);
}

/// The listed mistakes, most frequent first. Slices point into `entries` and the static table.
pub fn select(gpa: std.mem.Allocator, entries: []const book.Entry) ![]Item {
    var items: std.ArrayList(Item) = .empty;
    for (entries) |e| {
        if (std.mem.eql(u8, e.severity, "info")) continue;
        var title: []const u8 = e.rule;
        var text: []const u8 = e.pattern;
        // A compiler message with no advice written for it yet keeps its pattern as the text:
        // still a reminder.
        if (isCompiler(e.rule)) {
            if (isInProgress(e.pattern)) continue;
            for (known) |k| if (k.kind == .advice and std.mem.find(u8, e.pattern, k.needle) != null) {
                title = k.title;
                text = k.text;
                break;
            };
        }
        for (items.items) |*it| {
            if (!std.mem.eql(u8, it.title, title) or !std.mem.eql(u8, it.text, text)) continue;
            it.count += e.count;
            if (std.mem.order(u8, e.last_ts, it.last_ts) == .gt) it.last_ts = e.last_ts;
            break;
        } else try items.append(gpa, .{ .title = title, .text = text, .count = e.count, .last_ts = e.last_ts });
    }
    var kept: std.ArrayList(Item) = .empty;
    for (items.items) |it| if (it.count >= min_count) try kept.append(gpa, it);
    std.mem.sortUnstable(Item, kept.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.order(u8, a.title, b.title) == .lt;
        }
    }.lt);
    return kept.items[0..@min(kept.items.len, max_items)];
}

fn isInProgress(pattern: []const u8) bool {
    for (known) |k| if (k.kind == .in_progress and std.mem.find(u8, pattern, k.needle) != null) return true;
    return false;
}

/// The block's body (between the markers).
pub fn render(gpa: std.mem.Allocator, w: *std.Io.Writer, entries: []const book.Entry) !void {
    const items = try select(gpa, entries);
    if (items.len == 0) {
        try w.writeAll("None recorded yet. This list fills in from the book as mistakes are made.\n");
        return;
    }
    try w.writeAll("Written from the book; the hook keeps it current. Avoid these before the hook has to\ncatch them, most frequent first:\n\n");
    for (items) |it| {
        try w.print("- **{s}** ({d}×, last {s}): {s}\n", .{ it.title, it.count, it.last_ts[0..@min(it.last_ts.len, 10)], it.text });
    }
}

/// `text` with the marked block's body replaced by the rendered list. Unchanged (same slice)
/// when the markers are missing, so an old or hand-written skill is left alone.
pub fn fill(gpa: std.mem.Allocator, text: []const u8, entries: []const book.Entry) ![]const u8 {
    const b = std.mem.find(u8, text, begin_marker) orelse return text;
    const body_start = b + begin_marker.len;
    const e = std.mem.findPos(u8, text, body_start, end_marker) orelse return text;
    var out: std.Io.Writer.Allocating = .init(gpa);
    try out.writer.writeAll(text[0..body_start]);
    try out.writer.writeByte('\n');
    try render(gpa, &out.writer, entries);
    try out.writer.writeAll(text[e..]);
    return out.written();
}
