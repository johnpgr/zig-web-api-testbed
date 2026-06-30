//! Just some things that I wish were in the standard library

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const mem = std.mem;
const assert = std.debug.assert;
const windows = std.os.windows;
const ntdll = windows.ntdll;

const native_os = builtin.os.tag;

/// cast() safely transforms a numeric type into another
/// or a pointer into another, effectively an reinterpret_cast<>
pub fn cast(comptime T: type) fn (anytype) callconv(.@"inline") T {
    return struct {
        inline fn castFunc(value: anytype) T {
            const S = @TypeOf(value);
            const t_info = @typeInfo(T);
            const s_info = @typeInfo(S);

            // 1. Destination is a Pointer (or Slice)
            if (t_info == .pointer) {
                if (s_info == .pointer) {
                    return @ptrCast(@alignCast(value));
                } else if (s_info == .int or s_info == .comptime_int) {
                    return @ptrFromInt(value);
                } else {
                    @compileError("Cannot cast from " ++ @typeName(S) ++ " to pointer type " ++ @typeName(T));
                }
            }

            // 2. Destination is an Integer
            if (t_info == .int or t_info == .comptime_int) {
                if (s_info == .int or s_info == .comptime_int) {
                    return @intCast(value);
                } else if (s_info == .float or s_info == .comptime_float) {
                    return @intFromFloat(value);
                } else if (s_info == .pointer) {
                    return @intFromPtr(value);
                } else {
                    @compileError("Cannot cast from " ++ @typeName(S) ++ " to integer type " ++ @typeName(T));
                }
            }

            // 3. Destination is a Float
            if (t_info == .float or t_info == .comptime_float) {
                if (s_info == .int or s_info == .comptime_int) {
                    return @floatFromInt(value);
                } else if (s_info == .float or s_info == .comptime_float) {
                    return @floatCast(value);
                } else {
                    @compileError("Cannot cast from " ++ @typeName(S) ++ " to float type " ++ @typeName(T));
                }
            }

            @compileError("Unsupported destination type for cast: " ++ @typeName(T));
        }
    }.castFunc;
}

