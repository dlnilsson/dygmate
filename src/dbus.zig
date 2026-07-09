//! Minimal D-Bus client: session-bus connect, EXTERNAL auth, message
//! marshal/unmarshal, and a Connection for method calls, signals, and serving
//! incoming calls. Only the subset needed by StatusNotifierItem +
//! com.canonical.dbusmenu is implemented. Little-endian wire only ('l').

const std = @import("std");

// ---------------------------------------------------------------------------
// Session bus address + EXTERNAL auth.
// ---------------------------------------------------------------------------
/// Pull the `path=` value of the first `unix:` transport out of a
/// DBUS_SESSION_BUS_ADDRESS value, or null if there is no unix/path transport.
pub fn parseUnixPath(addr: []const u8) ?[]const u8 {
    return fieldOf(addr, "path=");
}

/// Pull the `abstract=` value (Linux abstract namespace socket). The caller
/// connects to this with a leading NUL byte in the socket path.
pub fn parseUnixAbstract(addr: []const u8) ?[]const u8 {
    return fieldOf(addr, "abstract=");
}

fn fieldOf(addr: []const u8, key: []const u8) ?[]const u8 {
    // Address may list several transports separated by ';'. Take the first
    // 'unix:' one and pull the requested key out of its comma-separated params.
    var it = std.mem.splitScalar(u8, addr, ';');
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, "unix:")) continue;
        const params = entry["unix:".len..];
        var pit = std.mem.splitScalar(u8, params, ',');
        while (pit.next()) |p| {
            if (std.mem.startsWith(u8, p, key)) return p[key.len..];
        }
    }
    return null;
}

