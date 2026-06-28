const std = @import("std");
const posix = std.posix;
const casts = @import("casts.zig");
const Io = std.Io;
const proto = @import("pg/proto.zig");
const InMessage = proto.InMessage;
const OutMessage = proto.OutMessage;
const tousize = casts.tousize;

pub const Column = struct {
    name: []const u8,
    type_oid: i32,
};

pub const Row = struct {
    fields: []const ?[]const u8,

    pub fn get(self: Row, index: usize) ?[]const u8 {
        if (index >= self.fields.len) return null;
        return self.fields[index];
    }

    pub fn getInt(self: Row, index: usize, comptime T: type) !T {
        const str = self.get(index) orelse return error.NullValue;
        return try std.fmt.parseInt(T, str, 10);
    }
};

pub const StartupOptions = struct {
    user: []const u8,
    database: []const u8,
    password: ?[]const u8 = null,
};

fn bytesToHex(bytes: []const u8, out_hex: []u8) !void {
    var i: usize = 0;
    for (bytes) |b| {
        _ = try std.fmt.bufPrint(out_hex[i..][0..2], "{x:0>2}", .{b});
        i += 2;
    }
}

fn computeMd5Password(
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
    salt: []const u8,
) ![]const u8 {
    const Md5 = std.crypto.hash.Md5;

    const concat1 = try std.fmt.allocPrint(allocator, "{s}{s}", .{ password, username });
    defer allocator.free(concat1);

    var hash1: [Md5.digest_length]u8 = undefined;
    Md5.hash(concat1, &hash1, .{});

    var hex1: [Md5.digest_length * 2]u8 = undefined;
    try bytesToHex(&hash1, &hex1);

    var concat2: [36]u8 = undefined;
    @memcpy(concat2[0..32], &hex1);
    @memcpy(concat2[32..36], salt);

    var hash2: [Md5.digest_length]u8 = undefined;
    Md5.hash(&concat2, &hash2, .{});

    var hex2: [Md5.digest_length * 2]u8 = undefined;
    try bytesToHex(&hash2, &hex2);

    return try std.fmt.allocPrint(allocator, "md5{s}", .{hex2});
}