/// A fixed-capacity arena backed by one reserved virtual address range.
///
/// `init` reserves the arena's full address range without making the pages
/// accessible. Allocations are served linearly from `base_ptr + offset`; when an
/// allocation crosses the current commit boundary, the arena commits enough
/// pages to cover the new offset.
///
/// Individual frees are no-ops. Memory is reclaimed by `reset`, by rewinding to
/// the checkpoint captured by `mark`, or by releasing the entire arena with
/// `deinit`.
///
/// `mark` stores a single checkpoint in the arena itself. Calling `mark` again
/// replaces the previous checkpoint; this type intentionally does not maintain
/// a stack of nested temporary scopes.
pub const VirtualArena = struct {
    /// Start of the reserved virtual address range owned by this arena.
    base_ptr: [*]u8,

    /// Number of bytes currently consumed from `base_ptr`.
    offset: usize,

    /// Total usable byte capacity requested by the caller.
    capacity: usize,

    /// Page-rounded number of bytes reserved in the virtual address space.
    reserved_size: usize,

    /// Page-rounded number of bytes currently committed and accessible.
    committed: usize,

    /// Checkpoint offset used by `mark` and `restore`.
    pos: usize,

    /// Reserves `capacity` bytes of virtual address space and returns an empty arena.
    ///
    /// The returned arena owns the reserved range and must be released with
    /// `deinit`. No pages are committed until the first allocation.
    pub fn init(capacity: usize) !VirtualArena {
        const reserved_size = try roundUpToPage(capacity);
        const ptr = try reserveMemory(reserved_size);

        return .{
            .base_ptr = ptr,
            .offset = 0,
            .capacity = capacity,
            .reserved_size = reserved_size,
            .committed = 0,
            .pos = 0,
        };
    }

    /// Releases the virtual address range owned by this arena.
    ///
    /// The arena must not be used after this call.
    pub fn deinit(self: *VirtualArena) void {
        // Assert at runtime that the base pointer is aligned to the kernel's official runtime page size
        std.debug.assert(@intFromPtr(self.base_ptr) % std.heap.pageSize() == 0);

        releaseMemory(self.base_ptr, self.reserved_size);
        self.* = undefined;
    }

    /// Drops all allocations by rewinding the arena to the beginning.
    ///
    /// This does not clear memory, decommit pages, or change the stored checkpoint.
    pub fn reset(self: *VirtualArena) void {
        self.offset = 0;
    }

    /// Returns the current allocation offset.
    pub fn getPos(self: VirtualArena) usize {
        return self.offset;
    }

    /// Stores the current allocation offset as the arena's restore point.
    ///
    /// Only one restore point is stored. A later call to `mark` overwrites the
    /// previous restore point.
    pub fn mark(self: *VirtualArena) void {
        self.pos = self.offset;
    }

    /// Rewinds the arena to the offset most recently captured by `mark`.
    ///
    /// Allocations made after the mark are invalid after this call. This does
    /// not decommit pages. Calling `restore` before `mark` rewinds to the
    /// arena's initial checkpoint, zero.
    pub fn restore(self: *VirtualArena) void {
        assert(self.pos <= self.capacity);
        self.offset = self.pos;
    }

    /// Returns the total byte capacity of the arena.
    pub fn queryCapacity(self: VirtualArena) usize {
        return self.capacity;
    }

    /// Returns the page-rounded byte size reserved from the virtual address space.
    pub fn queryReserved(self: VirtualArena) usize {
        return self.reserved_size;
    }

    /// Returns the page-rounded byte size currently committed and accessible.
    pub fn queryCommitted(self: VirtualArena) usize {
        return self.committed;
    }

    /// Returns the number of bytes currently consumed by the arena.
    pub fn queryUsed(self: VirtualArena) usize {
        return self.offset;
    }

    /// Returns whether `slice` points entirely inside the arena's mapping.
    ///
    /// This checks address ownership only; it does not prove that the slice is a
    /// currently live allocation.
    pub fn ownsSlice(self: *const VirtualArena, slice: []const u8) bool {
        if (slice.len == 0) return self.capacity == 0;
        const base = @intFromPtr(self.base_ptr);
        const region_end = base + self.capacity;
        const start = @intFromPtr(slice.ptr);
        const last = @intFromPtr(slice.ptr + slice.len - 1);
        return base <= start and last < region_end;
    }

    /// Returns whether `buf` ends exactly at the current arena offset.
    ///
    /// Such buffers can be resized upward, shrunk, or freed in place because
    /// they are the arena's most recent allocation.
    pub fn isLastAllocation(self: *const VirtualArena, buf: []const u8) bool {
        return buf.ptr + buf.len == self.base_ptr + self.offset;
    }

    /// Returns a standard allocator interface backed by this arena.
    ///
    /// The allocator borrows the arena. It is valid only while the arena is alive.
    /// Calls to `free` through this allocator do not reclaim memory; use `reset`
    /// or `restore` to reclaim arena allocations as a group.
    pub fn allocator(self: *VirtualArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    /// Allocator vtable callback that reserves `len` aligned bytes linearly.
    ///
    /// Returns null if the requested alignment cannot be satisfied, if the arena
    /// does not have enough remaining capacity, or if committing the required
    /// pages fails.
    fn alloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self = cast(*VirtualArena)(ctx);

        const adjust_off = mem.alignPointerOffset(self.base_ptr + self.offset, alignment.toByteUnits()) orelse
            return null;
        const aligned_offset = self.offset + adjust_off;

        if (aligned_offset > self.capacity or len > self.capacity - aligned_offset) {
            return null;
        }

        const new_offset = aligned_offset + len;
        if (!self.commitTo(new_offset)) return null;

        const result_ptr = self.base_ptr + aligned_offset;
        self.offset = new_offset;

        return result_ptr;
    }

    /// Allocator vtable callback that resizes an existing allocation.
    ///
    /// The most recent allocation can grow or shrink in place. Older
    /// allocations may only report successful shrinkage because their trailing
    /// space cannot be reclaimed without violating arena order.
    fn resize(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        _ = ret_addr;
        const self = cast(*VirtualArena)(ctx);
        assert(@inComptime() or self.ownsSlice(buf));

        if (!self.isLastAllocation(buf)) {
            if (new_len > buf.len) return false;
            return true;
        }

        // Shrink: reclaim space from the last allocation.
        if (new_len <= buf.len) {
            self.offset -= buf.len - new_len;
            return true;
        }

        // Grow the last allocation
        const additional_len = new_len - buf.len;
        if (additional_len > self.capacity - self.offset) {
            return false;
        }

        if (!self.commitTo(self.offset + additional_len)) return false;

        self.offset += additional_len;
        return true;
    }

    /// Allocator vtable callback that remaps only when resize succeeds in place.
    fn remap(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(ctx, buf, alignment, new_len, ret_addr)) buf.ptr else null;
    }

    /// Allocator vtable callback for per-allocation free.
    ///
    /// This is intentionally a no-op. Arena memory is reclaimed as a group with
    /// `reset`, `restore`, or `deinit`.
    fn free(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self = cast(*VirtualArena)(ctx);
        assert(@inComptime() or self.ownsSlice(buf));
    }

    /// Ensures that all pages up to `new_offset` are committed and accessible.
    fn commitTo(self: *VirtualArena, new_offset: usize) bool {
        assert(new_offset <= self.capacity);

        const new_committed = roundUpToPage(new_offset) catch return false;
        assert(new_committed <= self.reserved_size);

        if (new_committed <= self.committed) return true;

        const commit_ptr = self.base_ptr + self.committed;
        const commit_len = new_committed - self.committed;
        if (!commitMemory(commit_ptr, commit_len)) return false;

        self.committed = new_committed;
        return true;
    }
};

fn roundUpToPage(value: usize) !usize {
    const page_size = std.heap.pageSize();
    const remainder = value % page_size;
    if (remainder == 0) return value;
    return std.math.add(usize, value, page_size - remainder) catch error.OutOfMemory;
}