/// Write "AUTH EXTERNAL <hexuid>\r\n" into buf. <hexuid> is the ASCII-decimal
/// uid, hex-encoded byte by byte (uid 1000 -> "1000" -> "31303030"). Returns
/// the used slice.
pub fn authLine(buf: []u8, uid: u32) []const u8 {
    var dec: [10]u8 = undefined;
    const d = std.fmt.bufPrint(&dec, "{d}", .{uid}) catch unreachable;
    const prefix = "AUTH EXTERNAL ";
    var n: usize = 0;
    @memcpy(buf[0..prefix.len], prefix);
    n += prefix.len;
    const hex = "0123456789abcdef";
    for (d) |c| {
        buf[n] = hex[c >> 4];
        buf[n + 1] = hex[c & 0x0f];
        n += 2;
    }
    buf[n] = '\r';
    buf[n + 1] = '\n';
    n += 2;
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Alignment table.
// ---------------------------------------------------------------------------
/// Alignment (bytes) of a D-Bus type by its type-code character.
pub fn alignOf(type_code: u8) usize {
    return switch (type_code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 's', 'o' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

// ---------------------------------------------------------------------------
// Marshaller. Writes into a caller-owned ArrayList; all integers little-endian
// (we always emit 'l'). Alignment is measured from the start of the list, which
// for a message body is the body's own origin (bodies start 8-aligned).
// ---------------------------------------------------------------------------
pub const Writer = struct {
    list: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    pub fn init(list: *std.ArrayList(u8), gpa: std.mem.Allocator) Writer {
        return .{ .list = list, .gpa = gpa };
    }

    pub fn pad(w: *Writer, alignment: usize) !void {
        while (w.list.items.len % alignment != 0) try w.list.append(w.gpa, 0);
    }

    pub fn byte(w: *Writer, v: u8) !void {
        try w.list.append(w.gpa, v);
    }

    /// Append raw bytes (alignment 1, e.g. the contents of a byte array).
    pub fn bytes(w: *Writer, b: []const u8) !void {
        try w.list.appendSlice(w.gpa, b);
    }

    pub fn boolean(w: *Writer, v: bool) !void {
        try w.uint32(if (v) 1 else 0);
    }

    pub fn int16(w: *Writer, v: i16) !void {
        try w.uint16(@bitCast(v));
    }

    pub fn uint16(w: *Writer, v: u16) !void {
        try w.pad(2);
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try w.list.appendSlice(w.gpa, &b);
    }

    pub fn int32(w: *Writer, v: i32) !void {
        try w.uint32(@bitCast(v));
    }

    pub fn uint32(w: *Writer, v: u32) !void {
        try w.pad(4);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try w.list.appendSlice(w.gpa, &b);
    }

    pub fn string(w: *Writer, s: []const u8) !void {
        try w.uint32(@intCast(s.len));
        try w.list.appendSlice(w.gpa, s);
        try w.list.append(w.gpa, 0);
    }

    pub fn objectPath(w: *Writer, s: []const u8) !void {
        try w.string(s);
    }

    pub fn signature(w: *Writer, s: []const u8) !void {
        try w.list.append(w.gpa, @intCast(s.len));
        try w.list.appendSlice(w.gpa, s);
        try w.list.append(w.gpa, 0);
    }

    /// Token returned by beginArray and consumed by endArray. Held on the
    /// caller's stack, so nested arrays work.
    pub const ArrayToken = struct { len_pos: usize, content_start: usize };

    /// Begin an array of elements whose alignment is `elem_align`. Writes the
    /// 4-byte length placeholder (aligned to 4) then pads to the element
    /// alignment (that pad is NOT counted in the array length).
    pub fn beginArray(w: *Writer, elem_align: usize) !ArrayToken {
        try w.pad(4);
        const len_pos = w.list.items.len;
        try w.list.appendSlice(w.gpa, &.{ 0, 0, 0, 0 });
        try w.pad(elem_align);
        return .{ .len_pos = len_pos, .content_start = w.list.items.len };
    }

    /// Back-patch the array byte length: bytes written since the first element
    /// (the pad between length and first element is excluded).
    pub fn endArray(w: *Writer, tok: ArrayToken) void {
        const len: u32 = @intCast(w.list.items.len - tok.content_start);
        std.mem.writeInt(u32, w.list.items[tok.len_pos..][0..4], len, .little);
    }

    /// Struct and dict-entry: pad to 8 before the fields.
    pub fn beginStruct(w: *Writer) !void {
        try w.pad(8);
    }
};

// ---------------------------------------------------------------------------
// Unmarshaller.
// ---------------------------------------------------------------------------
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub const Error = error{ EndOfData, Malformed };

    pub fn readAlign(r: *Reader, alignment: usize) void {
        while (r.pos % alignment != 0) r.pos += 1;
    }

    pub fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.data.len) return error.EndOfData;
        const v = r.data[r.pos];
        r.pos += 1;
        return v;
    }

    pub fn uint16(r: *Reader) Error!u16 {
        r.readAlign(2);
        if (r.pos + 2 > r.data.len) return error.EndOfData;
        const v = std.mem.readInt(u16, r.data[r.pos..][0..2], .little);
        r.pos += 2;
        return v;
    }

    pub fn uint32(r: *Reader) Error!u32 {
        r.readAlign(4);
        if (r.pos + 4 > r.data.len) return error.EndOfData;
        const v = std.mem.readInt(u32, r.data[r.pos..][0..4], .little);
        r.pos += 4;
        return v;
    }

    pub fn boolean(r: *Reader) Error!bool {
        return (try r.uint32()) != 0;
    }

    pub fn string(r: *Reader) Error![]const u8 {
        const len = try r.uint32();
        if (r.pos + len + 1 > r.data.len) return error.EndOfData;
        const s = r.data[r.pos .. r.pos + len];
        r.pos += len + 1; // skip trailing NUL
        return s;
    }

    pub fn objectPath(r: *Reader) Error![]const u8 {
        return r.string();
    }

    pub fn signature(r: *Reader) Error![]const u8 {
        const len = try r.byte();
        if (r.pos + len + 1 > r.data.len) return error.EndOfData;
        const s = r.data[r.pos .. r.pos + len];
        r.pos += @as(usize, len) + 1;
        return s;
    }

    /// Read a u32 array byte-length and return the absolute end position of the
    /// array content (after aligning past the length). Caller reads elements
    /// until `r.pos` reaches the returned end.
    pub fn arrayEnd(r: *Reader, elem_align: usize) Error!usize {
        const len = try r.uint32();
        r.readAlign(elem_align);
        return r.pos + len;
    }
};

