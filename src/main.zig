const std = @import("std");

const Allocator = std.mem.Allocator;
const Address = std.net.Address;
const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;

const BUFFER_SIZE = 512;

const ADDRESS = [4]u8{ 127, 0, 0, 1 };
const PORT = 8080;

const Sock = struct {
    addr: posix.sockaddr,
    addr_len: posix.socklen_t,
};

const RecvData = struct {
    fd: i32,
    buffer: []u8,
};

const SendData = struct {
    fd: i32,
    str: []u8,
};

const Event = union(enum) {
    ACCEPT: Sock,
    RECV: RecvData,
    SEND: SendData,
    CLOSE: i32,

    fn freeData(self: *Event, allocator: Allocator) void {
        switch (self.*) {
            .RECV => |data| allocator.free(data.buffer),
            .SEND => |data| allocator.free(data.str),
            .ACCEPT, .CLOSE => {},
        }
    }
};

const EventPool = std.heap.MemoryPool(Event);

var server_should_exit = std.atomic.Value(bool).init(false);

inline fn serverShouldExit() bool {
    return server_should_exit.load(.monotonic);
}

fn sig_handler(sig: c_int) callconv(.C) void {
    if (sig == posix.SIG.INT)
        server_should_exit.store(true, .monotonic);
}

inline fn printInfo(T: type) void {
    std.debug.print("{s} size: {}, align: {}\n", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}

pub fn main() !void {
    const sigaction = posix.Sigaction{
        .handler = .{ .handler = sig_handler },
        .mask = linux.empty_sigset,
        .flags = 0,
    };
    try posix.sigaction(posix.SIG.INT, &sigaction, null);

    var gpa_instance = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa_instance.deinit();

    const gpa = gpa_instance.allocator();

    var eventPool = EventPool.init(gpa);
    defer eventPool.deinit();

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();

    const arena = arena_instance.allocator();

    var ring: IoUring = try IoUring.init(128, 0);
    defer ring.deinit();

    const server_addr: Address = Address.initIp4(ADDRESS, PORT);

    std.debug.print("Starting server at {}.\n", .{server_addr});

    const server_fd: i32 = try posix.socket(linux.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
    defer posix.close(server_fd);

    try posix.bind(server_fd, &server_addr.any, server_addr.getOsSockLen());

    try posix.listen(server_fd, 10);

    var acceptEvent: Event = .{
        .ACCEPT = Sock{ .addr = undefined, .addr_len = @sizeOf(posix.sockaddr) },
    };
    _ = try ring.accept(@intFromPtr(&acceptEvent), server_fd, &acceptEvent.ACCEPT.addr, &acceptEvent.ACCEPT.addr_len, 0);

    while (!serverShouldExit()) {
        _ = ring.submit_and_wait(1) catch |err| switch (err) {
            error.SignalInterrupt => {},
            else => return err,
        };

        while (ring.cq_ready() > 0) {
            const cqe: linux.io_uring_cqe = try ring.copy_cqe();
            const event: *Event = @ptrFromInt(cqe.user_data);

            switch (event.*) {
                .ACCEPT => |sock| switch (cqe.err()) {
                    .SUCCESS => {
                        const addr: std.net.Address = std.net.Address.initPosix(@alignCast(&sock.addr));

                        acceptEvent.ACCEPT.addr_len = @sizeOf(posix.sockaddr);

                        _ = try ring.accept(
                            @intFromPtr(&acceptEvent),
                            server_fd,
                            &acceptEvent.ACCEPT.addr,
                            &acceptEvent.ACCEPT.addr_len,
                            0,
                        );

                        const fd: i32 = cqe.res;

                        std.debug.print("Client connected. Opened fd {} @ {}.\n", .{ fd, addr });

                        const newEvent: *Event = try eventPool.create();
                        const buffer: []u8 = try arena.alloc(u8, BUFFER_SIZE);
                        newEvent.* = .{
                            .RECV = RecvData{ .fd = fd, .buffer = buffer },
                        };

                        _ = try ring.recv(@intFromPtr(newEvent), fd, .{ .buffer = buffer }, 0);
                    },

                    else => |err| std.debug.print(
                        "Accept returned error {s}.\n",
                        .{@tagName(err)},
                    ),
                },

                .RECV => |data| switch (cqe.err()) {
                    .SUCCESS => {
                        const nread: usize = @intCast(cqe.res);

                        if (nread < 1) {
                            arena.free(data.buffer);

                            event.* = .{
                                .CLOSE = data.fd,
                            };
                            _ = try ring.close(@intFromPtr(event), data.fd);

                            continue;
                        }

                        std.debug.print(
                            "Received {} bytes from fd {}: '{s}'.\n",
                            .{ nread, data.fd, data.buffer[0..nread] },
                        );

                        const str = data.buffer[0..nread];
                        const msg: []u8 = try arena.alloc(u8, str.len);
                        @memcpy(msg, str);

                        arena.free(data.buffer);

                        event.* = .{
                            .SEND = SendData{ .fd = data.fd, .str = msg },
                        };

                        _ = try ring.send(@intFromPtr(event), data.fd, msg, 0);
                    },

                    else => |err| {
                        std.debug.print(
                            "Recv from fd {} returned error {s}.\n",
                            .{ data.fd, @tagName(err) },
                        );

                        arena.free(data.buffer);

                        event.* = .{
                            .CLOSE = data.fd,
                        };
                        _ = try ring.close(@intFromPtr(event), data.fd);
                    },
                },

                .SEND => |data| switch (cqe.err()) {
                    .SUCCESS => {
                        std.debug.print("{} bytes written to fd {}.\n", .{ cqe.res, data.fd });

                        arena.free(data.str);

                        const buffer: []u8 = try arena.alloc(u8, BUFFER_SIZE);
                        event.* = .{
                            .RECV = RecvData{ .fd = data.fd, .buffer = buffer },
                        };

                        _ = try ring.recv(@intFromPtr(event), data.fd, .{ .buffer = buffer }, 0);
                    },

                    else => |err| {
                        std.debug.print(
                            "Send to fd {} returned error {s}.\n",
                            .{ data.fd, @tagName(err) },
                        );

                        arena.free(data.str);

                        event.* = .{
                            .CLOSE = data.fd,
                        };
                        _ = try ring.close(@intFromPtr(event), data.fd);
                    },
                },

                .CLOSE => |fd| {
                    event.freeData(arena);
                    eventPool.destroy(event);

                    switch (cqe.err()) {
                        .SUCCESS => std.debug.print("Client disconnected. Closed fd {}.\n", .{fd}),

                        else => |err| std.debug.print(
                            "Close fd {} returned error {s}.\n",
                            .{ fd, @tagName(err) },
                        ),
                    }
                },
            }
        }
    }

    std.debug.print("\nGoodbye!\n", .{});
}
