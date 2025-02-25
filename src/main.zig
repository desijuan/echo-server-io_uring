const std = @import("std");

const Allocator = std.mem.Allocator;
const Address = std.net.Address;
const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;

const BUFFER_SIZE = 512;

const ADDRESS = [4]u8{ 127, 0, 0, 1 };
const PORT = 8080;

const RecvData = struct {
    fd: i32,
    buffer: []u8,
};

const SendData = struct {
    fd: i32,
    str: []u8,
};

const Event = union(enum) {
    ACCEPT: void,
    RECV: RecvData,
    SEND: SendData,
    SEND_LAST: i32,
    CLOSE: void,

    fn freeData(self: *Event, allocator: Allocator) void {
        switch (self.*) {
            .RECV => |data| allocator.free(data.buffer),
            .SEND => |data| allocator.free(data.str),
            .ACCEPT, .SEND_LAST, .CLOSE => {},
        }
    }
};

const EventPool = std.heap.MemoryPool(Event);

var server_should_exit = std.atomic.Value(bool).init(false);

inline fn serverShouldExit() bool {
    return server_should_exit.load(.monotonic);
}

fn sig_handler(sig: c_int) callconv(.C) void {
    if (sig == posix.SIG.INT) {
        server_should_exit.store(true, .monotonic);
    }
}

pub fn main() !void {
    const sigaction = posix.Sigaction{
        .handler = .{ .handler = sig_handler },
        .mask = linux.empty_sigset,
        .flags = 0,
    };
    try posix.sigaction(posix.SIG.INT, &sigaction, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();

    var eventPool = EventPool.init(gpa.allocator());
    defer eventPool.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    var ring: IoUring = try IoUring.init(128, 0);
    defer ring.deinit();

    const addr: Address = Address.initIp4(ADDRESS, PORT);

    std.debug.print("Starting server at {}\n", .{addr});

    const server_fd: i32 = try posix.socket(linux.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer posix.close(server_fd);

    try posix.bind(server_fd, &addr.any, addr.getOsSockLen());

    try posix.listen(server_fd, 10);

    const acceptEvent: Event = .ACCEPT;
    _ = try ring.accept(@intFromPtr(&acceptEvent), server_fd, null, null, 0);

    while (!serverShouldExit()) {
        _ = ring.submit_and_wait(1) catch |err| switch (err) {
            error.SignalInterrupt => {},
            else => return err,
        };

        while (ring.cq_ready() > 0) {
            const cqe: linux.io_uring_cqe = try ring.copy_cqe();
            const event: *Event = @ptrFromInt(cqe.user_data);

            switch (event.*) {
                .ACCEPT => {
                    _ = try ring.accept(@intFromPtr(&acceptEvent), server_fd, null, null, 0);

                    std.debug.print("Client connected\n", .{});

                    const newEvent: *Event = try eventPool.create();

                    const client_fd: i32 = cqe.res;
                    const buffer: []u8 = try allocator.alloc(u8, BUFFER_SIZE);
                    newEvent.* = .{
                        .RECV = RecvData{ .fd = client_fd, .buffer = buffer },
                    };

                    _ = try ring.recv(@intFromPtr(newEvent), client_fd, .{ .buffer = buffer }, 0);
                },

                .RECV => |data| switch (cqe.err()) {
                    .SUCCESS => {
                        const nread: usize = @intCast(cqe.res);

                        if (nread <= 1) {
                            allocator.free(data.buffer);

                            event.* = .{ .SEND_LAST = data.fd };
                            _ = try ring.send(@intFromPtr(event), data.fd, "Goodbye!", 0);

                            continue;
                        }

                        std.debug.print(
                            "Received {} bytes from fd {}: '{s}'\n",
                            .{ nread, data.fd, data.buffer[0..nread] },
                        );

                        const str = data.buffer[0..nread];
                        const msg: []u8 = try allocator.alloc(u8, str.len);
                        @memcpy(msg, str);

                        allocator.free(data.buffer);

                        event.* = .{
                            .SEND = SendData{ .fd = data.fd, .str = msg },
                        };

                        _ = try ring.send(@intFromPtr(event), data.fd, msg, 0);
                    },

                    else => |err| std.debug.print(
                        "Recv from fd {} returned error {s}\n",
                        .{ data.fd, @tagName(err) },
                    ),
                },

                .SEND => |data| {
                    std.debug.print("{} bytes written.\n", .{cqe.res});

                    allocator.free(data.str);

                    const buffer: []u8 = try allocator.alloc(u8, BUFFER_SIZE);
                    event.* = .{
                        .RECV = RecvData{ .fd = data.fd, .buffer = buffer },
                    };

                    _ = try ring.recv(@intFromPtr(event), data.fd, .{ .buffer = buffer }, 0);
                },

                .SEND_LAST => |fd| {
                    std.debug.print("{} bytes written.\n", .{cqe.res});
                    event.* = .CLOSE;
                    _ = try ring.close(@intFromPtr(event), fd);
                },

                .CLOSE => {
                    std.debug.print("Client disconnected\n", .{});
                    event.freeData(allocator);
                    eventPool.destroy(event);
                },
            }
        }
    }

    std.debug.print("\nGoodbye!\n", .{});
}
