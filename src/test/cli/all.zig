//! End-to-end CLI tests. These spawn the REAL `zcanon` and `zsnag` binaries, so they need the
//! build to have installed them — `zig build test-cli` wires that dependency and passes the
//! install prefix via `$ZCANON_TEST_BIN`.
test {
    _ = @import("cli_test.zig");
}
