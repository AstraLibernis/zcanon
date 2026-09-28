// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Two files:
//!
//!   - the BOOK (`book.tsv`, `History`): one line per mistake — rule plus message pattern —
//!     with how many times it was made, first and last date, and where it last happened
//!     (`path:line` and the source line). A line is only ever bumped, never removed.
//!   - the OPEN set (`open.tsv`, `Book`): the findings in the code right now, one row per
//!     finding. Each save re-scans the whole file, so anything no longer present has been
//!     fixed and is pruned. It exists to tell a NEW occurrence (count +1) from the same
//!     unfixed finding seen again on the next save (no count).
//!
//! Backing store is one TSV, not sqlite: `lib.nu` shelled out to `sqlite3`, which is not
//! installed here and never was, so every write silently vanished. TSV is the format the
//! companion zephem map already uses at 10 MB+ scale, needs no external binary, and removes
//! the hand-rolled SQL quoting that was the layer's main injection hazard.
const std = @import("std");
const snag = @import("snag.zig");

/// Dedup key is (file, rule, message, snippet) — line/col are deliberately excluded so a
/// finding survives edits that shift it up or down the file.
pub const Record = struct {
    first_ts: []const u8,
    last_ts: []const u8,
    hits: u64,
    zig_version: []const u8,
    file: []const u8,
    rule: []const u8,
    severity: []const u8,
    line: u32,
    col: u32,
    message: []const u8,
    snippet: []const u8,
    /// Only in books written by one interim build; read so they can be migrated, never written.
    fixed_ts: []const u8 = "",

    pub fn sameFinding(a: Record, b: Record) bool {
        return std.mem.eql(u8, a.file, b.file) and
            std.mem.eql(u8, a.rule, b.rule) and
            std.mem.eql(u8, a.message, b.message) and
            std.mem.eql(u8, a.snippet, b.snippet);
    }
};

pub const AST_RULE = "ast-check";
/// The background compiler's errors (`zig build check`).
pub const COMPILE_RULE = "compile";

/// Rule-group names, matching `snag.Group` plus the compiler's own check. Kept as strings
/// because the book is a text file read by both the hook and a human.
pub const GROUP_AST = "ast";
pub const GROUP_CORE = "core";
pub const GROUP_STRUCTURAL = "structural";
pub const GROUP_MAP = "map";
pub const GROUP_COMPILE = "compile";

/// Which group a recorded rule belongs to, read from zsnag's rule registry rather than
/// inferred from the number: numbering by range broke the day a core rule (R014) was added
/// after the map rules. An unknown code (a rule since removed) counts as core.
pub fn groupOf(rule: []const u8) []const u8 {
    if (std.mem.eql(u8, rule, AST_RULE)) return GROUP_AST;
    if (std.mem.eql(u8, rule, COMPILE_RULE)) return GROUP_COMPILE;
    for (snag.rules) |r| {
        if (std.mem.eql(u8, r.code, rule)) return r.group.name();
    }
    return GROUP_CORE;
}

fn isActive(group: []const u8, active: []const []const u8) bool {
    for (active) |g| if (std.mem.eql(u8, g, group)) return true;
    return false;
}

pub const header = "first_ts\tlast_ts\thits\tzig_version\tfile\trule\tseverity\tline\tcol\tmessage\tsnippet";
const n_cols = 11;

/// TSV fields must not carry the delimiters. Snippets are raw source lines, so embedded
/// tabs are normal — escape rather than mangle, and keep it reversible.
pub fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
}

pub fn unescape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(gpa, s[i]);
            continue;
        }
        i += 1;
        try out.append(gpa, switch (s[i]) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            '\\' => '\\',
            // Not an escape we emit; keep both bytes so the round-trip stays lossless.
            else => blk: {
                try out.append(gpa, '\\');
                break :blk s[i];
            },
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Wall-clock seconds since the unix epoch. `std.time.timestamp()` was removed in 0.16 —
/// the real-time clock now comes through the Io layer.
pub fn nowSeconds(io: std.Io) i64 {
    const ns = std.Io.Clock.real.now(io).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s)); // zsnag:ok — seconds always fit i64
}