pub const QueryResult = struct {
    conn: *PgConnection,
    allocator: std.mem.Allocator,
    columns: []Column,
    columns_buffer: ?[]const u8 = null,
    done: bool = false,
    active_row_data: ?[]const u8 = null,
    active_row_fields: ?[]const ?[]const u8 = null,

    pub fn init(conn: *PgConnection, allocator: std.mem.Allocator) !QueryResult {
        var self = QueryResult{
            .conn = conn,
            .allocator = allocator,
            .columns = &.{},
            .columns_buffer = null,
            .done = false,
            .active_row_data = null,
            .active_row_fields = null,
        };
        try self.readHeader();
        return self;
    }

    pub fn deinit(self: *QueryResult) void {
        if (self.columns_buffer) |buf| {
            self.allocator.free(buf);
        }
        self.allocator.free(self.columns);
        if (self.active_row_data) |data| {
            self.allocator.free(data);
        }
        if (self.active_row_fields) |fields| {
            self.allocator.free(fields);
        }
    }

    fn readHeader(self: *QueryResult) !void {
        var msg = try self.conn.readMessage(self.allocator);
        defer self.allocator.free(msg.data);

        switch (msg.tag) {
            'T' => { // RowDescription
                const num_fields = try msg.readInt16();
                if (num_fields < 0) return error.InvalidRowDescription;

                const cols = try self.allocator.alloc(Column, @intCast(num_fields));
                errdefer self.allocator.free(cols);

                // Transfer ownership of message buffer to QueryResult
                self.columns_buffer = msg.data;
                const original_data = msg.data;
                msg.data = &.{}; // Prevent defer from freeing it

                var temp_msg = InMessage.init('T', original_data);
                temp_msg.pos = msg.pos;

                const limit = tousize(num_fields);
                var i: usize = 0;
                while (i < limit) : (i += 1) {
                    const name = try temp_msg.readString();
                    _ = try temp_msg.readInt32(); // table OID
                    _ = try temp_msg.readInt16(); // column attribute index
                    const type_oid = try temp_msg.readInt32();
                    _ = try temp_msg.readInt16(); // type size
                    _ = try temp_msg.readInt32(); // type modifier
                    _ = try temp_msg.readInt16(); // format code

                    cols[i] = .{
                        .name = name,
                        .type_oid = type_oid,
                    };
                }
                self.columns = cols;
            },
            'C' => { // CommandComplete
                self.done = true;
                const z_msg = try self.conn.readMessage(self.allocator);
                defer self.allocator.free(z_msg.data);
                if (z_msg.tag != 'Z') return error.ExpectedReadyForQuery;
            },
            'E' => { // ErrorResponse
                try self.conn.parseErrorResponse(&msg);
            },
            else => {
                return error.UnexpectedMessage;
            },
        }
    }

    pub fn next(self: *QueryResult) !?Row {
        // Free previous row resources
        if (self.active_row_data) |data| {
            self.allocator.free(data);
            self.active_row_data = null;
        }
        if (self.active_row_fields) |fields| {
            self.allocator.free(fields);
            self.active_row_fields = null;
        }

        if (self.done) return null;

        while (true) {
            var msg = try self.conn.readMessage(self.allocator);
            errdefer self.allocator.free(msg.data);

            switch (msg.tag) {
                'D' => { // DataRow
                    const num_vals = try msg.readInt16();
                    if (num_vals < 0) return error.InvalidDataRow;

                    const fields = try self.allocator.alloc(?[]const u8, @intCast(num_vals));
                    errdefer self.allocator.free(fields);

                    const limit = tousize(num_vals);
                    var i: usize = 0;
                    while (i < limit) : (i += 1) {
                        const val_len = try msg.readInt32();
                        if (val_len == -1) {
                            fields[i] = null;
                        } else if (val_len < 0) {
                            return error.InvalidFieldLength;
                        } else {
                            const val_bytes = try msg.readBytes(@intCast(val_len));
                            fields[i] = val_bytes;
                        }
                    }

                    self.active_row_data = msg.data;
                    self.active_row_fields = fields;

                    return Row{ .fields = fields };
                },
                'C' => { // CommandComplete
                    self.done = true;
                    const z_msg = try self.conn.readMessage(self.allocator);
                    defer self.allocator.free(z_msg.data);
                    if (z_msg.tag != 'Z') return error.ExpectedReadyForQuery;

                    self.allocator.free(msg.data);
                    return null;
                },
                'E' => { // ErrorResponse
                    defer self.allocator.free(msg.data);
                    try self.conn.parseErrorResponse(&msg);
                },
                else => {
                    self.allocator.free(msg.data);
                },
            }
        }
    }
};

