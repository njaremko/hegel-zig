const std = @import("std");
const c = @import("c.zig");

pub const Error = error{
    StopTest,
    AssumptionRejected,
    Backend,
    InvalidHandle,
    InvalidArgument,
    AlreadyComplete,
    NotComplete,
    Internal,
    UnknownReturnCode,
    OutOfMemory,
};

pub fn check(ctx: ?*c.context_t, rc: c.result_t) Error!void {
    _ = ctx;
    switch (rc) {
        c.OK => return,
        c.E_STOP_TEST => return Error.StopTest,
        c.E_ASSUME => return Error.AssumptionRejected,
        c.E_BACKEND => return Error.Backend,
        c.E_INVALID_HANDLE => return Error.InvalidHandle,
        c.E_INVALID_ARG => return Error.InvalidArgument,
        c.E_ALREADY_COMPLETE => return Error.AlreadyComplete,
        c.E_NOT_COMPLETE => return Error.NotComplete,
        c.E_INTERNAL => return Error.Internal,
        else => return Error.UnknownReturnCode,
    }
}

pub fn lastErrorAlloc(allocator: std.mem.Allocator, ctx: ?*c.context_t) Error![]u8 {
    const msg = c.hegel_context_last_error(ctx) orelse return allocator.dupe(u8, "") catch Error.OutOfMemory;
    return allocator.dupe(u8, std.mem.span(msg)) catch Error.OutOfMemory;
}

pub const Context = struct {
    ptr: *c.context_t,

    pub fn init() Error!Context {
        const ptr = c.hegel_context_new() orelse return Error.InvalidHandle;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Context) void {
        _ = c.hegel_context_free(self.ptr);
        self.ptr = undefined;
    }
};

pub const SettingsHandle = struct {
    ctx: *c.context_t,
    ptr: *c.settings_t,

    pub fn init(ctx: *c.context_t) Error!SettingsHandle {
        var out: ?*c.settings_t = null;
        try check(ctx, c.hegel_settings_new(ctx, &out));
        return .{ .ctx = ctx, .ptr = out orelse return Error.InvalidHandle };
    }

    pub fn deinit(self: *SettingsHandle) void {
        _ = c.hegel_settings_free(self.ctx, self.ptr);
        self.ptr = undefined;
    }
};

pub const Run = struct {
    ctx: *c.context_t,
    ptr: *c.run_t,

    pub fn start(ctx: *c.context_t, settings: *c.settings_t) Error!Run {
        var out: ?*c.run_t = null;
        try check(ctx, c.hegel_run_start(ctx, settings, &out));
        return .{ .ctx = ctx, .ptr = out orelse return Error.InvalidHandle };
    }

    pub fn deinit(self: *Run) void {
        _ = c.hegel_run_free(self.ctx, self.ptr);
        self.ptr = undefined;
    }

    pub fn next(self: *Run) Error!?*c.test_case_t {
        var out: ?*c.test_case_t = null;
        try check(self.ctx, c.hegel_next_test_case(self.ctx, self.ptr, &out));
        return out;
    }

    pub fn result(self: *Run) Error!*const c.run_result_t {
        var out: ?*const c.run_result_t = null;
        try check(self.ctx, c.hegel_run_result(self.ctx, self.ptr, &out));
        return out orelse return Error.InvalidHandle;
    }
};

pub const OwnedTestCase = struct {
    ctx: *c.context_t,
    ptr: *c.test_case_t,

    pub fn fromBlob(ctx: *c.context_t, settings: *const c.settings_t, blob: [*:0]const u8) Error!OwnedTestCase {
        var out: ?*c.test_case_t = null;
        try check(ctx, c.hegel_test_case_from_blob(ctx, settings, blob, &out));
        return .{ .ctx = ctx, .ptr = out orelse return Error.InvalidHandle };
    }

    pub fn deinit(self: *OwnedTestCase) void {
        _ = c.hegel_test_case_free(self.ctx, self.ptr);
        self.ptr = undefined;
    }
};

pub fn markComplete(
    ctx: *c.context_t,
    tc: *c.test_case_t,
    status: c_int,
    origin: ?[*:0]const u8,
) Error!void {
    try check(ctx, c.hegel_mark_complete(ctx, tc, status, origin));
}

pub fn runStatus(ctx: *c.context_t, result: *const c.run_result_t) Error!c_int {
    var status: c_int = c.RUN_STATUS_PASSED;
    try check(ctx, c.hegel_run_result_status(ctx, result, &status));
    return status;
}

pub fn runErrorAlloc(
    allocator: std.mem.Allocator,
    ctx: *c.context_t,
    result: *const c.run_result_t,
) Error![]u8 {
    var out: ?[*:0]const u8 = null;
    try check(ctx, c.hegel_run_result_error(ctx, result, &out));
    const msg = out orelse return allocator.dupe(u8, "unknown error") catch Error.OutOfMemory;
    return allocator.dupe(u8, std.mem.span(msg)) catch Error.OutOfMemory;
}

pub fn failureCount(ctx: *c.context_t, result: *const c.run_result_t) Error!usize {
    var count: usize = 0;
    try check(ctx, c.hegel_run_result_failure_count(ctx, result, &count));
    return count;
}

pub fn failureAt(
    ctx: *c.context_t,
    result: *const c.run_result_t,
    index: usize,
) Error!*const c.failure_t {
    var out: ?*const c.failure_t = null;
    try check(ctx, c.hegel_run_result_failure(ctx, result, index, &out));
    return out orelse return Error.InvalidHandle;
}

pub fn failureBlob(ctx: *c.context_t, failure: *const c.failure_t) Error!?[*:0]const u8 {
    var out: ?[*:0]const u8 = null;
    try check(ctx, c.hegel_failure_reproduction_blob(ctx, failure, &out));
    return out;
}

pub fn versionAlloc(allocator: std.mem.Allocator) Error![]u8 {
    var out: ?[*:0]const u8 = null;
    try check(null, c.hegel_version(null, &out));
    const version = out orelse return Error.InvalidHandle;
    return allocator.dupe(u8, std.mem.span(version)) catch Error.OutOfMemory;
}
