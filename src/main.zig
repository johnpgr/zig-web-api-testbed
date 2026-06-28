const std = @import("std");
const consts = @import("consts.zig");
const casts = @import("casts.zig");
const VirtualArena = @import("virtual-arena.zig");
const Scratch = @import("scratch-arena.zig");
const pg = @import("pg.zig");

const Io = std.Io;
const GiB = consts.GiB;

pub fn main(init: std.process.Init.Minimal) !void {
    // 1. Initialize the Arena (Zero Reallocation Cost)
    var arena = try VirtualArena.init(1 * GiB);
    defer arena.deinit();

    // 2. Initialize the single-threaded Evented (io_uring) I/O backend using the VirtualArena
    var evented: Io.Evented = undefined;
    try evented.init(arena.allocator(), .{
        .thread_limit = 0, // 0 extra threads => single-threaded event loop
        .environ = init.environ,
    });
    defer evented.deinit();

    const io = evented.io();
    const main_alloc = arena.allocator();

    // 3. Connect to PostgreSQL
    const socket_path = "/home/joao/dev/zig-web-api-testbed/postgres_socket/.s.PGSQL.5433";
    const conn = try pg.connect(io, main_alloc, socket_path);
    defer conn.close(io, main_alloc);

    std.debug.print("Connected to PostgreSQL socket!\n", .{});

    // 4. Begin a Scratch scope for the request/transaction
    var scratch = Scratch.begin(&arena);
    defer scratch.end();
    const alloc = scratch.allocator();

    // 5. Send Startup Message / Perform Handshake
    std.debug.print("Sending StartupMessage...\n", .{});
    try conn.startup(alloc, "joao", "postgres");
    std.debug.print("Authentication and Handshake Successful!\n", .{});

    // 6. Execute Query
    std.debug.print("Executing query...\n", .{});
    var result = try conn.query(alloc, "SELECT 42 as number, 'Antigravity' as name, NULL as val;");
    defer result.deinit();

    std.debug.print("Columns:\n", .{});
    for (result.columns) |col| {
        std.debug.print("  - {s} (OID: {})\n", .{col.name, col.type_oid});
    }

    std.debug.print("Rows:\n", .{});
    while (try result.next()) |row| {
        const num = try row.getInt(0, i32);
        const name = row.get(1) orelse "NULL";
        const val = row.get(2) orelse "NULL";
        std.debug.print("  - num: {}, name: {s}, val: {s}\n", .{num, name, val});
    }

    std.debug.print("Done!\n", .{});
}