pub const PgConnection = struct {
    file: Io.File,
    io: Io,
    read_buffer: []u8,
    pg_reader: Io.File.Reader,

    pub fn close(self: *PgConnection, io: Io, allocator: std.mem.Allocator) void {
        self.file.close(io);
        allocator.free(self.read_buffer);
        allocator.destroy(self);
    }

    pub fn readMessage(self: *PgConnection, allocator: std.mem.Allocator) !InMessage {
        const tag = try self.pg_reader.interface.takeByte();
        const length = try self.pg_reader.interface.takeInt(i32, .big);
        if (length < 4) return error.InvalidMessageLength;
        const payload_len = tousize(length - 4);

        const payload = try allocator.alloc(u8, payload_len);
        errdefer allocator.free(payload);

        try self.pg_reader.interface.readSliceAll(payload);
        return InMessage.init(tag, payload);
    }

    pub fn parseErrorResponse(self: *PgConnection, msg: *InMessage) !void {
        _ = self;
        std.debug.print("PostgreSQL Error:\n", .{});
        while (true) {
            const field_type = try msg.readByte();
            if (field_type == 0) break;
            const value = try msg.readString();
            switch (field_type) {
                'S' => std.debug.print("  Severity: {s}\n", .{value}),
                'C' => std.debug.print("  Code: {s}\n", .{value}),
                'M' => std.debug.print("  Message: {s}\n", .{value}),
                'D' => std.debug.print("  Detail: {s}\n", .{value}),
                'H' => std.debug.print("  Hint: {s}\n", .{value}),
                else => {},
            }
        }
        return error.PostgresError;
    }

    fn sendPassword(self: *PgConnection, allocator: std.mem.Allocator, password: []const u8) !void {
        const msg_len = 1 + 4 + password.len + 1;
        const buf = try allocator.alloc(u8, msg_len);
        defer allocator.free(buf);

        var out = OutMessage.begin(buf, 'p');
        out.writeString(password);
        const msg_slice = try out.build();

        var write_buf: [256]u8 = undefined;
        var pg_writer = self.file.writerStreaming(self.io, &write_buf);
        try pg_writer.interface.writeAll(msg_slice);
        try pg_writer.interface.flush();
    }

    pub fn startup(
        self: *PgConnection,
        allocator: std.mem.Allocator,
        options: StartupOptions,
    ) !void {
        var send_buf: [512]u8 = undefined;
        var out = OutMessage.beginStartup(&send_buf);

        out.writeInt32(196608); // Protocol version 3.0
        out.writeString("user");
        out.writeString(options.user);
        out.writeString("database");
        out.writeString(options.database);
        out.writeByte(0);

        const msg_slice = try out.build();

        var write_buf: [256]u8 = undefined;
        var pg_writer = self.file.writerStreaming(self.io, &write_buf);
        try pg_writer.interface.writeAll(msg_slice);
        try pg_writer.interface.flush();

        while (true) {
            var msg = try self.readMessage(allocator);
            defer allocator.free(msg.data);

            switch (msg.tag) {
                'R' => {
                    const auth_type = try msg.readInt32();
                    if (auth_type == 0) {
                        // Success
                    } else if (auth_type == 3) {
                        const pwd = options.password orelse return error.PasswordRequired;
                        try self.sendPassword(allocator, pwd);
                    } else if (auth_type == 5) {
                        const salt = try msg.readBytes(4);
                        const pwd = options.password orelse return error.PasswordRequired;
                        const hashed_pwd = try computeMd5Password(allocator, options.user, pwd, salt);
                        defer allocator.free(hashed_pwd);
                        try self.sendPassword(allocator, hashed_pwd);
                    } else {
                        return error.UnsupportedAuthenticationMethod;
                    }
                },
                'S' => {
                    _ = try msg.readString(); // name
                    _ = try msg.readString(); // value
                },
                'K' => {
                    _ = try msg.readInt32(); // pid
                    _ = try msg.readInt32(); // key
                },
                'Z' => {
                    _ = try msg.readByte(); // tx_status
                    break;
                },
                'E' => {
                    try self.parseErrorResponse(&msg);
                },
                else => {},
            }
        }
    }

    pub fn query(
        self: *PgConnection,
        allocator: std.mem.Allocator,
        sql: []const u8,
    ) !QueryResult {
        const query_msg_len = 1 + 4 + sql.len + 1;
        const query_buf = try allocator.alloc(u8, query_msg_len);
        defer allocator.free(query_buf);

        var out = OutMessage.begin(query_buf, 'Q');
        out.writeString(sql);
        const msg_slice = try out.build();

        var write_buf: [256]u8 = undefined;
        var pg_writer = self.file.writerStreaming(self.io, &write_buf);
        try pg_writer.interface.writeAll(msg_slice);
        try pg_writer.interface.flush();

        return QueryResult.init(self, allocator);
    }
};

pub fn connect(io: Io, allocator: std.mem.Allocator, socket_path: []const u8) !*PgConnection {
    const socket_rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (posix.errno(socket_rc) != .SUCCESS) {
        return posix.unexpectedErrno(posix.errno(socket_rc));
    }
    const pg_fd: posix.fd_t = @intCast(socket_rc);
    errdefer _ = posix.system.close(pg_fd);

    var addr_storage: extern union {
        any: posix.sockaddr,
        un: posix.sockaddr.un,
    } = undefined;

    addr_storage.un.family = posix.AF.UNIX;
    if (socket_path.len >= addr_storage.un.path.len) return error.SocketPathTooLong;
    @memcpy(addr_storage.un.path[0..socket_path.len], socket_path);
    addr_storage.un.path[socket_path.len] = 0;
    const addr_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + socket_path.len + 1);

    const connect_rc = posix.system.connect(pg_fd, &addr_storage.any, addr_len);
    if (connect_rc != 0 and posix.errno(connect_rc) != .SUCCESS) {
        return posix.unexpectedErrno(posix.errno(connect_rc));
    }

    const conn = try allocator.create(PgConnection);
    errdefer allocator.destroy(conn);

    const read_buf = try allocator.alloc(u8, 4096);
    errdefer allocator.free(read_buf);

    conn.* = .{
        .file = .{
            .handle = pg_fd,
            .flags = .{ .nonblocking = false },
        },
        .io = io,
        .read_buffer = read_buf,
        .pg_reader = undefined,
    };
    conn.pg_reader = conn.file.readerStreaming(io, conn.read_buffer);

    return conn;
}
