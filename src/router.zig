const std = @import("std");
const http = std.http;
const pg = @import("pg.zig");

pub fn dispatch(
    allocator: std.mem.Allocator,
    request: *http.Server.Request,
    conn: *pg.PgConnection,
    keep_alive: bool,
) !void {
    const method = request.head.method;
    const target = request.head.target;

    const headers = &.{
        http.Header{ .name = "Content-Type", .value = "application/json" },
    };

    if (std.mem.eql(u8, target, "/health")) {
        if (method != .GET) {
            try respondError(request, .method_not_allowed, "Method Not Allowed", keep_alive);
            return;
        }
        try request.respond("{\"status\":\"ok\"}\n", .{
            .status = .ok,
            .keep_alive = keep_alive,
            .extra_headers = headers,
        });
    } else if (std.mem.eql(u8, target, "/db-test")) {
        if (method != .GET) {
            try respondError(request, .method_not_allowed, "Method Not Allowed", keep_alive);
            return;
        }

        // Query database using the connection
        var result = conn.query(allocator, "SELECT 42 as val, 'PostgreSQL Unix Socket Connection OK' as msg;") catch |err| {
            std.debug.print("Database query failed: {any}\n", .{err});
            try respondError(request, .internal_server_error, "Database connection error", keep_alive);
            return;
        };
        defer result.deinit();

        var val: i32 = 0;
        var msg_str: []const u8 = "unknown";
        if (try result.next()) |row| {
            val = try row.getInt(0, i32);
            msg_str = row.get(1) orelse "NULL";
        }

        var json_buf: [256]u8 = undefined;
        const response_body = try std.fmt.bufPrint(&json_buf, "{{\"db_response\":{},\"message\":\"{s}\"}}\n", .{ val, msg_str });

        try request.respond(response_body, .{
            .status = .ok,
            .keep_alive = keep_alive,
            .extra_headers = headers,
        });
    } else if (std.mem.eql(u8, target, "/")) {
        if (method != .GET) {
            try respondError(request, .method_not_allowed, "Method Not Allowed", keep_alive);
            return;
        }
        try request.respond("{\"name\":\"johnpgr-api\",\"version\":\"0.1.0\",\"description\":\"JohnPGR Zig REST API Server\"}\n", .{
            .status = .ok,
            .keep_alive = keep_alive,
            .extra_headers = headers,
        });
    } else {
        try respondError(request, .not_found, "Route Not Found", keep_alive);
    }
}

fn respondError(request: *http.Server.Request, status: http.Status, message: []const u8, keep_alive: bool) !void {
    var json_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&json_buf, "{{\"error\":\"{s}\",\"code\":{d}}}\n", .{ message, @intFromEnum(status) });
    try request.respond(body, .{
        .status = status,
        .keep_alive = keep_alive,
        .extra_headers = &.{
            http.Header{ .name = "Content-Type", .value = "application/json" },
        },
    });
}
