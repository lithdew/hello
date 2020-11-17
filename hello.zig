const std = @import("std");
const pike = @import("pike/pike.zig");
const zap = @import("zap/src/zap.zig");

const os = std.os;
const mem = std.mem;
const net = std.net;
const log = std.log;
const heap = std.heap;
const atomic = std.atomic;

pub const pike_task = zap.runtime.executor.Task;
pub const pike_batch = zap.runtime.executor.Batch;
pub const pike_dispatch = dispatch;

inline fn dispatch(batchable: anytype, args: anytype) void {
    zap.runtime.schedule(batchable, args);
}

pub fn main() !void {
    try pike.init();
    defer pike.deinit();

    var signal = try pike.Signal.init(.{ .interrupt = true });

    try try zap.runtime.run(.{}, asyncMain, .{&signal});
}

pub fn asyncMain(signal: *pike.Signal) !void {
    defer signal.deinit();

    var event = try pike.Event.init();
    defer event.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    try signal.registerTo(&notifier);
    try event.registerTo(&notifier);

    var stopped = false;

    var frame = async run(&notifier, signal, &event, &stopped);

    while (!stopped) {
        try notifier.poll(1_000_000);
    }

    try nosuspend await frame;

    defer log.debug("Successfully shut down.", .{});
}

pub const ClientQueue = atomic.Queue(*Client);

pub const Client = struct {
    socket: pike.Socket,
    address: net.Address,

    fn run(server: *Server, notifier: *const pike.Notifier, _socket: pike.Socket, _address: net.Address) void {
        run_(server, notifier, _socket, _address) catch |err| {
            log.err("Client - run(): {}", .{@errorName(err)});
        };
    }

    inline fn run_(server: *Server, notifier: *const pike.Notifier, _socket: pike.Socket, _address: net.Address) !void {
        zap.runtime.yield();

        var self = Client{ .socket = _socket, .address = _address };
        var node = ClientQueue.Node{ .data = &self };

        server.clients.put(&node);
        defer if (server.clients.remove(&node)) {
            self.socket.deinit();
        };

        try self.socket.registerTo(notifier);

        var buf: [4096]u8 = undefined;
        var buf_len: usize = 0;

        while (true) {
            while (true) {
                const num_bytes = try self.socket.read(buf[buf_len..]);
                if (num_bytes == 0) return;

                if (buf_len + num_bytes >= @sizeOf(@TypeOf(buf))) {
                    return error.RequestTooLarge;
                }

                if (mem.indexOf(u8, buf[buf_len..][0..num_bytes], "\r\n\r\n") != null) {
                    break;
                }

                buf_len += num_bytes;
            }

            try self.socket.writer().writeAll("HTTP/1.1 200 Ok\r\nContent-Length: 11\r\n\r\nHello World");

            buf_len = 0;
        }
    }
};

pub const Server = struct {
    socket: pike.Socket,
    clients: ClientQueue,

    frame: @Frame(Server.run),

    pub fn init() !Server {
        var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
        errdefer socket.deinit();

        try socket.set(.reuse_address, true);

        return Server{
            .socket = socket,
            .clients = ClientQueue.init(),
            .frame = undefined,
        };
    }

    pub fn deinit(self: *Server) void {
        self.socket.deinit();

        await self.frame;

        while (self.clients.get()) |node| {
            node.data.socket.deinit();
        }
    }

    pub fn start(self: *Server, notifier: *const pike.Notifier, address: net.Address) !void {
        try self.socket.bind(address);
        try self.socket.listen(128);
        try self.socket.registerTo(notifier);

        self.frame = async self.run(notifier);

        log.info("Web server started on: {}", .{address});
    }

    fn run(self: *Server, notifier: *const pike.Notifier) callconv(.Async) void {
        defer log.debug("Web server has shut down.", .{});

        while (true) {
            var conn = self.socket.accept() catch |err| switch (err) {
                error.SocketNotListening,
                error.OperationCancelled,
                => return,
                else => {
                    log.err("Server - socket.accept(): {}", .{@errorName(err)});
                    continue;
                },
            };

            zap.runtime.spawn(.{}, Client.run, .{ self, notifier, conn.socket, conn.address }) catch |err| {
                log.err("Server - runtime.spawn(): {}", .{@errorName(err)});
                continue;
            };
        }
    }
};

pub fn run(notifier: *const pike.Notifier, signal: *pike.Signal, event: *pike.Event, stopped: *bool) !void {
    defer {
        stopped.* = true;
        event.post() catch {};
    }

    // Setup TCP server.

    var server = try Server.init();
    defer server.deinit();

    // Start the server, and await for an interrupt signal to gracefully shutdown
    // the server.

    try server.start(notifier, try net.Address.parseIp("0.0.0.0", 9000));
    try signal.wait();
}
