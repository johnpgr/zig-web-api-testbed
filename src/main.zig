const std = @import("std");
const core = @import("core.zig");
const consts = @import("consts.zig");
const pg = @import("pg.zig");
const Config = @import("config.zig");
const server = @import("server.zig");

const Io = std.Io;
const GiB = consts.GiB;
const VirtualArena = core.VirtualArena;

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = try VirtualArena.init(1 * GiB);
    defer arena.deinit();

    var evented: Io.Evented = undefined;
    try evented.init(arena.allocator(), .{
        .thread_limit = 0, // 0 extra threads => single-threaded event loop
        .environ = init.environ,
    });
    defer evented.deinit();

    const io = evented.io();
    const main_alloc = arena.allocator();
    const config = Config.init(init.environ);

    var socket_path_buf: [256]u8 = undefined;
    const socket_path = try config.pgSocketPath(&socket_path_buf);

    std.debug.print("Connecting to PostgreSQL at socket: {s}...\n", .{socket_path});
    const conn = try pg.connect(io, main_alloc, socket_path);
    defer conn.close(io, main_alloc);

    std.debug.print("Sending PostgreSQL StartupMessage (user: {s}, database: {s})...\n", .{ config.pg_user, config.pg_database });
    try conn.startup(main_alloc, .{
        .user = config.pg_user,
        .database = config.pg_database,
    });
    std.debug.print("PostgreSQL Handshake Successful!\n", .{});

    try server.run(io, &arena, config, conn);
}
