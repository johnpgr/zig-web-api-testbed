const std = @import("std");
const core = @import("core.zig");
const pg = @import("pg.zig");
const router = @import("router.zig");
const Config = @import("config.zig");

const VirtualArena = core.VirtualArena;
const Io = std.Io;
const net = std.Io.net;
const http = std.http;
const posix = std.posix;

pub fn run(
    io: Io,
    arena: *VirtualArena,
    config: Config,
    conn: *pg.PgConnection,
) !void {
    const socket_path = config.app_socket_path;

    // Unlink socket if it already exists to avoid AddressInUse
    Io.Dir.deleteFileAbsolute(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    const fd_rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (posix.errno(fd_rc) != .SUCCESS) {
        return posix.unexpectedErrno(posix.errno(fd_rc));
    }
    const socket_fd: posix.fd_t = @intCast(fd_rc);
    errdefer _ = posix.system.close(socket_fd);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    if (socket_path.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;
    const addr_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + socket_path.len + 1);

    const bind_rc = posix.system.bind(socket_fd, @ptrCast(&addr), addr_len);
    if (posix.errno(bind_rc) != .SUCCESS) {
        return posix.unexpectedErrno(posix.errno(bind_rc));
    }

    // Set permissions of the socket file so that Nginx can write to it
    const path_c = try arena.allocator().dupeSentinel(u8, socket_path, 0);
    defer arena.allocator().free(path_c);
    const chmod_rc = posix.system.chmod(path_c, 0o777);
    if (posix.errno(chmod_rc) != .SUCCESS) {
        return posix.unexpectedErrno(posix.errno(chmod_rc));
    }

    const listen_rc = posix.system.listen(socket_fd, 128);
    if (posix.errno(listen_rc) != .SUCCESS) {
        return posix.unexpectedErrno(posix.errno(listen_rc));
    }

    std.debug.print("Server running on Unix socket: {s}\n", .{socket_path});

    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;

    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const client_fd_rc = posix.system.accept(socket_fd, &client_addr, &client_addr_len);
        if (posix.errno(client_fd_rc) != .SUCCESS) {
            std.debug.print("Accept error: {any}\n", .{posix.errno(client_fd_rc)});
            continue;
        }
        const client_fd: posix.fd_t = @intCast(client_fd_rc);

        const client_file = Io.File{
            .handle = client_fd,
            .flags = .{ .nonblocking = false },
        };
        defer client_file.close(io);

        var stream_reader = client_file.readerStreaming(io, &recv_buffer);
        var stream_writer = client_file.writerStreaming(io, &send_buffer);

        var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

        while (true) {
            var request = http_server.receiveHead() catch |err| {
                if (err == error.HttpConnectionClosing) {
                    break;
                }
                std.debug.print("Receive head error: {any}\n", .{err});
                break;
            };

            // If it's a request with body but no Content-Length or Chunked encoding, force keep_alive to false.
            // This avoids panics in the std.http.Server.zig library due to missing framing headers.
            const keep_alive = request.head.keep_alive and !(request.head.method.requestHasBody() and request.head.transfer_encoding == .none and request.head.content_length == null);

            // Rewind request-scoped allocations after dispatch.
            arena.mark();
            defer arena.restore();
            const request_allocator = arena.allocator();

            router.dispatch(request_allocator, &request, conn, keep_alive) catch |err| {
                std.debug.print("Request routing/dispatch error: {any}\n", .{err});
            };

            if (!keep_alive) {
                break;
            }
        }
    }
}
