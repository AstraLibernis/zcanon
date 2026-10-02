// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Internal re-export surface, so out-of-line tests in src/test/ can reach the modules
//! by name (`@import("zcanon").tier`) instead of by path — a test root under src/test/
//! cannot `@import("../…")` across the module boundary.
pub const tier = @import("tier.zig");
pub const book = @import("book.zig");
pub const vars = @import("vars.zig");
pub const settings = @import("settings.zig");
pub const hook = @import("hook.zig");
pub const report = @import("report.zig");
pub const snag = @import("snag.zig");
pub const zephem = @import("zephem.zig");
pub const setup = @import("setup.zig");
pub const semantic = @import("semantic.zig");
pub const daemon = @import("daemon.zig");
pub const bugs = @import("bugs.zig");
pub const publish = @import("publish.zig");
pub const advice = @import("advice.zig");
