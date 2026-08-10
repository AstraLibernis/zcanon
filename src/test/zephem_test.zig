const std = @import("std");
const testing = std.testing;
const zephem = @import("zcanon").zephem;

// ---- arity, the part that got it wrong first ------------------------------

test "arity counts parameters, not commas" {
    try testing.expectEqual(@as(?usize, 0), zephem.arityOf("fn cwd() Dir"));
    try testing.expectEqual(@as(?usize, 1), zephem.arityOf("fn ArrayList(comptime T: type) type"));
    try testing.expectEqual(
        @as(?usize, 3),
        zephem.arityOf("fn parseInt(comptime T: type, buf: []const u8, base: u8) ParseIntError!T"),
    );
}

test "a trailing comma in a wrapped signature is not an extra parameter" {
    // std wraps long signatures and leaves a trailing comma — four params, four commas.
    const sig =
        "fn parseFromSliceLeaky( comptime T: type, allocator: Allocator, s: []const u8, " ++
        "options: ParseOptions, ) ParseError(Scanner)!T";
    try testing.expectEqual(@as(?usize, 4), zephem.arityOf(sig));
}

test "arity ignores commas nested inside parameter types" {
    // The fn-typed parameter carries its own commas at depth > 1.
    const sig =
        "fn sort( comptime T: type, items: []T, context: anytype, " ++
        "comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool, ) void";
    try testing.expectEqual(@as(?usize, 4), zephem.arityOf(sig));

    const sig2 = "fn directEnumArray( comptime E: type, comptime Data: type, " ++
        "comptime max_unused_slots: comptime_int, init_values: EnumFieldStruct(E, Data, null), ) [x]Data";
    try testing.expectEqual(@as(?usize, 4), zephem.arityOf(sig2));
}

test "arity is null for a non-signature or an unbalanced one" {
    try testing.expectEqual(@as(?usize, null), zephem.arityOf(""));
    try testing.expectEqual(@as(?usize, null), zephem.arityOf("const x = 1"));
    try testing.expectEqual(@as(?usize, null), zephem.arityOf("fn broken(a: T"));
}

// ---- deprecation ----------------------------------------------------------

test "deprecation is recognised across std's phrasings" {
    try testing.expect(zephem.isDeprecated("Deprecated; use `array_list.Aligned`."));
    try testing.expect(zephem.isDeprecated("Deprecated, use `addFilePath`."));
    try testing.expect(zephem.isDeprecated("Deprecated in favor of `find`."));
    try testing.expect(zephem.isDeprecated("deprecated, see `getPath3`."));
    try testing.expect(!zephem.isDeprecated("Returns the index of the first match."));
    try testing.expect(!zephem.isDeprecated(""));
}

test "the replacement name is extracted from the doc" {
    try testing.expectEqualStrings("array_list.Aligned", zephem.deprecationOf("Deprecated; use `array_list.Aligned`.").?);
    try testing.expectEqualStrings("addFilePath", zephem.deprecationOf("Deprecated, use `addFilePath`.").?);
    try testing.expectEqualStrings("find", zephem.deprecationOf("Deprecated in favor of `find`.").?);
    try testing.expectEqualStrings("getPath3", zephem.deprecationOf("Deprecated, see `getPath3`.").?);
}

test "a deprecation with no backticked target yields null, not a bogus name" {
    try testing.expectEqual(@as(?[]const u8, null), zephem.deprecationOf("Deprecated. Do not use."));
    try testing.expectEqual(@as(?[]const u8, null), zephem.deprecationOf("Deprecated ``"));
    // Not deprecated at all, even though it has backticks.
    try testing.expectEqual(@as(?[]const u8, null), zephem.deprecationOf("See `other` for details."));
}

// ---- the map ---------------------------------------------------------------
//
// Parsing is tested against a synthetic table so it does not depend on the ambient
// environment. The real 8.8 MB table is exercised end-to-end by `zsnag` itself.

/// A synthetic lookup table in zephem's 16-column layout:
/// path depth kind name n_children detail sig doc rkind rdetail canon ftype fval delegate vis mod
const synthetic_tsv =
    "path\tdepth\tkind\tname\tn_children\tdetail\tsig\tdoc\trkind\trdetail\tcanon\tftype\tfval\tdelegate\tvis\tmod\n" ++
    "std.fmt.parseInt\t2\tfn\tparseInt\t0\t\tfn parseInt(comptime T: type, buf: []const u8, base: u8) E!T\t\t\t\t\t\t\t\tpub\t\n" ++
    "std.mem.indexOf\t2\tfn\tindexOf\t0\t\tfn indexOf(comptime T: type, h: []const T, n: []const T) ?usize\tDeprecated in favor of `find`.\t\t\t\t\t\t\tpub\t\n" ++
    "std.hidden.thing\t2\tfn\tthing\t0\t\tfn thing() void\t\t\t\t\t\t\t\tpriv\t\n" ++
    "malformed\trow\twith\tfew\tcolumns\n";

fn synthetic(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8, synthetic_tsv);
}

test "parsing indexes by path and skips the header and malformed rows" {
    var m = try zephem.parse(testing.allocator, try synthetic(testing.allocator));
    defer m.deinit();

    try testing.expectEqual(@as(usize, 3), m.count());
    try testing.expect(m.get("path") == null); // header not indexed
    try testing.expect(m.get("malformed") == null); // short row dropped
}

test "entry fields land in the right columns" {
    var m = try zephem.parse(testing.allocator, try synthetic(testing.allocator));
    defer m.deinit();

    const e = m.get("std.fmt.parseInt").?;
    try testing.expectEqualStrings("fn", e.kind);
    try testing.expectEqualStrings("fn parseInt(comptime T: type, buf: []const u8, base: u8) E!T", e.sig);
    try testing.expectEqual(@as(?usize, 3), zephem.arityOf(e.sig).?);
    try testing.expect(e.isPublic());
}

test "a private decl is flagged as not callable at that path" {
    var m = try zephem.parse(testing.allocator, try synthetic(testing.allocator));
    defer m.deinit();
    try testing.expect(!m.get("std.hidden.thing").?.isPublic());
}

test "a deprecated entry carries its replacement through to the reader" {
    var m = try zephem.parse(testing.allocator, try synthetic(testing.allocator));
    defer m.deinit();
    const e = m.get("std.mem.indexOf").?;
    try testing.expect(zephem.isDeprecated(e.doc));
    try testing.expectEqualStrings("find", zephem.deprecationOf(e.doc).?);
}

test "an absent path resolves to null — the basis for R013" {
    var m = try zephem.parse(testing.allocator, try synthetic(testing.allocator));
    defer m.deinit();
    try testing.expect(m.get("std.mem.copy") == null);
    try testing.expect(m.get("std.mem.copyForwards2") == null);
}
