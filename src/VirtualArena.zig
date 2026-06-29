const std = @import("std");
const casts = @import("casts.zig");

const posix = std.posix;
const mem = std.mem;
const assert = std.debug.assert;
const reinterpretCast = casts.reinterpretCast;

const VirtualArena = @This();

base_ptr: [*]u8,
offset: usize,
capacity: usize,

pub fn init(capacity: usize) !VirtualArena {
    const ptr = try posix.mmap(
        null,
        capacity,
        .{ .READ = true, .WRITE = true },
        posix.MAP{.TYPE = .PRIVATE, .ANONYMOUS = true},
        -1,
        0,
    );

    return .{
        .base_ptr = ptr.ptr,
        .offset = 0,
        .capacity = capacity,
    };
}

pub fn deinit(self: *VirtualArena) void {
    posix.munmap(@as([*]align(std.heap.pageSize()) u8, @alignCast(self.base_ptr))[0..self.capacity]);
    self.* = undefined;
}

pub fn reset(self: *VirtualArena) void {
    self.offset = 0;
}

pub fn getPos(self: VirtualArena) usize {
    return self.offset;
}

pub fn restore(self: *VirtualArena, pos: usize) void {
    assert(pos <= self.capacity);
    self.offset = pos;
}

pub fn queryCapacity(self: VirtualArena) usize {
    return self.capacity;
}

pub fn queryUsed(self: VirtualArena) usize {
    return self.offset;
}

pub fn ownsSlice(self: *const VirtualArena, slice: []const u8) bool {
    if (slice.len == 0) return self.capacity == 0;
    const base = @intFromPtr(self.base_ptr);
    const region_end = base + self.capacity;
    const start = @intFromPtr(slice.ptr);
    const last = @intFromPtr(slice.ptr + slice.len - 1);
    return base <= start and last < region_end;
}

pub fn isLastAllocation(self: *const VirtualArena, buf: []const u8) bool {
    return buf.ptr + buf.len == self.base_ptr + self.offset;
}

pub fn allocator(self: *VirtualArena) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        }
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self = reinterpretCast(*VirtualArena, ctx);

    const adjust_off = mem.alignPointerOffset(self.base_ptr + self.offset, alignment.toByteUnits()) orelse
        return null;
    const aligned_offset = self.offset + adjust_off;

    if (aligned_offset + len > self.capacity) {
        return null;
    }

    const result_ptr = self.base_ptr + aligned_offset;
    self.offset = aligned_offset + len;

    return result_ptr;
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = alignment;
    _ = ret_addr;
    const self = reinterpretCast(*VirtualArena, ctx);
    assert(@inComptime() or self.ownsSlice(buf));

    if (!self.isLastAllocation(buf)) {
        if (new_len > buf.len) return false;
        return true;
    }

    // Shrink: reclaim space from the last allocation
    if (new_len <= buf.len) {
        self.offset -= buf.len - new_len;
        return true;
    }

    // Grow the last allocation
    const additional_len = new_len - buf.len;
    if (self.offset + additional_len > self.capacity) {
        return false;
    }
    self.offset += additional_len;
    return true;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, buf, alignment, new_len, ret_addr)) buf.ptr else null;
}

/// Free reclaims space only for the most-recent (LIFO) allocation.
fn free(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const self = reinterpretCast(*VirtualArena, ctx);
    assert(@inComptime() or self.ownsSlice(buf));

    if (self.isLastAllocation(buf)) {
        self.offset -= buf.len;
    }
}