/// `datetime('now')` in sqlite's default format, which the old book used: UTC,
/// "YYYY-MM-DD HH:MM:SS". Kept identical so an operator reading both formats sees one thing.
pub fn stamp(buf: *[20]u8, epoch_secs: i64) ![]const u8 {
    // A negative stamp is a real runtime input (bad clock), not a broken invariant — so it
    // returns an error rather than tripping an assert.
    if (epoch_secs < 0) return error.NegativeTimestamp;
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(epoch_secs) }; // zsnag:ok — guarded above
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

pub const Book = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    recs: std.ArrayList(Record),

    pub fn init(gpa: std.mem.Allocator) Book {
        return .{ .gpa = gpa, .arena = .init(gpa), .recs = .empty };
    }

    pub fn deinit(b: *Book) void {
        b.recs.deinit(b.gpa);
        b.arena.deinit();
    }

    /// Parse a book from TSV text. Malformed lines are skipped rather than aborting — a
    /// corrupt row must not cost the operator the rest of their history.
    pub fn parse(b: *Book, text: []const u8) !void {
        const a = b.arena.allocator();
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (first) {
                first = false;
                if (std.mem.startsWith(u8, line, "first_ts\t")) continue;
            }
            var f: [n_cols + 1][]const u8 = undefined;
            var it = std.mem.splitScalar(u8, line, '\t');
            var n: usize = 0;
            while (it.next()) |field| : (n += 1) {
                if (n > n_cols) break;
                f[n] = field;
            }
            if (n != n_cols and n != n_cols + 1) continue;

            try b.recs.append(b.gpa, .{
                .first_ts = try unescape(a, f[0]),
                .last_ts = try unescape(a, f[1]),
                .hits = std.fmt.parseInt(u64, f[2], 10) catch continue,
                .zig_version = try unescape(a, f[3]),
                .file = try unescape(a, f[4]),
                .rule = try unescape(a, f[5]),
                .severity = try unescape(a, f[6]),
                .line = std.fmt.parseInt(u32, f[7], 10) catch continue,
                .col = std.fmt.parseInt(u32, f[8], 10) catch continue,
                .message = try unescape(a, f[9]),
                .snippet = try unescape(a, f[10]),
                .fixed_ts = if (n == n_cols + 1) try unescape(a, f[11]) else "",
            });
        }
    }

    pub fn write(b: *const Book, w: *std.Io.Writer) !void {
        try w.writeAll(header);
        try w.writeByte('\n');
        for (b.recs.items) |r| {
            try escape(w, r.first_ts);
            try w.writeByte('\t');
            try escape(w, r.last_ts);
            try w.print("\t{d}\t", .{r.hits});
            try escape(w, r.zig_version);
            try w.writeByte('\t');
            try escape(w, r.file);
            try w.writeByte('\t');
            try escape(w, r.rule);
            try w.writeByte('\t');
            try escape(w, r.severity);
            try w.print("\t{d}\t{d}\t", .{ r.line, r.col });
            try escape(w, r.message);
            try w.writeByte('\t');
            try escape(w, r.snippet);
            try w.writeByte('\n');
        }
    }

    /// Insert-or-bump, matching the old `ON CONFLICT DO UPDATE`: hits += 1, last_ts moves,
    /// and line/col/severity/zig_version take the fresh values.
    pub fn upsert(b: *Book, fresh: []const Record) !void {
        return b.upsertTracking(fresh, null);
    }

    /// `upsert`, also collecting the findings that were NOT already open: new occurrences.
    pub fn upsertTracking(b: *Book, fresh: []const Record, new: ?*std.ArrayList(Record)) !void {
        const a = b.arena.allocator();
        for (fresh) |nr| {
            const existing = for (b.recs.items) |*old| {
                if (Record.sameFinding(old.*, nr)) break old;
            } else null;

            if (existing) |old| {
                old.hits += 1;
                old.last_ts = try a.dupe(u8, nr.last_ts);
                old.line = nr.line;
                old.col = nr.col;
                old.severity = try a.dupe(u8, nr.severity);
                old.zig_version = try a.dupe(u8, nr.zig_version);
            } else {
                if (new) |list| try list.append(b.gpa, nr);
                try b.recs.append(b.gpa, .{
                    .first_ts = try a.dupe(u8, nr.first_ts),
                    .last_ts = try a.dupe(u8, nr.last_ts),
                    .hits = 1,
                    .zig_version = try a.dupe(u8, nr.zig_version),
                    .file = try a.dupe(u8, nr.file),
                    .rule = try a.dupe(u8, nr.rule),
                    .severity = try a.dupe(u8, nr.severity),
                    .line = nr.line,
                    .col = nr.col,
                    .message = try a.dupe(u8, nr.message),
                    .snippet = try a.dupe(u8, nr.snippet),
                });
            }
        }
    }

    /// Drop rows for `file` that the current scan did NOT reproduce — they are fixed.
    ///
    /// Scoped by which rule GROUPS actually ran. Booleans for "zsnag ran" and "ast ran" were
    /// not enough: zsnag exits 0 even when the zephem map failed to load, so the map-backed
    /// rules produced nothing while the hook believed they had run — and their entire history
    /// for the file was deleted as "resolved". A group absent from `active` is never pruned.
    pub fn pruneFile(b: *Book, file: []const u8, fresh: []const Record, active: []const []const u8) void {
        b.prune(.{ .file = file }, fresh, active);
    }

    /// Which rows a scan speaks for: one file (zsnag, ast-check), or every file under a
    /// project root (the compiler checks the whole project at once).
    pub const Scope = union(enum) {
        file: []const u8,
        under: []const u8,

        fn covers(sc: Scope, file: []const u8) bool {
            return switch (sc) {
                .file => |f| std.mem.eql(u8, file, f),
                .under => |root| std.mem.startsWith(u8, file, root) and file.len > root.len and file[root.len] == '/',
            };
        }
    };

    /// `pruneFile` for any scope.
    pub fn prune(b: *Book, scope: Scope, fresh: []const Record, active: []const []const u8) void {
        var i: usize = 0;
        while (i < b.recs.items.len) {
            const r = b.recs.items[i];
            const in_scope = scope.covers(r.file) and isActive(groupOf(r.rule), active);
            if (!in_scope) {
                i += 1;
                continue;
            }
            const still_present = for (fresh) |nr| {
                if (Record.sameFinding(r, nr)) break true;
            } else false;
            if (still_present) {
                i += 1;
            } else {
                _ = b.recs.orderedRemove(i);
            }
        }
    }
};

