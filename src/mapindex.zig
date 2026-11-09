// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! A sorted index of zephem's lookup table, so a hook run reads the few dozen rows it needs
//! instead of scanning all of them. The scan was the main cost of the hook on Windows (every
//! page of the table faulted in on every run).
//!
//! The index lives in zcanon's own config folder (zcanon keeps what it generates there) and
//! is bound to one exact table: its path, size, mtime, and a hash of its first and last
//! 4 KiB. Any mismatch, a truncated or corrupt index (the records carry a checksum), or a
//! table too large for 32-bit offsets, and the caller falls back to the full scan and
//! rewrites the index. The index only says WHERE rows are; every row it points at is
//! re-checked against the asked path, so it can miss nothing silently as long as it is
//! fresh, and a stale one is refused by the key.
//!
//! Row selection matches `zephem.index` exactly: lines split on '\n', empty lines skipped,
//! the first non-empty line skipped when it is the `path\t…` header, and the path is the
//! text before the first tab. Rows with the same path come back in table order, so the
//! caller's "last row wins" is unchanged.
const std = @import("std");

pub const magic = "ZCLKIDX1";
pub const header_len = 64;
pub const rec_len = 16;
const edge = 4096;

pub const HashFn = fn ([]const u8) u64;

pub fn wyhash(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0, s);
}

/// The identity of the table an index was built for.
pub const Key = struct {
    size: u64,
    mtime: i96,
    path_hash: u64,
    edge_hash: u64,

    pub fn of(path: []const u8, mtime: i96, text: []const u8) Key {
        var h = std.hash.Wyhash.init(0);
        h.update(text[0..@min(edge, text.len)]);
        h.update(text[text.len - @min(edge, text.len) ..]);
        return .{ .size = text.len, .mtime = mtime, .path_hash = wyhash(path), .edge_hash = h.final() };
    }
};

const Rec = struct {
    hash: u64,
    off: u32,
    len: u32,

    fn less(_: void, a: Rec, b: Rec) bool {
        return if (a.hash != b.hash) a.hash < b.hash else a.off < b.off;
    }
};

/// The rows `zephem.index` would consider, as (path, line) pairs, in table order.
pub const Rows = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    first: bool = true,

    pub fn init(text: []const u8) Rows {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    pub fn next(r: *Rows) ?[]const u8 {
        while (r.lines.next()) |line| {
            if (line.len == 0) continue;
            if (r.first) {
                r.first = false;
                if (std.mem.startsWith(u8, line, "path\t")) continue;
            }
            return line;
        }
        return null;
    }
};

pub const BuildError = error{TableTooLarge} || std.mem.Allocator.Error;

/// The index bytes for `text`. Caller frees.
pub fn build(gpa: std.mem.Allocator, text: []const u8, key: Key, comptime h: HashFn) BuildError![]u8 {
    if (text.len > std.math.maxInt(u32)) return error.TableTooLarge;
    var recs: std.ArrayList(Rec) = .empty;
    defer recs.deinit(gpa);
    var rows = Rows.init(text);
    while (rows.next()) |line| {
        const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
        const off = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
        // Both fit: text.len <= maxInt(u32) was checked above.
        try recs.append(gpa, .{ .hash = h(line[0..tab]), .off = @intCast(off), .len = @intCast(line.len) });
    }
    std.mem.sortUnstable(Rec, recs.items, {}, Rec.less);

    const out = try gpa.alloc(u8, header_len + recs.items.len * rec_len);
    errdefer gpa.free(out);
    const body = out[header_len..];
    for (recs.items, 0..) |r, i| {
        const b = body[i * rec_len ..][0..rec_len];
        std.mem.writeInt(u64, b[0..8], r.hash, .little);
        std.mem.writeInt(u32, b[8..12], r.off, .little);
        std.mem.writeInt(u32, b[12..16], r.len, .little);
    }
    writeHeader(out[0..header_len], key, recs.items.len, wyhash(body));
    return out;
}

fn writeHeader(hd: *[header_len]u8, key: Key, count: u64, rec_hash: u64) void {
    @memcpy(hd[0..8], magic);
    std.mem.writeInt(u64, hd[8..16], key.size, .little);
    std.mem.writeInt(i128, hd[16..32], key.mtime, .little);
    std.mem.writeInt(u64, hd[32..40], key.path_hash, .little);
    std.mem.writeInt(u64, hd[40..48], key.edge_hash, .little);
    std.mem.writeInt(u64, hd[48..56], count, .little);
    std.mem.writeInt(u64, hd[56..64], rec_hash, .little);
}

pub const Index = struct {
    body: []const u8,
    count: usize,

    fn hashAt(ix: Index, i: usize) u64 {
        return std.mem.readInt(u64, ix.body[i * rec_len ..][0..8], .little);
    }

    /// Rows whose path is exactly `path`, in table order.
    pub fn find(ix: Index, text: []const u8, path: []const u8, comptime h: HashFn) Matches {
        const want = h(path);
        // lower bound on the hash
        var lo: usize = 0;
        var hi: usize = ix.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ix.hashAt(mid) < want) lo = mid + 1 else hi = mid;
        }
        return .{ .ix = ix, .text = text, .path = path, .hash = want, .i = lo };
    }
};

pub const Matches = struct {
    ix: Index,
    text: []const u8,
    path: []const u8,
    hash: u64,
    i: usize,

    pub fn next(m: *Matches) ?[]const u8 {
        while (m.i < m.ix.count and m.ix.hashAt(m.i) == m.hash) {
            const b = m.ix.body[m.i * rec_len ..][0..rec_len];
            m.i += 1;
            const off: usize = std.mem.readInt(u32, b[8..12], .little);
            const len: usize = std.mem.readInt(u32, b[12..16], .little);
            if (off > m.text.len or len > m.text.len - off) continue;
            const row = m.text[off..][0..len];
            // A hash collision, or an index that disagrees with the table: not this path.
            if (row.len <= m.path.len or row[m.path.len] != '\t') continue;
            if (!std.mem.eql(u8, row[0..m.path.len], m.path)) continue;
            return row;
        }
        return null;
    }
};

/// The index in `bytes` if it was built for `key` and is intact; null otherwise.
pub fn open(bytes: []const u8, key: Key) ?Index {
    if (bytes.len < header_len) return null;
    var want: [header_len]u8 = undefined;
    const count = std.mem.readInt(u64, bytes[48..56], .little);
    const body_len = std.math.mul(u64, count, rec_len) catch return null;
    if (bytes.len - header_len != body_len) return null;
    const body = bytes[header_len..];
    writeHeader(&want, key, count, wyhash(body));
    if (!std.mem.eql(u8, bytes[0..header_len], &want)) return null;
    return .{ .body = body, .count = @intCast(count) };
}