// ---------------------------------------------------------------------------
// Message framing.
// ---------------------------------------------------------------------------
pub const MessageType = enum(u8) {
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
};

pub const HeaderField = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
};

/// A parsed message. Slices point into the buffer passed to parseMessage and
/// are valid only as long as that buffer lives.
pub const Message = struct {
    type: MessageType,
    flags: u8,
    serial: u32,
    reply_serial: ?u32 = null,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    body: []const u8 = &.{},
};

/// The set of header fields a caller wants on an outgoing message.
pub const Fields = struct {
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    signature: ?[]const u8 = null,
};

/// Marshal a full D-Bus message (fixed header + header fields + body) into a
/// freshly-allocated slice owned by the caller.
pub fn buildMessage(
    gpa: std.mem.Allocator,
    mtype: MessageType,
    flags: u8,
    serial: u32,
    fields: Fields,
    body: []const u8,
) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(gpa);
    var w = Writer.init(&list, gpa);

    // Fixed header: 'l', type, flags, version, body_length, serial.
    try w.byte('l');
    try w.byte(@intFromEnum(mtype));
    try w.byte(flags);
    try w.byte(1);
    try w.uint32(@intCast(body.len));
    try w.uint32(serial);

    // Header fields: a(yv), element alignment 8.
    const tok = try w.beginArray(8);
    if (fields.path) |p| try writeField(&w, .path, "o", .{ .str = p });
    if (fields.reply_serial) |rs| try writeField(&w, .reply_serial, "u", .{ .u32 = rs });
    if (fields.destination) |d| try writeField(&w, .destination, "s", .{ .str = d });
    if (fields.error_name) |e| try writeField(&w, .error_name, "s", .{ .str = e });
    if (fields.interface) |i| try writeField(&w, .interface, "s", .{ .str = i });
    if (fields.member) |m| try writeField(&w, .member, "s", .{ .str = m });
    if (fields.signature) |sig| try writeField(&w, .signature, "g", .{ .sig = sig });
    w.endArray(tok);

    // Body starts 8-aligned; the body bytes were marshalled from origin 0, so
    // placing them at a multiple of 8 preserves their internal alignment.
    try w.pad(8);
    try list.appendSlice(gpa, body);

    return list.toOwnedSlice(gpa);
}

const FieldValue = union(enum) {
    str: []const u8,
    u32: u32,
    sig: []const u8,
};

fn writeField(w: *Writer, code: HeaderField, sig: []const u8, value: FieldValue) !void {
    try w.beginStruct(); // (yv) is 8-aligned
    try w.byte(@intFromEnum(code));
    try w.signature(sig);
    switch (value) {
        .str => |s| try w.string(s),
        .u32 => |v| try w.uint32(v),
        .sig => |s| try w.signature(s),
    }
}

/// Convenience wrapper: build a method_call.
pub fn buildMethodCall(
    gpa: std.mem.Allocator,
    serial: u32,
    dest: []const u8,
    path: []const u8,
    iface: []const u8,
    member: []const u8,
    body_sig: ?[]const u8,
    body: []const u8,
) ![]u8 {
    return buildMessage(gpa, .method_call, 0, serial, .{
        .path = path,
        .destination = dest,
        .interface = iface,
        .member = member,
        .signature = body_sig,
    }, body);
}

