const std = @import("std");
const Io = std.Io;
const hegel = @import("hegel_zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const property = struct {
        fn run(tc: *hegel.TestCase) !void {
            const gen = try hegel.integers(i32, .{ .min_value = 0, .max_value = 100 });
            const value = try tc.draw(gen);
            if (value < 0) try tc.fail("non-negative generator produced a negative value");
        }
    }.run;

    var result = try hegel.check(allocator, property, .{ .test_cases = 25, .database = .disabled });
    defer result.deinit(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    switch (result) {
        .passed => |passed| try stdout.print("Hegel example passed {} cases\n", .{passed.test_cases}),
        .failed => |failure| try stdout.print("Hegel example failed: {s}\n", .{failure.message}),
        .run_error => |message| try stdout.print("Hegel example run error: {s}\n", .{message}),
    }
    try stdout.flush();
}

test "example property passes" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *hegel.TestCase) !void {
            const gen = try hegel.integers(i32, .{ .min_value = 0, .max_value = 10 });
            const value = try tc.draw(gen);
            if (value < 0 or value > 10) try tc.fail("bounded integer out of range");
        }
    }.run;
    var result = try hegel.check(allocator, property, .{ .test_cases = 10, .seed = 3, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}
