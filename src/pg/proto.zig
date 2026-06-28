const std = @import("std");

pub const MessageError = error{
    Overflow,
    Underflow,
};

pub const OutMessage = struct {
    data: []u8,
    pos: usize = 0,
    has_tag: bool,
    err: ?MessageError = null,

    /// Starts a regular PostgreSQL backend message with a 1-byte tag and a 4-byte length placeholder.
    pub fn begin(buffer: []u8, tag: u8) OutMessage {
        var msg = OutMessage{
            .data = buffer,
            .pos = 0,
            .has_tag = true,
        };
        msg.writeByte(tag);
        msg.writeInt32(0); // length placeholder
        return msg;
    }

    /// Starts a PostgreSQL startup message (no tag, 4-byte length placeholder).
    pub fn beginStartup(buffer: []u8) OutMessage {
        var msg = OutMessage{
            .data = buffer,
            .pos = 0,
            .has_tag = false,
        };
        msg.writeInt32(0); // length placeholder
        return msg;
    }

    pub fn writeByte(self: *OutMessage, b: u8) void {
        if (self.err != null) return;
        if (self.pos >= self.data.len) {
            self.err = error.Overflow;
            return;
        }
        self.data[self.pos] = b;
        self.pos += 1;
    }

    pub fn writeInt32(self: *OutMessage, v: i32) void {
        if (self.err != null) return;
        if (self.pos + 4 > self.data.len) {
            self.err = error.Overflow;
            return;
        }
        std.mem.writeInt(i32, self.data[self.pos..][0..4], v, .big);
        self.pos += 4;
    }

    pub fn writeInt16(self: *OutMessage, v: i16) void {
        if (self.err != null) return;
        if (self.pos + 2 > self.data.len) {
            self.err = error.Overflow;
            return;
        }
        std.mem.writeInt(i16, self.data[self.pos..][0..2], v, .big);
        self.pos += 2;
    }

    pub fn writeBytes(self: *OutMessage, bytes: []const u8) void {
        if (self.err != null) return;
        if (self.pos + bytes.len > self.data.len) {
            self.err = error.Overflow;
            return;
        }
        @memcpy(self.data[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    /// Writes a null-terminated string.
    pub fn writeString(self: *OutMessage, s: []const u8) void {
        self.writeBytes(s);
        self.writeByte(0);
    }

    /// Patches the length field and returns the built message slice.
    pub fn build(self: *OutMessage) MessageError![]u8 {
        if (self.err) |e| return e;
        const total_len = self.pos;
        if (self.has_tag) {
            // Write length at data[1..5] (after 1-byte tag).
            // PostgreSQL message length excludes the tag byte.
            const len_val: i32 = @intCast(total_len - 1);
            std.mem.writeInt(i32, self.data[1..5], len_val, .big);
        } else {
            // Write length at data[0..4].
            const len_val: i32 = @intCast(total_len);
            std.mem.writeInt(i32, self.data[0..4], len_val, .big);
        }
        return self.data[0..self.pos];
    }
};

pub const InMessage = struct {
    tag: u8,
    data: []const u8,
    pos: usize = 0,

    pub fn init(tag: u8, data: []const u8) InMessage {
        return .{
            .tag = tag,
            .data = data,
            .pos = 0,
        };
    }

    pub fn readByte(self: *InMessage) MessageError!u8 {
        if (self.pos >= self.data.len) return error.Underflow;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readInt32(self: *InMessage) MessageError!i32 {
        if (self.pos + 4 > self.data.len) return error.Underflow;
        const v = std.mem.readInt(i32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    pub fn readInt16(self: *InMessage) MessageError!i16 {
        if (self.pos + 2 > self.data.len) return error.Underflow;
        const v = std.mem.readInt(i16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    pub fn readBytes(self: *InMessage, len: usize) MessageError![]const u8 {
        if (self.pos + len > self.data.len) return error.Underflow;
        const bytes = self.data[self.pos..][0..len];
        self.pos += len;
        return bytes;
    }

    /// Reads a null-terminated string (without the null byte).
    pub fn readString(self: *InMessage) MessageError![]const u8 {
        var end = self.pos;
        while (end < self.data.len and self.data[end] != 0) : (end += 1) {}
        if (end >= self.data.len) return error.Underflow;
        const s = self.data[self.pos..end];
        self.pos = end + 1; // skip null terminator
        return s;
    }

    pub fn remaining(self: InMessage) usize {
        return self.data.len - self.pos;
    }
};