/// Parse a complete message. Returns slices into `bytes`.
pub fn parseMessage(bytes: []const u8) !Message {
    var r = Reader{ .data = bytes };
    const endian = try r.byte();
    if (endian != 'l') return error.Malformed; // big-endian not supported
    const mtype_raw = try r.byte();
    const flags = try r.byte();
    _ = try r.byte(); // version
    const body_len = try r.uint32();
    const serial = try r.uint32();

    if (mtype_raw < 1 or mtype_raw > 4) return error.Malformed;
    var msg = Message{
        .type = @enumFromInt(mtype_raw),
        .flags = flags,
        .serial = serial,
    };

    // Header fields array a(yv), element alignment 8. Read each value by its
    // variant signature (so unknown field codes are skipped, not fatal), then
    // store into the matching Message field.
    const fields_end = try r.arrayEnd(8);
    while (r.pos < fields_end) {
        r.readAlign(8); // struct
        const code = try r.byte();
        const sig = try r.signature();
        const t: u8 = if (sig.len > 0) sig[0] else 0;
        switch (t) {
            's', 'o' => {
                const s = try r.string();
                switch (code) {
                    @intFromEnum(HeaderField.path) => msg.path = s,
                    @intFromEnum(HeaderField.interface) => msg.interface = s,
                    @intFromEnum(HeaderField.member) => msg.member = s,
                    @intFromEnum(HeaderField.error_name) => msg.error_name = s,
                    @intFromEnum(HeaderField.destination) => msg.destination = s,
                    @intFromEnum(HeaderField.sender) => msg.sender = s,
                    else => {},
                }
            },
            'u' => {
                const v = try r.uint32();
                if (code == @intFromEnum(HeaderField.reply_serial)) msg.reply_serial = v;
            },
            'g' => {
                const s = try r.signature();
                if (code == @intFromEnum(HeaderField.signature)) msg.signature = s;
            },
            else => return error.Malformed,
        }
    }

    r.readAlign(8); // body start
    if (r.pos + body_len > bytes.len) return error.EndOfData;
    msg.body = bytes[r.pos .. r.pos + body_len];
    return msg;
}

// ---------------------------------------------------------------------------
// Connection: unix-socket transport, EXTERNAL auth, calls/replies/signals.
// ---------------------------------------------------------------------------
const net = std.Io.net;

