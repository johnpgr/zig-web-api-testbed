//! Temporary sub-lifetime on an existing `VirtualArena` (`ArenaTempBegin` / `ArenaTempEnd`).
//!
//! Save a checkpoint, allocate through `allocator()` (which uses the wrapped
//! arena), then call `end` to bulk-free everything allocated in the scope.
const std = @import("std");
const VirtualArena = @import("virtual-arena.zig");

const Scratch = @This();

arena: *VirtualArena,
pos: usize,

/// Equivalent to `ArenaTempBegin(arena)`.
pub fn begin(arena: *VirtualArena) Scratch {
    return .{
        .arena = arena,
        .pos = arena.getPos(),
    };
}

/// Equivalent to `ArenaTempEnd(temp)`.
pub fn end(self: Scratch) void {
    self.arena.restore(self.pos);
}

pub fn arenaPtr(self: Scratch) *VirtualArena {
    return self.arena;
}

pub fn checkpointPos(self: Scratch) usize {
    return self.pos;
}

/// Allocates on the wrapped arena. Call `end` to rewind past these allocations.
pub fn allocator(self: *Scratch) std.mem.Allocator {
    return self.arena.allocator();
}

const testing = std.testing;

test "Scratch begin/end on arena" {
    var arena = try VirtualArena.init(2 * std.heap.pageSize());
    defer arena.deinit();

    const persistent = try arena.allocator().alloc(u8, 32);

    var temp = Scratch.begin(&arena);
    _ = try temp.allocator().alloc(u8, 64);
    try testing.expect(arena.queryUsed() > persistent.len);

    temp.end();
    try testing.expectEqual(persistent.len, arena.queryUsed());
    try testing.expect(arena.ownsSlice(persistent));
}

test "Scratch allocator usable with defer end" {
    var arena = try VirtualArena.init(2 * std.heap.pageSize());
    defer arena.deinit();

    var temp = Scratch.begin(&arena);
    defer temp.end();

    var slice = try temp.allocator().alloc(u8, 16);
    try testing.expect(temp.allocator().resize(slice, 48));
    slice = slice.ptr[0..48];
    try testing.expectEqual(@as(usize, 48), arena.queryUsed());

    temp.end();
    try testing.expectEqual(@as(usize, 0), arena.queryUsed());
}
