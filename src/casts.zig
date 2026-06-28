pub fn toi8(value: anytype) i8 {
    return numericCast(i8, value);
}

pub fn toi16(value: anytype) i16 {
    return numericCast(i16, value);
}

pub fn toi32(value: anytype) i32 {
    return numericCast(i32, value);
}

pub fn toi64(value: anytype) i64 {
    return numericCast(i64, value);
}

pub fn tou8(value: anytype) u8 {
    return numericCast(u8, value);
}

pub fn tou16(value: anytype) u16 {
    return numericCast(u16, value);
}

pub fn tou32(value: anytype) u32 {
    return numericCast(u32, value);
}

pub fn tou64(value: anytype) u64 {
    return numericCast(u64, value);
}

pub fn tof32(value: anytype) f32 {
    return numericCast(f32, value);
}

pub fn tof64(value: anytype) f64 {
    return numericCast(f64, value);
}

pub fn tocint(value: anytype) c_int {
    return numericCast(c_int, value);
}

pub fn tousize(value: anytype) usize {
    return numericCast(usize, value);
}

pub fn numericCast(comptime T: type, value: anytype) T {
    const S = @TypeOf(value);

    // Dispatch to the builtin numeric cast that matches the source and destination kinds.
    return switch (@typeInfo(T)) {
        .int, .comptime_int => switch (@typeInfo(S)) {
            .int, .comptime_int => @intCast(value),
            .float, .comptime_float => @intFromFloat(value),
            else => @compileError("cast() only supports numeric source types"),
        },
        .float, .comptime_float => switch (@typeInfo(S)) {
            .int, .comptime_int => @floatFromInt(value),
            .float, .comptime_float => @floatCast(value),
            else => @compileError("cast() only supports numeric source types"),
        },
        else => @compileError("cast() only supports numeric destination types"),
    };
}

pub fn reinterpretCast(comptime T: type, value: anytype) T {
    return @ptrCast(@alignCast(value));
}