pub const Connection = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: net.Stream,
    serial: u32 = 0,
    unique_name: []u8 = &.{},
    /// Reused per readMessage; returned Message slices point in here and are
    /// valid until the next readMessage.
    read_buf: std.ArrayList(u8) = .empty,

    pub const Error = error{
        NoSessionBus,
        NoUnixSocket,
        AuthFailed,
        ConnectionClosed,
    } || std.mem.Allocator.Error;

    /// Connect to the session bus, authenticate (EXTERNAL), and say Hello.
    pub fn connectSession(
        io: std.Io,
        gpa: std.mem.Allocator,
        environ: *std.process.Environ.Map,
        uid: u32,
    ) !*Connection {
        const addr = environ.get("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoSessionBus;
        const path = parseUnixPath(addr) orelse return error.NoUnixSocket;
        const ua = try net.UnixAddress.init(path);
        const stream = try ua.connect(io);

        const self = try gpa.create(Connection);
        errdefer gpa.destroy(self);
        self.* = .{ .io = io, .gpa = gpa, .stream = stream };
        errdefer stream.close(io);

        try self.authenticate(uid);
        try self.hello();
        return self;
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
        self.gpa.free(self.unique_name);
        self.read_buf.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn fd(self: *Connection) std.posix.fd_t {
        return self.stream.socket.handle;
    }

    pub fn nextSerial(self: *Connection) u32 {
        self.serial += 1;
        return self.serial;
    }

    // -- transport helpers ---------------------------------------------------
    fn writeAll(self: *Connection, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const empty: []const u8 = &.{};
            const n = try self.io.vtable.netWrite(self.io.userdata, self.stream.socket.handle, bytes[off..], (&empty)[0..1], 0);
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
    }

    fn readExact(self: *Connection, buf: []u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            var vec = [_][]u8{buf[off..]};
            const n = try self.io.vtable.netRead(self.io.userdata, self.stream.socket.handle, &vec);
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
    }

    // -- auth ----------------------------------------------------------------
    fn authenticate(self: *Connection, uid: u32) !void {
        try self.writeAll(&.{0}); // required leading NUL
        var lbuf: [64]u8 = undefined;
        try self.writeAll(authLine(&lbuf, uid));

        var resp: [256]u8 = undefined;
        const line = try self.readLine(&resp);
        if (!std.mem.startsWith(u8, line, "OK")) return error.AuthFailed;
        try self.writeAll("BEGIN\r\n");
    }

    /// Read one CRLF-terminated ASCII line (auth phase only). Returns the line
    /// without the trailing CRLF.
    fn readLine(self: *Connection, buf: []u8) ![]const u8 {
        var i: usize = 0;
        while (i < buf.len) {
            try self.readExact(buf[i .. i + 1]);
            if (buf[i] == '\n') {
                const end = if (i > 0 and buf[i - 1] == '\r') i - 1 else i;
                return buf[0..end];
            }
            i += 1;
        }
        return error.AuthFailed;
    }

    // -- messages ------------------------------------------------------------
    pub fn call(
        self: *Connection,
        dest: []const u8,
        path: []const u8,
        iface: []const u8,
        member: []const u8,
        sig: ?[]const u8,
        body: []const u8,
    ) !u32 {
        const serial = self.nextSerial();
        const bytes = try buildMethodCall(self.gpa, serial, dest, path, iface, member, sig, body);
        defer self.gpa.free(bytes);
        try self.writeAll(bytes);
        return serial;
    }

    pub fn emitSignal(
        self: *Connection,
        path: []const u8,
        iface: []const u8,
        member: []const u8,
        sig: ?[]const u8,
        body: []const u8,
    ) !void {
        const serial = self.nextSerial();
        const bytes = try buildMessage(self.gpa, .signal, 0, serial, .{
            .path = path,
            .interface = iface,
            .member = member,
            .signature = sig,
        }, body);
        defer self.gpa.free(bytes);
        try self.writeAll(bytes);
    }

    pub fn reply(self: *Connection, to: Message, sig: ?[]const u8, body: []const u8) !void {
        const serial = self.nextSerial();
        const bytes = try buildMessage(self.gpa, .method_return, 0, serial, .{
            .reply_serial = to.serial,
            .destination = to.sender,
            .signature = sig,
        }, body);
        defer self.gpa.free(bytes);
        try self.writeAll(bytes);
    }

    pub fn replyError(self: *Connection, to: Message, name: []const u8, text: []const u8) !void {
        const serial = self.nextSerial();
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.gpa);
        var w = Writer.init(&body, self.gpa);
        try w.string(text);
        const bytes = try buildMessage(self.gpa, .error_reply, 0, serial, .{
            .reply_serial = to.serial,
            .destination = to.sender,
            .error_name = name,
            .signature = "s",
        }, body.items);
        defer self.gpa.free(bytes);
        try self.writeAll(bytes);
    }

    /// Block until one complete message arrives; parse and return it. Slices
    /// in the result point into read_buf (valid until the next readMessage).
    pub fn readMessage(self: *Connection) !Message {
        try self.read_buf.resize(self.gpa, 16);
        try self.readExact(self.read_buf.items[0..16]);
        const endian: std.builtin.Endian = if (self.read_buf.items[0] == 'B') .big else .little;
        const body_len = std.mem.readInt(u32, self.read_buf.items[4..8], endian);
        const harr_len = std.mem.readInt(u32, self.read_buf.items[12..16], endian);
        const header_end: usize = 16 + harr_len;
        const body_start = std.mem.alignForward(usize, header_end, 8);
        const total = body_start + body_len;
        try self.read_buf.resize(self.gpa, total);
        try self.readExact(self.read_buf.items[16..total]);
        return parseMessage(self.read_buf.items);
    }

    /// Send a method call and read messages until its reply arrives. Non-reply
    /// messages (signals, incoming calls) received meanwhile are dropped — used
    /// only for startup handshakes where no useful traffic is expected.
    pub fn callAndWait(
        self: *Connection,
        dest: []const u8,
        path: []const u8,
        iface: []const u8,
        member: []const u8,
        sig: ?[]const u8,
        body: []const u8,
    ) !Message {
        const serial = try self.call(dest, path, iface, member, sig, body);
        while (true) {
            const m = try self.readMessage();
            if ((m.type == .method_return or m.type == .error_reply) and m.reply_serial == serial) {
                if (m.type == .error_reply) return error.AuthFailed;
                return m;
            }
        }
    }

    fn hello(self: *Connection) !void {
        const m = try self.callAndWait(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "Hello",
            null,
            &.{},
        );
        var r = Reader{ .data = m.body };
        const name = try r.string();
        self.unique_name = try self.gpa.dupe(u8, name);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "parseUnixPath extracts the socket path" {
    try std.testing.expectEqualStrings(
        "/run/user/1000/bus",
        parseUnixPath("unix:path=/run/user/1000/bus").?,
    );
    try std.testing.expectEqualStrings(
        "/run/user/1000/bus",
        parseUnixPath("unix:path=/run/user/1000/bus,guid=abc123").?,
    );
    try std.testing.expect(parseUnixPath("tcp:host=localhost") == null);
}

test "authLine hex-encodes the decimal uid" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("AUTH EXTERNAL 31303030\r\n", authLine(&buf, 1000));
    try std.testing.expectEqualStrings("AUTH EXTERNAL 30\r\n", authLine(&buf, 0));
}

test "marshal string is len32 + bytes + NUL" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var w = Writer.init(&list, std.testing.allocator);
    try w.string("foo");
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 'f', 'o', 'o', 0 }, list.items);
}

