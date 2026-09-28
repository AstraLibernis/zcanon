// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Read-only views over the book — the port of `nu/zbook.nu`. Four modes: a table of
//! contents by rule, the most recent findings, a per-file roll-up, and the detail for one
//! rule. Nushell's `table` gave column alignment for free; here it is explicit.
const std = @import("std");
const book = @import("book.zig");
const tier = @import("tier.zig");

pub const Mode = union(enum) {
    toc,
    recent: usize,
    files,
    rule: []const u8,

    pub fn parse(args: []const []const u8) !Mode {
        if (args.len == 0) return .toc;
        const head = args[0];
        if (std.mem.eql(u8, head, "recent")) {
            if (args.len < 2) return .{ .recent = 20 };
            return .{ .recent = std.fmt.parseInt(usize, args[1], 10) catch 20 };
        }
        if (std.mem.eql(u8, head, "files")) return .files;
        if (head.len > 1 and head[0] == 'R') return .{ .rule = head };
        return error.UnknownReport;
    }
};

fn pad(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    if (s.len < width) try w.splatByteAll(' ', width - s.len);
}

/// Widest value in `col` across the records, floored at the header width.
fn widthOf(recs: []const book.Record, comptime col: []const u8, min: usize) usize {
    var w = min;
    for (recs) |r| {
        const v = @field(r, col);
        if (v.len > w) w = v.len;
    }
    return w;
}

const Agg = struct {
    key: []const u8,
    severity: []const u8,
    findings: usize,
    hits: u64,
    last_ts: []const u8,
};

fn bumpAgg(list: *std.ArrayList(Agg), gpa: std.mem.Allocator, key: []const u8, r: book.Record) !void {
    for (list.items) |*a| {
        if (!std.mem.eql(u8, a.key, key)) continue;
        a.findings += 1;
        a.hits += r.hits;
        if (std.mem.order(u8, r.last_ts, a.last_ts) == .gt) a.last_ts = r.last_ts;
        return;
    }
    try list.append(gpa, .{
        .key = key,
        .severity = r.severity,
        .findings = 1,
        .hits = r.hits,
        .last_ts = r.last_ts,
    });
}

fn byHitsDesc(_: void, a: Agg, b: Agg) bool {
    if (a.hits != b.hits) return a.hits > b.hits;
    return std.mem.order(u8, a.key, b.key) == .lt;
}

pub fn render(gpa: std.mem.Allocator, w: *std.Io.Writer, recs: []const book.Record, mode: Mode) !void {
    if (recs.len == 0) {
        try w.writeAll("the book is empty — no findings recorded yet.\n");
        return;
    }
    switch (mode) {
        .toc => try renderToc(gpa, w, recs),
        .files => try renderFiles(gpa, w, recs),
        .recent => |n| try renderRecent(gpa, w, recs, n),
        .rule => |code| try renderRule(w, recs, code),
    }
}

fn renderToc(gpa: std.mem.Allocator, w: *std.Io.Writer, recs: []const book.Record) !void {
    var aggs: std.ArrayList(Agg) = .empty;
    defer aggs.deinit(gpa);
    for (recs) |r| try bumpAgg(&aggs, gpa, r.rule, r);
    std.mem.sort(Agg, aggs.items, {}, byHitsDesc);

    try w.print("# the book — {d} findings across {d} rules, most-hit first\n\n", .{ recs.len, aggs.items.len });
    try pad(w, "rule", 12);
    try pad(w, "severity", 10);
    try pad(w, "findings", 10);
    try pad(w, "hits", 8);
    try w.writeAll("last seen\n");
    for (aggs.items) |a| {
        try pad(w, a.key, 12);
        try pad(w, a.severity, 10);
        var buf: [24]u8 = undefined;
        try pad(w, try std.fmt.bufPrint(&buf, "{d}", .{a.findings}), 10);
        try pad(w, try std.fmt.bufPrint(&buf, "{d}", .{a.hits}), 8);
        try w.print("{s}\n", .{a.last_ts});
    }
}

fn renderFiles(gpa: std.mem.Allocator, w: *std.Io.Writer, recs: []const book.Record) !void {
    var aggs: std.ArrayList(Agg) = .empty;
    defer aggs.deinit(gpa);
    for (recs) |r| try bumpAgg(&aggs, gpa, r.file, r);
    std.mem.sort(Agg, aggs.items, {}, byHitsDesc);

    var width: usize = 4;
    for (aggs.items) |a| if (a.key.len > width) {
        width = a.key.len;
    };

    try w.print("# the book by file — {d} files\n\n", .{aggs.items.len});
    try pad(w, "file", width + 2);
    try pad(w, "findings", 10);
    try w.writeAll("hits\n");
    for (aggs.items) |a| {
        try pad(w, a.key, width + 2);
        var buf: [24]u8 = undefined;
        try pad(w, try std.fmt.bufPrint(&buf, "{d}", .{a.findings}), 10);
        try w.print("{d}\n", .{a.hits});
    }
}

fn renderRecent(gpa: std.mem.Allocator, w: *std.Io.Writer, recs: []const book.Record, limit: usize) !void {
    const sorted = try gpa.dupe(book.Record, recs);
    defer gpa.free(sorted);
    std.mem.sort(book.Record, sorted, {}, struct {
        fn lt(_: void, a: book.Record, b: book.Record) bool {
            return std.mem.order(u8, a.last_ts, b.last_ts) == .gt;
        }
    }.lt);

    const n = @min(limit, sorted.len);
    try w.print("# {d} most recent findings\n\n", .{n});
    const fw = widthOf(sorted[0..n], "file", 4);
    for (sorted[0..n]) |r| {
        try w.print("{s}  ", .{r.last_ts});
        try pad(w, r.rule, 12);
        try pad(w, r.file, fw + 2);
        try w.print("{d}:{d}  {s}\n", .{ r.line, r.col, r.message });
    }
}

fn renderRule(w: *std.Io.Writer, recs: []const book.Record, code: []const u8) !void {
    var n: usize = 0;
    for (recs) |r| if (std.mem.eql(u8, r.rule, code)) {
        n += 1;
    };
    if (n == 0) {
        try w.print("no findings recorded for {s}.\n", .{code});
        return;
    }
    try w.print("# {s} — {d} findings\n\n", .{ code, n });
    for (recs) |r| {
        if (!std.mem.eql(u8, r.rule, code)) continue;
        const t = tier.classify(r.severity, r.file);
        try w.print("{s}:{d}:{d}  ({s}, {d} hits)\n    {s}\n    {s}\n", .{
            r.file, r.line, r.col, t.key(), r.hits, r.message, r.snippet,
        });
    }
}
