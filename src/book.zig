//! The book — the local log of findings that SURVIVE. Each save re-scans the whole file,
//! so anything no longer present has been fixed and is pruned; `hits` counts real
//! recurrences, not repeated saves of a fix.
//!
//! Backing store is one TSV, not sqlite: `lib.nu` shelled out to `sqlite3`, which is not
//! installed here and never was, so every write silently vanished. TSV is the format the
//! companion zephem map already uses at 10 MB+ scale, needs no external binary, and removes
//! the hand-rolled SQL quoting that was the layer's main injection hazard.
const std = @import("std");

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

    pub fn sameFinding(a: Record, b: Record) bool {
        return std.mem.eql(u8, a.file, b.file) and
            std.mem.eql(u8, a.rule, b.rule) and
            std.mem.eql(u8, a.message, b.message) and
            std.mem.eql(u8, a.snippet, b.snippet);
    }
};

pub const AST_RULE = "ast-check";

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

/// `datetime('now')` in sqlite's default format, which the old book used: UTC,
/// "YYYY-MM-DD HH:MM:SS". Kept identical so an operator reading both formats sees one thing.
/// Wall-clock seconds since the unix epoch. `std.time.timestamp()` was removed in 0.16 —
/// the real-time clock now comes through the Io layer.
pub fn nowSeconds(io: std.Io) i64 {
    const ns = std.Io.Clock.real.now(io).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s)); // zsnag:ok — seconds always fit i64
}

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

// R008 false positive: the `const Book` span runs to the next `;`, which is deep inside the
// struct body, so it captures `ArenaAllocator` + `.init(` and then hunts for a `Book.deinit`
// that will never exist. The arena IS released, by `deinit` below. See the PLAN.md ledger.
pub const Book = struct { // zsnag:ok
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
            var f: [n_cols][]const u8 = undefined;
            var it = std.mem.splitScalar(u8, line, '\t');
            var n: usize = 0;
            while (it.next()) |field| : (n += 1) {
                if (n >= n_cols) break;
                f[n] = field;
            }
            if (n != n_cols) continue;

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
    /// Scoped by which checker actually ran, so a crashed zsnag cannot erase its own history
    /// (and an ast-check that never ran cannot erase ast rows).
    pub fn pruneFile(b: *Book, file: []const u8, fresh: []const Record, ran_zsnag: bool, ran_ast: bool) void {
        var i: usize = 0;
        while (i < b.recs.items.len) {
            const r = b.recs.items[i];
            const is_ast = std.mem.eql(u8, r.rule, AST_RULE);
            const in_scope = std.mem.eql(u8, r.file, file) and
                ((is_ast and ran_ast) or (!is_ast and ran_zsnag));
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