fn reserveMemory(size: usize) ![*]u8 {
    if (size == 0) return error.InvalidCapacity;

    if (native_os == .windows) {
        var base_addr: ?*anyopaque = null;
        var region_size: windows.SIZE_T = size;
        const status = ntdll.NtAllocateVirtualMemory(
            windows.GetCurrentProcess(),
            @ptrCast(&base_addr),
            0,
            &region_size,
            .{ .RESERVE = true },
            .{ .NOACCESS = true },
        );
        if (status != .SUCCESS) return error.OutOfMemory;
        return @ptrCast(base_addr.?);
    }

    const memory = try posix.mmap(
        null,
        size,
        .{},
        posix.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    return memory.ptr;
}

fn commitMemory(ptr: [*]u8, size: usize) bool {
    if (size == 0) return true;

    if (native_os == .windows) {
        var base_addr: ?*anyopaque = ptr;
        var region_size: windows.SIZE_T = size;
        const status = ntdll.NtAllocateVirtualMemory(
            windows.GetCurrentProcess(),
            @ptrCast(&base_addr),
            0,
            &region_size,
            .{ .COMMIT = true },
            .{ .READWRITE = true },
        );
        return status == .SUCCESS;
    }

    return posix.errno(posix.system.mprotect(ptr, size, .{ .READ = true, .WRITE = true })) == .SUCCESS;
}

fn releaseMemory(ptr: [*]u8, size: usize) void {
    if (native_os == .windows) {
        var base_addr: ?*anyopaque = ptr;
        var region_size: windows.SIZE_T = 0;
        _ = ntdll.NtFreeVirtualMemory(
            windows.GetCurrentProcess(),
            @ptrCast(&base_addr),
            &region_size,
            .{ .RELEASE = true },
        );
        return;
    }

    posix.munmap(@as([*]align(std.heap.page_size_min) u8, @alignCast(ptr))[0..size]);
}

const testing = std.testing;

test "VirtualArena mark/restore" {
    var arena = try VirtualArena.init(2 * std.heap.pageSize());
    defer arena.deinit();

    const persistent = try arena.allocator().alloc(u8, 32);

    arena.mark();
    _ = try arena.allocator().alloc(u8, 64);
    try testing.expect(arena.queryUsed() > persistent.len);

    arena.restore();
    try testing.expectEqual(persistent.len, arena.queryUsed());
    try testing.expect(arena.ownsSlice(persistent));
}

test "VirtualArena usable as temporary sub-arena" {
    var arena = try VirtualArena.init(2 * std.heap.pageSize());
    defer arena.deinit();

    arena.mark();
    defer arena.restore();

    var slice = try arena.allocator().alloc(u8, 16);
    try testing.expect(arena.allocator().resize(slice, 48));
    slice = slice.ptr[0..48];
    try testing.expectEqual(@as(usize, 48), arena.queryUsed());

    arena.restore();
    try testing.expectEqual(@as(usize, 0), arena.queryUsed());
}

test "VirtualArena commits pages on demand" {
    const page_size = std.heap.pageSize();
    var arena = try VirtualArena.init(3 * page_size);
    defer arena.deinit();

    try testing.expectEqual(@as(usize, 3 * page_size), arena.queryCapacity());
    try testing.expectEqual(@as(usize, 3 * page_size), arena.queryReserved());
    try testing.expectEqual(@as(usize, 0), arena.queryCommitted());

    _ = try arena.allocator().alloc(u8, 1);
    try testing.expectEqual(page_size, arena.queryCommitted());

    _ = try arena.allocator().alloc(u8, page_size);
    try testing.expectEqual(2 * page_size, arena.queryCommitted());
}

test "VirtualArena allocator free is no-op" {
    var arena = try VirtualArena.init(2 * std.heap.pageSize());
    defer arena.deinit();

    const allocation = try arena.allocator().alloc(u8, 32);
    arena.allocator().free(allocation);

    try testing.expectEqual(@as(usize, 32), arena.queryUsed());
}

/// Returns a fixed-capacity array type with inline storage.
///
/// `BoundedArray` never allocates. Its maximum element count is known at
/// compile time, and `append` reports capacity exhaustion with `false`.
pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        /// Inline storage for up to `capacity` elements.
        items: [capacity]T = undefined,

        /// Number of initialized elements in `items`.
        len: usize = 0,

        const Self = @This();

        /// Creates an empty bounded array without initializing backing storage.
        pub fn initUndefined() Self {
            return .{};
        }

        /// Appends `item` if capacity remains.
        ///
        /// Returns `true` when the item is appended and `false` when the array is full.
        pub fn append(self: *Self, item: T) bool {
            if (self.len >= capacity) return false;
            self.items[self.len] = item;
            self.len += 1;
            return true;
        }

        /// Returns the initialized prefix of the backing storage.
        pub fn slice(self: *Self) []T {
            return self.items[0..self.len];
        }

        /// Drops all elements by setting the length to zero.
        ///
        /// This does not clear or overwrite the backing storage.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}