// ---- the history ---------------------------------------------------------------------------

/// The mistake a message describes, with the specifics abstracted away, so the same error on
/// different names is one line: for the compiler's own diagnostics each 'quoted' name becomes
/// '…' ("expected type '…', found '…'"). zsnag's messages are kept whole — R011's backticked
/// API name IS the mistake.
pub fn pattern(gpa: std.mem.Allocator, rule: []const u8, message: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, rule, AST_RULE) and !std.mem.eql(u8, rule, COMPILE_RULE)) return message;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < message.len) : (i += 1) {
        if (message[i] == '\'') {
            if (std.mem.findScalarPos(u8, message, i + 1, '\'')) |close| {
                try out.appendSlice(gpa, "'…'");
                i = close;
                continue;
            }
        }
        try out.append(gpa, message[i]);
    }
    return out.items;
}

/// One mistake and its record.
pub const Entry = struct {
    rule: []const u8,
    severity: []const u8,
    pattern: []const u8,
    count: u64,
    first_ts: []const u8,
    last_ts: []const u8,
    /// Where it last happened: `file:line`, the message as reported, and the source line.
    file: []const u8,
    line: u32,
    message: []const u8,
    snippet: []const u8,
};

pub const history_header = "rule\tseverity\tcount\tfirst_ts\tlast_ts\tfile\tline\tpattern\tmessage\tsnippet";
const history_cols = 10;

