const std = @import("std");
const Environ = std.process.Environ;

const Config = @This();

app_socket_path: []const u8,
pg_socket_dir: []const u8,
pg_port: u16,
pg_database: []const u8,
pg_user: []const u8,

pub fn init(environ: Environ) Config {
    const app_socket_path = getEnv(environ, "APP_SOCKET_PATH", "/run/johnpgr-api/api.sock");

    const pg_socket_dir = getEnv(environ, "PGHOST", "/run/postgresql");
    const pg_port_str = getEnv(environ, "PGPORT", "5432");
    const pg_port = std.fmt.parseInt(u16, pg_port_str, 10) catch 5432;

    const pg_database = getEnv(environ, "PGDATABASE", "johnpgr_api");
    const pg_user = getEnv(environ, "PGUSER", "johnpgr-api");

    return .{
        .app_socket_path = app_socket_path,
        .pg_socket_dir = pg_socket_dir,
        .pg_port = pg_port,
        .pg_database = pg_database,
        .pg_user = pg_user,
    };
}

fn getEnv(environ: Environ, key: []const u8, default: []const u8) []const u8 {
    if (Environ.getPosix(environ, key)) |val| {
        if (val.len > 0) return val;
    }
    return default;
}

pub fn pgSocketPath(self: Config, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/.s.PGSQL.{d}", .{ self.pg_socket_dir, self.pg_port });
}
