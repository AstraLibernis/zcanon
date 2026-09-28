// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Reading the book. Each line of the history is one mistake: how many times it was made,
//! when first and last, and where it last happened as a clickable `path:line`.
const std = @import("std");
const book = @import("book.zig");

pub const Mode = union(enum) {
    /// Every mistake, most frequent first.
    mistakes,
    /// Totals per rule.
    rules,
    recent: usize,
    /// The findings in the code right now.
    open,
    rule: []const u8,

    pub fn parse(args: []const []const u8) !Mode {
        if (args.len == 0) return .mistakes;
        const head = args[0];
        if (std.mem.eql(u8, head, "rules")) return .rules;
        if (std.mem.eql(u8, head, "open") or std.mem.eql(u8, head, "files")) return .open;
        if (std.mem.eql(u8, head, "recent")) {
            if (args.len < 2) return .{ .recent = 20 };
            return .{ .recent = std.fmt.parseInt(usize, args[1], 10) catch 20 };
        }
        if (head.len > 1 and head[0] == 'R') return .{ .rule = head };
        if (std.mem.eql(u8, head, book.AST_RULE) or std.mem.eql(u8, head, book.COMPILE_RULE)) return .{ .rule = head };
        return error.UnknownReport;
    }
};

pub fn render(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    history: []const book.Entry,
    open: []const book.Record,
    mode: Mode,
) !void {
    switch (mode) {
        .open => return renderOpen(w, open),
        else => {},
    }
    if (history.len == 0) return w.writeAll("the book is empty — no mistakes recorded yet.\n");
    const sorted = try gpa.dupe(book.Entry, history);
    defer gpa.free(sorted);
    switch (mode) {
        .mistakes => {
            std.mem.sort(book.Entry, sorted, {}, byCount);
            try w.print("# the book — {d} distinct mistakes, most frequent first\n\n", .{sorted.len});
            for (sorted) |e| try line(w, e);
        },
        .recent => |n| {
            std.mem.sort(book.Entry, sorted, {}, byRecent);
            const k = @min(n, sorted.len);
            try w.print("# the {d} most recently made mistakes\n\n", .{k});
            for (sorted[0..k]) |e| try line(w, e);
        },
        .rule => |code| {
            std.mem.sort(book.Entry, sorted, {}, byCount);
            var n: usize = 0;
            for (sorted) |e| if (std.mem.eql(u8, e.rule, code)) {
                n += 1;
            };
            if (n == 0) return w.print("no mistakes recorded for {s}.\n", .{code});
            try w.print("# {s} — {d} distinct mistakes\n\n", .{ code, n });
            for (sorted) |e| {
                if (!std.mem.eql(u8, e.rule, code)) continue;
                try line(w, e);
                if (e.snippet.len > 0) try w.print("      {s}\n", .{e.snippet});
            }
        },
        .rules => try renderRules(gpa, w, history),
        .open => unreachable,
    }
}

/// `   12×  2026-09-28 15:42  [R011] /path/file.zig:106  `std.fs.max_path_bytes` is deprecated…`
fn line(w: *std.Io.Writer, e: book.Entry) !void {
    try w.print("{d:>5}×  {s}  [{s}] {s}:{d}  {s}\n", .{ e.count, e.last_ts[0..@min(16, e.last_ts.len)], e.rule, e.file, e.line, e.pattern });
}

fn byCount(_: void, a: book.Entry, b: book.Entry) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.last_ts, b.last_ts) == .gt;
}

fn byRecent(_: void, a: book.Entry, b: book.Entry) bool {
    return std.mem.order(u8, a.last_ts, b.last_ts) == .gt;
}

fn renderRules(gpa: std.mem.Allocator, w: *std.Io.Writer, history: []const book.Entry) !void {
    const Agg = struct { rule: []const u8, mistakes: usize = 0, times: u64 = 0, last_ts: []const u8 = "" };
    var aggs: std.ArrayList(Agg) = .empty;
    defer aggs.deinit(gpa);
    for (history) |e| {
        const a = for (aggs.items) |*x| {
            if (std.mem.eql(u8, x.rule, e.rule)) break x;
        } else blk: {
            try aggs.append(gpa, .{ .rule = e.rule });
            break :blk &aggs.items[aggs.items.len - 1];
        };
        a.mistakes += 1;
        a.times += e.count;
        if (std.mem.order(u8, e.last_ts, a.last_ts) == .gt) a.last_ts = e.last_ts;
    }
    std.mem.sort(Agg, aggs.items, {}, struct {
        fn gt(_: void, x: Agg, y: Agg) bool {
            return x.times > y.times;
        }
    }.gt);
    try w.print("# the book by rule — {d} rules\n\n", .{aggs.items.len});
    try w.writeAll("rule        mistakes  times   last\n");
    for (aggs.items) |a| try w.print("{s:<12}{d:<10}{d:<8}{s}\n", .{ a.rule, a.mistakes, a.times, a.last_ts });
}

fn renderOpen(w: *std.Io.Writer, open: []const book.Record) !void {
    try w.print("# {d} findings in the code right now\n\n", .{open.len});
    for (open) |r| try w.print("[{s}] {s}:{d}:{d}  {s}\n", .{ r.rule, r.file, r.line, r.col, r.message });
}
