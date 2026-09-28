// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Finding priority tiers. Findings are never hidden — the tier only LABELS how much
//! to worry, so the noisy advisory rules don't read as alarms. Pure function of
//! (severity, file): error→blocking, warn→caution, else advisory; an advisory finding
//! in throwaway code demotes to `expected`.
const std = @import("std");

pub const Tier = enum(u2) {
    blocking = 0,
    caution = 1,
    advisory = 2,
    expected = 3,

    /// Header shown above the group. Lower rank = more urgent; the enum value IS the rank,
    /// so `std.sort` on it yields display order.
    pub fn head(t: Tier) []const u8 {
        return switch (t) {
            .blocking => "▲ BLOCKING — fix before continuing",
            .caution => "⚠ CORRECTNESS RISK — review, likely a real bug",
            .advisory => "ℹ ADVISORY — usually fine, noted for awareness",
            .expected => "· EXPECTED (bench/test/scratch) — no action needed",
        };
    }

    /// The head's leading symbol, for the short view's one-line rows.
    pub fn mark(t: Tier) []const u8 {
        return switch (t) {
            .blocking => "▲",
            .caution => "⚠",
            .advisory => "ℹ",
            .expected => "·",
        };
    }

    pub fn key(t: Tier) []const u8 {
        return @tagName(t);
    }
};

/// Ported from lib.nu's `(?i)(/tmp/|/scratch|bench|experiment|_test\.zig$|/tests?/)`.
/// Kept as an explicit matcher rather than a regex dependency: the pattern is fixed and
/// this way the alternatives are readable and individually testable.
fn isScratch(file: []const u8) bool {
    const substrings = [_][]const u8{
        "/tmp/", "/scratch", "bench", "experiment", "/test/", "/tests/",
    };
    for (substrings) |needle| {
        if (containsIgnoreCase(file, needle)) return true;
    }
    return endsWithIgnoreCase(file, "_test.zig");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    std.debug.assert(needle.len > 0);
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    std.debug.assert(suffix.len > 0);
    if (suffix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

/// `severity` is zsnag's own spelling: "error" | "warn" | anything else (info).
/// ast-check findings arrive as "error", which is why they land in `blocking`.
pub fn classify(severity: []const u8, file: []const u8) Tier {
    const base: Tier = if (std.mem.eql(u8, severity, "error"))
        .blocking
    else if (std.mem.eql(u8, severity, "warn"))
        .caution
    else
        .advisory;

    if (base == .advisory and isScratch(file)) return .expected;
    return base;
}
