// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The bug report: mistakes made again and again. When a line of the book's history reaches
//! `threshold` — the same rule and message pattern, made that many separate times — it is
//! entered here, and from then on only updated. Nothing is ever
//! removed, even if the book is pruned or purged: this is the durable record of what the
//! model keeps getting wrong, and so of where a new rule or a line in the skill would pay.
//!
//! Only errors and warnings count. Advisory findings (R007 casts, R010 prints) are normal in
//! correct code, and would bury the real repeats.
//!
//! Stored as `bugs.tsv`, and rendered to `bugs.md` beside it for reading.
const std = @import("std");
const book = @import("book.zig");

/// Occurrences of one pattern before it is reported.
pub const threshold = 5;

pub const Bug = struct {
    rule: []const u8,
    pattern: []const u8,
    occurrences: u64,
    first_ts: []const u8,
    last_ts: []const u8,
    /// When it crossed the threshold.
    reported_ts: []const u8,
    /// The latest occurrence, verbatim.
    example_file: []const u8,
    example_line: u32,
    example_message: []const u8,
    example_snippet: []const u8,
};

pub const header = "rule\tpattern\toccurrences\tfirst_ts\tlast_ts\treported_ts\texample_file\texample_line\texample_message\texample_snippet";
const n_cols = 10;

pub fn parse(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Bug)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "rule\t")) continue;
        var f: [n_cols][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, '\t');
        var n: usize = 0;
        while (it.next()) |field| : (n += 1) {
            if (n >= n_cols) break;
            f[n] = field;
        }
        if (n != n_cols) continue;
        try out.append(gpa, .{
            .rule = try book.unescape(gpa, f[0]),
            .pattern = try book.unescape(gpa, f[1]),
            .occurrences = std.fmt.parseInt(u64, f[2], 10) catch continue,
            .first_ts = try book.unescape(gpa, f[3]),
            .last_ts = try book.unescape(gpa, f[4]),
            .reported_ts = try book.unescape(gpa, f[5]),
            .example_file = try book.unescape(gpa, f[6]),
            .example_line = std.fmt.parseInt(u32, f[7], 10) catch 0,
            .example_message = try book.unescape(gpa, f[8]),
            .example_snippet = try book.unescape(gpa, f[9]),
        });
    }
}

pub fn write(w: *std.Io.Writer, bugs: []const Bug) !void {
    try w.writeAll(header);
    try w.writeByte('\n');
    for (bugs) |b| {
        try book.escape(w, b.rule);
        try w.writeByte('\t');
        try book.escape(w, b.pattern);
        try w.print("\t{d}\t", .{b.occurrences});
        try book.escape(w, b.first_ts);
        try w.writeByte('\t');
        try book.escape(w, b.last_ts);
        try w.writeByte('\t');
        try book.escape(w, b.reported_ts);
        try w.writeByte('\t');
        try book.escape(w, b.example_file);
        try w.print("\t{d}\t", .{b.example_line});
        try book.escape(w, b.example_message);
        try w.writeByte('\t');
        try book.escape(w, b.example_snippet);
        try w.writeByte('\n');
    }
}

fn counts(severity: []const u8) bool {
    return std.mem.eql(u8, severity, "error") or std.mem.eql(u8, severity, "warn");
}

/// Fold the history into the report: add every mistake made `threshold` times or more,
/// refresh the ones already there. Counts only ever rise — a smaller history (purged) leaves
/// the reported numbers as they were. Returns whether anything changed.
pub fn update(gpa: std.mem.Allocator, history: []const book.Entry, bugs: *std.ArrayList(Bug), now: []const u8) !bool {
    var changed = false;
    for (history) |e| {
        if (!counts(e.severity) or e.count < threshold) continue;
        const existing = for (bugs.items) |*b| {
            if (std.mem.eql(u8, b.rule, e.rule) and std.mem.eql(u8, b.pattern, e.pattern)) break b;
        } else null;
        if (existing) |b| {
            if (e.count <= b.occurrences and std.mem.eql(u8, e.last_ts, b.last_ts)) continue;
            b.occurrences = @max(b.occurrences, e.count);
            b.last_ts = e.last_ts;
            b.example_file = e.file;
            b.example_line = e.line;
            b.example_message = e.message;
            b.example_snippet = e.snippet;
        } else {
            try bugs.append(gpa, .{
                .rule = e.rule,
                .pattern = e.pattern,
                .occurrences = e.count,
                .first_ts = e.first_ts,
                .last_ts = e.last_ts,
                .reported_ts = now,
                .example_file = e.file,
                .example_line = e.line,
                .example_message = e.message,
                .example_snippet = e.snippet,
            });
        }
        changed = true;
    }
    return changed;
}

/// `bugs.md`: most-repeated first.
pub fn render(w: *std.Io.Writer, bugs: []const Bug) !void {
    const sorted = bugs;
    try w.print(
        "# zcanon bug report\n\n" ++
            "Mistakes made {d} or more times, from the book. Entries are never removed; " ++
            "each is a candidate for a new zsnag rule or a line in the skill.\n\n",
        .{threshold},
    );
    if (sorted.len == 0) return w.writeAll("Nothing has repeated that often yet.\n");
    var order: [256]usize = undefined;
    const n = @min(sorted.len, order.len);
    for (0..n) |i| order[i] = i;
    std.mem.sort(usize, order[0..n], sorted, struct {
        fn gt(bs: []const Bug, x: usize, y: usize) bool {
            return bs[x].occurrences > bs[y].occurrences;
        }
    }.gt);
    for (order[0..n]) |i| {
        const b = sorted[i];
        try w.print("## [{s}] {s}\n\n", .{ b.rule, b.pattern });
        try w.print("- made {d} times; first {s}, last {s}; reported {s}\n", .{
            b.occurrences, b.first_ts, b.last_ts, b.reported_ts,
        });
        try w.print("- latest: [{s}:{d}]({s}#L{d}) — {s}\n", .{ b.example_file, b.example_line, b.example_file, b.example_line, b.example_message });
        if (b.example_snippet.len > 0) try w.print("\n  ```zig\n  {s}\n  ```\n", .{b.example_snippet});
        try w.writeByte('\n');
    }
    if (sorted.len > n) try w.print("({d} more in bugs.tsv)\n", .{sorted.len - n});
}