/// True for a book written before the history existed: the per-finding format, which is now
/// the open set.
pub fn isOpenFormat(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "first_ts\t");
}

pub const History = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry),

    pub fn init(gpa: std.mem.Allocator) History {
        return .{ .gpa = gpa, .arena = .init(gpa), .entries = .empty };
    }

    pub fn deinit(h: *History) void {
        h.entries.deinit(h.gpa);
        h.arena.deinit();
    }

    pub fn parse(h: *History, text: []const u8) !void {
        const a = h.arena.allocator();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or std.mem.startsWith(u8, line, "rule\t")) continue;
            var f: [history_cols][]const u8 = undefined;
            var it = std.mem.splitScalar(u8, line, '\t');
            var n: usize = 0;
            while (it.next()) |field| : (n += 1) {
                if (n >= history_cols) break;
                f[n] = field;
            }
            if (n != history_cols) continue;
            try h.entries.append(h.gpa, .{
                .rule = try unescape(a, f[0]),
                .severity = try unescape(a, f[1]),
                .count = std.fmt.parseInt(u64, f[2], 10) catch continue,
                .first_ts = try unescape(a, f[3]),
                .last_ts = try unescape(a, f[4]),
                .file = try unescape(a, f[5]),
                .line = std.fmt.parseInt(u32, f[6], 10) catch 0,
                .pattern = try unescape(a, f[7]),
                .message = try unescape(a, f[8]),
                .snippet = try unescape(a, f[9]),
            });
        }
    }

    pub fn write(h: *const History, w: *std.Io.Writer) !void {
        try w.writeAll(history_header);
        try w.writeByte('\n');
        for (h.entries.items) |e| {
            try escape(w, e.rule);
            try w.writeByte('\t');
            try escape(w, e.severity);
            try w.print("\t{d}\t", .{e.count});
            try escape(w, e.first_ts);
            try w.writeByte('\t');
            try escape(w, e.last_ts);
            try w.writeByte('\t');
            try escape(w, e.file);
            try w.print("\t{d}\t", .{e.line});
            try escape(w, e.pattern);
            try w.writeByte('\t');
            try escape(w, e.message);
            try w.writeByte('\t');
            try escape(w, e.snippet);
            try w.writeByte('\n');
        }
    }

    /// One more occurrence of `r`'s mistake at `when`: count +1, the date and location move.
    pub fn bump(h: *History, r: Record, when: []const u8) !void {
        const a = h.arena.allocator();
        const pat = try pattern(a, r.rule, r.message);
        for (h.entries.items) |*e| {
            if (!std.mem.eql(u8, e.rule, r.rule) or !std.mem.eql(u8, e.pattern, pat)) continue;
            e.count += 1;
            if (std.mem.order(u8, when, e.last_ts) != .lt) {
                e.last_ts = try a.dupe(u8, when);
                e.severity = try a.dupe(u8, r.severity);
                e.file = try a.dupe(u8, r.file);
                e.line = r.line;
                e.message = try a.dupe(u8, r.message);
                e.snippet = try a.dupe(u8, r.snippet);
            }
            if (std.mem.order(u8, when, e.first_ts) == .lt) e.first_ts = try a.dupe(u8, when);
            return;
        }
        try h.entries.append(h.gpa, .{
            .rule = try a.dupe(u8, r.rule),
            .severity = try a.dupe(u8, r.severity),
            .pattern = try a.dupe(u8, pat),
            .count = 1,
            .first_ts = try a.dupe(u8, when),
            .last_ts = try a.dupe(u8, when),
            .file = try a.dupe(u8, r.file),
            .line = r.line,
            .message = try a.dupe(u8, r.message),
            .snippet = try a.dupe(u8, r.snippet),
        });
    }
};