test "byte then uint32 inserts 3 pad bytes for 4-alignment" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var w = Writer.init(&list, std.testing.allocator);
    try w.byte(0x11);
    try w.uint32(0x22334455);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0, 0, 0, 0x55, 0x44, 0x33, 0x22 }, list.items);
}

test "round-trip string through Reader" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var w = Writer.init(&list, std.testing.allocator);
    try w.byte(0x11);
    try w.string("hello");
    var r = Reader{ .data = list.items };
    try std.testing.expectEqual(@as(u8, 0x11), try r.byte());
    try std.testing.expectEqualStrings("hello", try r.string());
}

test "array of bytes: length excludes trailing, content follows length" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var w = Writer.init(&list, std.testing.allocator);
    const tok = try w.beginArray(1);
    try w.byte(0xAA);
    try w.byte(0xBB);
    w.endArray(tok);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0xAA, 0xBB }, list.items);
}

test "array of uint32: length counts content only, not pad after length" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var w = Writer.init(&list, std.testing.allocator);
    try w.byte(0x01); // force misalignment so array length pads to 4
    const tok = try w.beginArray(4);
    try w.uint32(0xAABBCCDD);
    w.endArray(tok);
    // 01, pad to 4: 00 00 00, len=4: 04 00 00 00, elem: DD CC BB AA
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0, 0, 0, 4, 0, 0, 0, 0xDD, 0xCC, 0xBB, 0xAA }, list.items);
}

test "frame then parse a method_call round-trips the header fields" {
    const a = std.testing.allocator;
    const bytes = try buildMethodCall(a, 7, "org.example", "/foo", "org.example.Iface", "Ping", null, &.{});
    defer a.free(bytes);
    const msg = try parseMessage(bytes);
    try std.testing.expectEqual(MessageType.method_call, msg.type);
    try std.testing.expectEqual(@as(u32, 7), msg.serial);
    try std.testing.expectEqualStrings("/foo", msg.path.?);
    try std.testing.expectEqualStrings("org.example.Iface", msg.interface.?);
    try std.testing.expectEqualStrings("Ping", msg.member.?);
    try std.testing.expectEqualStrings("org.example", msg.destination.?);
    try std.testing.expectEqual(@as(usize, 0), msg.body.len);
}

test "frame then parse a method_call with a body signature and payload" {
    const a = std.testing.allocator;
    var body = std.ArrayList(u8).empty;
    defer body.deinit(a);
    var bw = Writer.init(&body, a);
    try bw.string("hello");
    const bytes = try buildMethodCall(a, 42, "org.d", "/p", "org.d.I", "Echo", "s", body.items);
    defer a.free(bytes);
    const msg = try parseMessage(bytes);
    try std.testing.expectEqual(@as(u32, 42), msg.serial);
    try std.testing.expectEqualStrings("s", msg.signature.?);
    var br = Reader{ .data = msg.body };
    try std.testing.expectEqualStrings("hello", try br.string());
}
