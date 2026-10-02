// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Test aggregator. Tests live out-of-line here, one `<mod>_test.zig` per module, so the
//! modules themselves stay lean. `zig build test` compiles this root.
test {
    _ = @import("tier_test.zig");
    _ = @import("book_test.zig");
    _ = @import("settings_test.zig");
    _ = @import("hook_test.zig");
    _ = @import("report_test.zig");
    _ = @import("snag_test.zig");
    _ = @import("zephem_test.zig");
    _ = @import("oracle_arity_test.zig");
    _ = @import("semantic_test.zig");
    _ = @import("publish_test.zig");
    _ = @import("advice_test.zig");
}
