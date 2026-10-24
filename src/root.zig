//! Hegel for Zig: property-based tests driven by Hegel's native engine.

const std = @import("std");
const c = @import("c.zig");
const ffi = @import("ffi.zig");
const cbor = @import("cbor.zig");

pub const HegelError = error{
    AssumptionFailed,
    StopTest,
    PropertyFailed,
    InvalidArgument,
    Backend,
    InvalidHandle,
    AlreadyComplete,
    NotComplete,
    Internal,
    UnknownReturnCode,
    UnexpectedEngineValue,
    UnsupportedType,
    OutOfMemory,
};

pub const Verbosity = enum {
    quiet,
    normal,
    verbose,
    debug,
};

pub const HealthCheck = enum {
    filter_too_much,
    too_slow,
    test_cases_too_large,
    large_initial_test_case,
};

pub const allHealthChecks = [_]HealthCheck{
    .filter_too_much,
    .too_slow,
    .test_cases_too_large,
    .large_initial_test_case,
};

pub fn verbosityToString(verbosity: Verbosity) []const u8 {
    return switch (verbosity) {
        .quiet => "quiet",
        .normal => "normal",
        .verbose => "verbose",
        .debug => "debug",
    };
}

pub fn healthCheckToString(health_check: HealthCheck) []const u8 {
    return switch (health_check) {
        .filter_too_much => "filter_too_much",
        .too_slow => "too_slow",
        .test_cases_too_large => "test_cases_too_large",
        .large_initial_test_case => "large_initial_test_case",
    };
}

pub const Database = union(enum) {
    unset,
    disabled,
    path: []const u8,
};

pub const Phases = struct {
    explicit: bool = true,
    reuse: bool = true,
    generate: bool = true,
    target: bool = true,
    shrink: bool = true,

    pub fn all() Phases {
        return .{};
    }

    pub fn mask(self: Phases) u32 {
        var result: u32 = 0;
        if (self.explicit) result |= c.PHASE_EXPLICIT;
        if (self.reuse) result |= c.PHASE_REUSE;
        if (self.generate) result |= c.PHASE_GENERATE;
        if (self.target) result |= c.PHASE_TARGET;
        if (self.shrink) result |= c.PHASE_SHRINK;
        return result;
    }
};

pub const Settings = struct {
    test_cases: ?u64 = null,
    verbosity: Verbosity = .normal,
    seed: ?u64 = null,
    derandomize: ?bool = null,
    database: Database = .disabled,
    database_key: ?[]const u8 = null,
    phases: Phases = .{},
    suppress_health_checks: []const HealthCheck = &.{},
    report_multiple_failures: bool = false,

    pub fn default() Settings {
        return .{};
    }
};

pub const Passed = struct {
    test_cases: u64,
};

pub const FailureReport = struct {
    message: []u8,
    generated: [][]u8,
    notes: [][]u8,
    failure_count: usize = 1,

    pub fn deinit(self: *FailureReport, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        for (self.generated) |item| allocator.free(item);
        allocator.free(self.generated);
        for (self.notes) |note_text| allocator.free(note_text);
        allocator.free(self.notes);
        self.* = .{ .message = &.{}, .generated = &.{}, .notes = &.{}, .failure_count = 0 };
    }
};

pub const CheckResult = union(enum) {
    passed: Passed,
    failed: FailureReport,
    run_error: []u8,

    pub fn deinit(self: *CheckResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .passed => {},
            .failed => |*report| report.deinit(allocator),
            .run_error => |message| allocator.free(message),
        }
        self.* = .{ .passed = .{ .test_cases = 0 } };
    }
};

pub const TestCase = struct {
    allocator: std.mem.Allocator,
    ctx: *c.context_t,
    tc: *c.test_case_t,
    is_final: bool,
    verbosity: Verbosity,
    generated: std.ArrayList([]u8) = .empty,
    notes: std.ArrayList([]u8) = .empty,
    failure_message: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *c.context_t,
        tc: *c.test_case_t,
        is_final: bool,
        verbosity: Verbosity,
    ) TestCase {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .tc = tc,
            .is_final = is_final,
            .verbosity = verbosity,
        };
    }

    pub fn deinit(self: *TestCase) void {
        for (self.generated.items) |item| self.allocator.free(item);
        self.generated.deinit(self.allocator);
        for (self.notes.items) |note_text| self.allocator.free(note_text);
        self.notes.deinit(self.allocator);
        if (self.failure_message) |message| self.allocator.free(message);
        self.* = undefined;
    }

    pub fn draw(self: *TestCase, generator: anytype) !@TypeOf(generator).Value {
        return generator.draw(self);
    }

    pub fn assume(self: *TestCase, condition: bool) HegelError!void {
        _ = self;
        if (!condition) return HegelError.AssumptionFailed;
    }

    pub fn fail(self: *TestCase, message: []const u8) HegelError!void {
        const next = try self.allocator.dupe(u8, message);
        if (self.failure_message) |old| self.allocator.free(old);
        self.failure_message = next;
        return HegelError.PropertyFailed;
    }

    pub fn note(self: *TestCase, message: []const u8) HegelError!void {
        if (!self.shouldKeepLog()) return;
        const copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(copy);
        try self.notes.append(self.allocator, copy);
    }

    pub fn target(self: *TestCase, label: [*:0]const u8, value: f64) HegelError!void {
        if (!std.math.isFinite(value)) return HegelError.InvalidArgument;
        ffi.check(self.ctx, c.hegel_target(self.ctx, self.tc, value, label)) catch |err| return mapFfiError(err);
    }

    fn generate(self: *TestCase, writer: anytype) HegelError!cbor.Value {
        var schema_bytes: std.ArrayList(u8) = .empty;
        defer schema_bytes.deinit(self.allocator);
        var encoder = cbor.Encoder.init(self.allocator, &schema_bytes);
        writer.writeSchema(&encoder) catch |err| return mapCborError(err);

        var out_value: ?[*]const u8 = null;
        var out_len: usize = 0;
        const rc = c.hegel_generate(
            self.ctx,
            self.tc,
            schema_bytes.items.ptr,
            schema_bytes.items.len,
            &out_value,
            &out_len,
        );
        ffi.check(self.ctx, rc) catch |err| return mapFfiError(err);
        const ptr = out_value orelse return HegelError.Backend;
        var value = cbor.decode(self.allocator, ptr[0..out_len]) catch |err| return mapCborError(err);
        errdefer value.deinit(self.allocator);
        if (self.shouldKeepLog()) {
            var rendered: std.ArrayList(u8) = .empty;
            errdefer rendered.deinit(self.allocator);
            cbor.appendJson(self.allocator, &rendered, value) catch |err| return mapCborError(err);
            const owned = try rendered.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(owned);
            try self.generated.append(self.allocator, owned);
        }
        return value;
    }

    fn shouldKeepLog(self: TestCase) bool {
        return switch (self.verbosity) {
            .quiet => false,
            .normal => self.is_final,
            .verbose, .debug => true,
        };
    }
};

pub fn check(
    allocator: std.mem.Allocator,
    comptime body: anytype,
    settings: Settings,
) HegelError!CheckResult {
    var context = ffi.Context.init() catch |err| return mapFfiError(err);
    defer context.deinit();

    var native_settings = ffi.SettingsHandle.init(context.ptr) catch |err| return mapFfiError(err);
    defer native_settings.deinit();
    try applySettings(allocator, context.ptr, native_settings.ptr, settings);

    var run = ffi.Run.start(context.ptr, native_settings.ptr) catch |err| return mapFfiError(err);
    defer run.deinit();

    var valid_cases: u64 = 0;
    while (true) {
        const tc_ptr = ffi.Run.next(&run) catch |err| return mapFfiError(err);
        const native_tc = tc_ptr orelse break;
        var tc = TestCase.init(allocator, context.ptr, native_tc, false, settings.verbosity);
        defer tc.deinit();
        const outcome = runBody(body, &tc);
        if (outcome.status == c.STATUS_VALID) valid_cases += 1;
        try checkRc(context.ptr, c.hegel_mark_complete(context.ptr, native_tc, outcome.status, outcome.origin));
    }

    const result = ffi.Run.result(&run) catch |err| return mapFfiError(err);
    const status = ffi.runStatus(context.ptr, result) catch |err| return mapFfiError(err);
    switch (status) {
        c.RUN_STATUS_PASSED => return .{ .passed = .{ .test_cases = valid_cases } },
        c.RUN_STATUS_ERROR => {
            const message = ffi.runErrorAlloc(allocator, context.ptr, result) catch |err| return mapFfiError(err);
            return .{ .run_error = message };
        },
        c.RUN_STATUS_FAILED => return replayFirstFailure(
            allocator,
            body,
            context.ptr,
            native_settings.ptr,
            result,
            settings.verbosity,
        ),
        else => return HegelError.Backend,
    }
}

pub fn testProperty(
    allocator: std.mem.Allocator,
    comptime body: anytype,
    settings: Settings,
) HegelError!void {
    var result = try check(allocator, body, settings);
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        .failed => return HegelError.PropertyFailed,
        .run_error => return HegelError.Backend,
    }
}

const BodyOutcome = struct {
    status: c_int,
    origin: ?[*:0]const u8 = null,
};

fn runBody(comptime body: anytype, tc: *TestCase) BodyOutcome {
    body(tc) catch |err| {
        const any_error: anyerror = err;
        return switch (any_error) {
            error.AssumptionFailed => .{ .status = c.STATUS_INVALID },
            error.StopTest => .{ .status = c.STATUS_OVERRUN },
            else => .{ .status = c.STATUS_INTERESTING, .origin = "zig_property_failure" },
        };
    };
    return .{ .status = c.STATUS_VALID };
}

fn replayFirstFailure(
    allocator: std.mem.Allocator,
    comptime body: anytype,
    ctx: *c.context_t,
    settings: *c.settings_t,
    result: *const c.run_result_t,
    verbosity: Verbosity,
) HegelError!CheckResult {
    const count = ffi.failureCount(ctx, result) catch |err| return mapFfiError(err);
    if (count == 0) return HegelError.Backend;
    const failure = ffi.failureAt(ctx, result, 0) catch |err| return mapFfiError(err);
    const blob = (ffi.failureBlob(ctx, failure) catch |err| return mapFfiError(err)) orelse return HegelError.Backend;

    var owned = ffi.OwnedTestCase.fromBlob(ctx, settings, blob) catch |err| return mapFfiError(err);
    defer owned.deinit();

    var tc = TestCase.init(allocator, ctx, owned.ptr, true, verbosity);
    defer tc.deinit();
    const outcome = runBody(body, &tc);
    try checkRc(ctx, c.hegel_mark_complete(ctx, owned.ptr, outcome.status, outcome.origin));
    if (outcome.status != c.STATUS_INTERESTING) {
        const message = try allocator.dupe(u8, "Flaky test detected: replay did not reproduce the failure");
        return .{ .run_error = message };
    }

    const message = if (tc.failure_message) |m|
        try allocator.dupe(u8, m)
    else
        try allocator.dupe(u8, "Hegel test failed");
    errdefer allocator.free(message);

    const generated = try tc.generated.toOwnedSlice(allocator);
    errdefer {
        for (generated) |item| allocator.free(item);
        allocator.free(generated);
    }
    tc.generated = .empty;
    const notes = try tc.notes.toOwnedSlice(allocator);
    errdefer {
        for (notes) |note_text| allocator.free(note_text);
        allocator.free(notes);
    }
    tc.notes = .empty;

    return .{ .failed = .{ .message = message, .generated = generated, .notes = notes, .failure_count = count } };
}

fn applySettings(
    allocator: std.mem.Allocator,
    ctx: *c.context_t,
    settings_handle: *c.settings_t,
    settings: Settings,
) HegelError!void {
    const test_cases = settings.test_cases orelse 100;
    try checkRc(ctx, c.hegel_settings_set_test_cases(ctx, settings_handle, test_cases));
    // Zig callers receive diagnostics through CheckResult. Keep the native
    // engine quiet so library calls do not perform hidden stderr I/O.
    try checkRc(ctx, c.hegel_settings_set_verbosity(ctx, settings_handle, c.VERBOSITY_QUIET));
    try checkRc(ctx, c.hegel_settings_set_seed(
        ctx,
        settings_handle,
        settings.seed orelse 0,
        settings.seed != null,
    ));
    try checkRc(ctx, c.hegel_settings_set_derandomize(
        ctx,
        settings_handle,
        settings.derandomize orelse inCi(),
    ));
    try checkRc(ctx, c.hegel_settings_set_report_multiple_failures(
        ctx,
        settings_handle,
        settings.report_multiple_failures,
    ));
    try checkRc(ctx, c.hegel_settings_set_phases(ctx, settings_handle, settings.phases.mask()));

    switch (settings.database) {
        .unset => {},
        .disabled => try checkRc(ctx, c.hegel_settings_set_database(ctx, settings_handle, "")),
        .path => |path| {
            const z_path = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(z_path);
            try checkRc(ctx, c.hegel_settings_set_database(ctx, settings_handle, z_path.ptr));
        },
    }

    if (settings.database_key) |key| {
        const z_key = try allocator.dupeSentinel(u8, key, 0);
        defer allocator.free(z_key);
        try checkRc(ctx, c.hegel_settings_set_database_key(ctx, settings_handle, z_key.ptr));
    }

    const suppress = healthMask(settings.suppress_health_checks);
    if (suppress != 0) {
        try checkRc(ctx, c.hegel_settings_set_suppress_health_check(ctx, settings_handle, suppress));
    }
}

fn checkRc(ctx: *c.context_t, rc: c.result_t) HegelError!void {
    ffi.check(ctx, rc) catch |err| return mapFfiError(err);
}

fn nativeVerbosity(verbosity: Verbosity) c_int {
    return switch (verbosity) {
        .quiet => c.VERBOSITY_QUIET,
        .normal => c.VERBOSITY_NORMAL,
        .verbose => c.VERBOSITY_VERBOSE,
        .debug => c.VERBOSITY_DEBUG,
    };
}

fn healthMask(checks: []const HealthCheck) u32 {
    var mask: u32 = 0;
    for (checks) |health_check| {
        mask |= switch (health_check) {
            .filter_too_much => c.HC_FILTER_TOO_MUCH,
            .too_slow => c.HC_TOO_SLOW,
            .test_cases_too_large => c.HC_TEST_CASES_TOO_LARGE,
            .large_initial_test_case => c.HC_LARGE_INITIAL_TEST_CASE,
        };
    }
    return mask;
}

fn inCi() bool {
    if (envPresent("CI")) return true;
    if (envPresent("GITLAB_CI")) return true;
    if (envPresent("CODEBUILD_BUILD_ID")) return true;
    if (envPresent("HEROKU_TEST_RUN_ID")) return true;
    if (envPresent("TEAMCITY_VERSION")) return true;
    if (envTrue("TF_BUILD")) return true;
    if (envTrue("BUILDKITE")) return true;
    if (envTrue("CIRCLECI")) return true;
    if (envTrue("CIRRUS_CI")) return true;
    if (envTrue("GITHUB_ACTIONS")) return true;
    return false;
}

fn envPresent(comptime name: [:0]const u8) bool {
    return std.c.getenv(name) != null;
}

fn envTrue(comptime name: [:0]const u8) bool {
    const value_ptr = std.c.getenv(name) orelse return false;
    const value = std.mem.span(value_ptr);
    return std.ascii.eqlIgnoreCase(value, "true");
}

fn mapFfiError(err: ffi.Error) HegelError {
    return switch (err) {
        error.StopTest => HegelError.StopTest,
        error.AssumptionRejected => HegelError.AssumptionFailed,
        error.Backend => HegelError.Backend,
        error.InvalidHandle => HegelError.InvalidHandle,
        error.InvalidArgument => HegelError.InvalidArgument,
        error.AlreadyComplete => HegelError.AlreadyComplete,
        error.NotComplete => HegelError.NotComplete,
        error.Internal => HegelError.Internal,
        error.UnknownReturnCode => HegelError.UnknownReturnCode,
        error.OutOfMemory => HegelError.OutOfMemory,
    };
}

fn mapCborError(err: cbor.Error) HegelError {
    return switch (err) {
        error.OutOfMemory => HegelError.OutOfMemory,
        error.UnexpectedEnd, error.InvalidCbor, error.UnsupportedCbor => HegelError.UnexpectedEngineValue,
    };
}

fn mapAllocatorError(err: error{OutOfMemory}) HegelError {
    return switch (err) {
        error.OutOfMemory => HegelError.OutOfMemory,
    };
}

fn hasMethod(comptime T: type, comptime name: []const u8) bool {
    return @hasDecl(T, name);
}

fn isSchemaBacked(comptime Gen: type) bool {
    if (@hasDecl(Gen, "schema_backed")) return Gen.schema_backed;
    return hasMethod(Gen, "writeSchema") and generatedValueParsable(Gen);
}

fn generatedValueParsable(comptime Gen: type) bool {
    if (hasMethod(Gen, "parseValue")) return true;
    const T = Gen.Value;
    return switch (@typeInfo(T)) {
        .bool, .int, .float => true,
        .pointer => |ptr| ptr.size == .slice and ptr.child == u8,
        else => false,
    };
}

fn preservesEquality(comptime Gen: type) bool {
    if (@hasDecl(Gen, "preserves_equality")) return Gen.preserves_equality;
    return false;
}

fn attemptsBound(count: usize, multiplier: usize) HegelError!usize {
    if (count == 0) return 0;
    return std.math.mul(usize, count, multiplier) catch HegelError.InvalidArgument;
}

fn typeNeedsDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.size == .slice,
        .optional => |opt| typeNeedsDeinit(opt.child),
        .error_union => |err_union| typeNeedsDeinit(err_union.payload),
        .array => |array| typeNeedsDeinit(array.child),
        .@"struct" => |s| blk: {
            inline for (s.field_types) |field_type| {
                if (typeNeedsDeinit(field_type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |u| blk: {
            inline for (u.field_types) |field_type| {
                if (typeNeedsDeinit(field_type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn typeContainsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |opt| typeContainsPointer(opt.child),
        .error_union => |err_union| typeContainsPointer(err_union.payload),
        .array => |array| typeContainsPointer(array.child),
        .@"struct" => |s| blk: {
            inline for (s.field_types) |field_type| {
                if (typeContainsPointer(field_type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |u| blk: {
            inline for (u.field_types) |field_type| {
                if (typeContainsPointer(field_type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn typeIsPlainData(comptime T: type) bool {
    return !typeContainsPointer(T);
}

fn generatedEqual(comptime T: type, left: T, right: T) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                if (left.len != right.len) break :blk false;
                for (left, right) |left_item, right_item| {
                    if (!generatedEqual(ptr.child, left_item, right_item)) break :blk false;
                }
                break :blk true;
            }
            break :blk left == right;
        },
        .optional => {
            if (left == null and right == null) return true;
            if (left == null or right == null) return false;
            return generatedEqual(@TypeOf(left.?), left.?, right.?);
        },
        .error_union => |err_union| {
            if (left) |left_payload| {
                if (right) |right_payload| {
                    return generatedEqual(err_union.payload, left_payload, right_payload);
                } else |_| {
                    return false;
                }
            } else |left_error| {
                if (right) |_| {
                    return false;
                } else |right_error| {
                    return left_error == right_error;
                }
            }
        },
        .array => |array| blk: {
            for (left, right) |left_item, right_item| {
                if (!generatedEqual(array.child, left_item, right_item)) break :blk false;
            }
            break :blk true;
        },
        .@"struct" => |s| blk: {
            inline for (s.field_names, s.field_types) |field_name, field_type| {
                if (!generatedEqual(field_type, @field(left, field_name), @field(right, field_name))) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .@"union" => |u| blk: {
            if (u.tag_type) |_| {
                if (std.meta.activeTag(left) != std.meta.activeTag(right)) break :blk false;
                switch (left) {
                    inline else => |payload, tag| {
                        const name = @tagName(tag);
                        break :blk generatedEqual(@TypeOf(payload), payload, @field(right, name));
                    },
                }
            }
            break :blk false;
        },
        else => std.meta.eql(left, right),
    };
}

pub fn deinitValue(generator: anytype, allocator: std.mem.Allocator, value: anytype) void {
    rootDeinitValue(generator, allocator, value);
}

fn rootDeinitValue(generator: anytype, allocator: std.mem.Allocator, value: anytype) void {
    const Gen = @TypeOf(generator);
    if (comptime hasMethod(Gen, "deinitValue")) {
        generator.deinitValue(allocator, value);
    } else {
        defaultDeinitValue(allocator, value);
    }
}

fn defaultDeinitValue(allocator: std.mem.Allocator, value: anytype) void {
    const Ptr = @TypeOf(value);
    const info = @typeInfo(Ptr);
    if (info != .pointer) @compileError("deinitValue expects a pointer to a generated value");
    const T = info.pointer.child;
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                if (ptr.child == u8) {
                    allocator.free(value.*);
                } else {
                    for (value.*) |*item| defaultDeinitValue(allocator, item);
                    allocator.free(value.*);
                }
            }
        },
        .optional => {
            if (value.*) |*inner| defaultDeinitValue(allocator, inner);
        },
        .error_union => {
            if (value.*) |*payload| defaultDeinitValue(allocator, payload) else |_| {}
        },
        .array => {
            for (&value.*) |*item| defaultDeinitValue(allocator, item);
        },
        .@"struct" => |s| {
            inline for (s.field_names) |field_name| {
                defaultDeinitValue(allocator, &@field(value.*, field_name));
            }
        },
        .@"union" => |u| {
            if (u.tag_type) |_| {
                switch (value.*) {
                    inline else => |*payload| defaultDeinitValue(allocator, payload),
                }
            }
        },
        else => {},
    }
}

pub fn IntegerParams(comptime T: type) type {
    return struct {
        min_value: ?T = null,
        max_value: ?T = null,
    };
}

pub fn integers(comptime T: type, params: IntegerParams(T)) HegelError!IntegerGenerator(T) {
    comptime {
        if (T == bool) @compileError("use booleans() for bool values");
        if (@typeInfo(T) == .comptime_int) @compileError("integers() requires an explicitly sized integer type");
        if (@typeInfo(T) != .int) {
            @compileError("integers() requires an integer type");
        }
        if (@typeInfo(T).int.bits > 64) @compileError("integers() supports integer widths up to 64 bits");
    }
    const min_value = params.min_value orelse std.math.minInt(T);
    const max_value = params.max_value orelse std.math.maxInt(T);
    if (min_value > max_value) return HegelError.InvalidArgument;
    return .{ .min_value = min_value, .max_value = max_value };
}

pub fn IntegerGenerator(comptime T: type) type {
    return struct {
        pub const Value = T;
        pub const preserves_equality = true;
        min_value: T,
        max_value: T,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!T {
            var value = try tc.generate(self);
            defer value.deinit(tc.allocator);
            return parseInteger(T, value);
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            try encoder.map(3);
            try encoder.fieldText("type", "integer");
            try encoder.text("min_value");
            try writeZigInteger(encoder, self.min_value);
            try encoder.text("max_value");
            try writeZigInteger(encoder, self.max_value);
        }
    };
}

fn writeZigInteger(encoder: *cbor.Encoder, value: anytype) cbor.Error!void {
    const T = @TypeOf(value);
    if (@typeInfo(T).int.signedness == .unsigned) {
        try encoder.unsigned(@as(u64, @intCast(value)));
    } else {
        try encoder.signed(value);
    }
}

fn parseInteger(comptime T: type, value: cbor.Value) HegelError!T {
    switch (value) {
        .uint => |n| return std.math.cast(T, n) orelse HegelError.UnexpectedEngineValue,
        .int => |n| return std.math.cast(T, n) orelse HegelError.UnexpectedEngineValue,
        else => return HegelError.UnexpectedEngineValue,
    }
}

pub fn FloatParams(comptime T: type) type {
    return struct {
        min_value: ?T = null,
        max_value: ?T = null,
        exclude_min: bool = false,
        exclude_max: bool = false,
        allow_nan: ?bool = null,
        allow_infinity: ?bool = null,
    };
}

pub fn floats(comptime T: type, params: FloatParams(T)) HegelError!FloatGenerator(T) {
    comptime if (@typeInfo(T) != .float) @compileError("floats() requires a float type");
    const has_min = params.min_value != null;
    const has_max = params.max_value != null;
    const allow_nan = params.allow_nan orelse (!has_min and !has_max);
    const allow_infinity = params.allow_infinity orelse (!has_min or !has_max);
    if (allow_nan and (has_min or has_max)) return HegelError.InvalidArgument;
    if (has_min and has_max and params.min_value.? > params.max_value.?) return HegelError.InvalidArgument;
    if (allow_infinity and has_min and has_max) return HegelError.InvalidArgument;
    return .{
        .min_value = params.min_value,
        .max_value = params.max_value,
        .exclude_min = params.exclude_min,
        .exclude_max = params.exclude_max,
        .allow_nan = allow_nan,
        .allow_infinity = allow_infinity,
    };
}

pub fn FloatGenerator(comptime T: type) type {
    return struct {
        pub const Value = T;
        pub const preserves_equality = true;
        min_value: ?T,
        max_value: ?T,
        exclude_min: bool,
        exclude_max: bool,
        allow_nan: bool,
        allow_infinity: bool,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!T {
            var value = try tc.generate(self);
            defer value.deinit(tc.allocator);
            return parseFloat(T, value);
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            var fields: u64 = 6;
            if (self.min_value != null) fields += 1;
            if (self.max_value != null) fields += 1;
            try encoder.map(fields);
            try encoder.fieldText("type", "float");
            try encoder.fieldBool("exclude_min", self.exclude_min);
            try encoder.fieldBool("exclude_max", self.exclude_max);
            try encoder.fieldBool("allow_nan", self.allow_nan);
            try encoder.fieldBool("allow_infinity", self.allow_infinity);
            try encoder.fieldUnsigned("width", @bitSizeOf(T));
            if (self.min_value) |min_value| try encoder.fieldFloat("min_value", @floatCast(min_value));
            if (self.max_value) |max_value| try encoder.fieldFloat("max_value", @floatCast(max_value));
        }
    };
}

fn parseFloat(comptime T: type, value: cbor.Value) HegelError!T {
    switch (value) {
        .float => |f| return @floatCast(f),
        .uint => |n| return @floatFromInt(n),
        .int => |n| return @floatFromInt(n),
        else => return HegelError.UnexpectedEngineValue,
    }
}

pub const BooleanGenerator = struct {
    pub const Value = bool;
    pub const preserves_equality = true;

    pub fn draw(self: BooleanGenerator, tc: *TestCase) HegelError!bool {
        var value = try tc.generate(self);
        defer value.deinit(tc.allocator);
        return switch (value) {
            .boolean => |b| b,
            else => HegelError.UnexpectedEngineValue,
        };
    }

    pub fn writeSchema(self: BooleanGenerator, encoder: *cbor.Encoder) cbor.Error!void {
        _ = self;
        try encoder.map(1);
        try encoder.fieldText("type", "boolean");
    }
};

pub fn booleans() BooleanGenerator {
    return .{};
}

pub fn JustGenerator(comptime T: type) type {
    return struct {
        pub const Value = T;
        pub const schema_backed = typeIsPlainData(T);
        pub const preserves_equality = false;
        value: T,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!T {
            var value = try tc.generate(self);
            defer value.deinit(tc.allocator);
            return self.value;
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            _ = self;
            if (comptime !typeIsPlainData(T)) @compileError("just() schema values must be plain data");
            try encoder.map(2);
            try encoder.fieldText("type", "constant");
            try encoder.text("value");
            try encoder.nil();
        }

        pub fn parseValue(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError!T {
            _ = allocator;
            _ = value;
            return self.value;
        }
    };
}

pub fn just(comptime T: type, value: T) JustGenerator(T) {
    comptime if (!typeIsPlainData(T)) @compileError("just() captured values must be plain data");
    return .{ .value = value };
}

pub const TextParams = struct {
    min_size: usize = 0,
    max_size: ?usize = null,
    codec: ?[]const u8 = null,
    min_codepoint: ?u32 = null,
    max_codepoint: ?u32 = null,
    categories: ?[]const []const u8 = null,
    exclude_categories: ?[]const []const u8 = null,
    include_characters: ?[]const u8 = null,
    exclude_characters: ?[]const u8 = null,
    alphabet: ?[]const u8 = null,
};

pub fn text(params: TextParams) HegelError!TextGenerator {
    if (params.max_size) |max_size| if (params.min_size > max_size) return HegelError.InvalidArgument;
    if (params.alphabet != null and hasCharParams(params)) return HegelError.InvalidArgument;
    return .{ .params = params };
}

pub const TextGenerator = struct {
    pub const Value = []u8;
    pub const preserves_equality = true;
    params: TextParams,

    pub fn draw(self: TextGenerator, tc: *TestCase) HegelError![]u8 {
        var value = try tc.generate(self);
        defer value.deinit(tc.allocator);
        return parseOwnedString(tc.allocator, value);
    }

    pub fn deinitValue(self: TextGenerator, allocator: std.mem.Allocator, value: *[]u8) void {
        _ = self;
        allocator.free(value.*);
    }

    pub fn writeSchema(self: TextGenerator, encoder: *cbor.Encoder) cbor.Error!void {
        try writeTextSchema(encoder, self.params, false);
    }
};

pub const CharactersParams = struct {
    codec: ?[]const u8 = null,
    min_codepoint: ?u32 = null,
    max_codepoint: ?u32 = null,
    categories: ?[]const []const u8 = null,
    exclude_categories: ?[]const []const u8 = null,
    include_characters: ?[]const u8 = null,
    exclude_characters: ?[]const u8 = null,
};

pub const CharactersGenerator = struct {
    pub const Value = []u8;
    pub const preserves_equality = true;
    params: CharactersParams,

    pub fn draw(self: CharactersGenerator, tc: *TestCase) HegelError![]u8 {
        var value = try tc.generate(self);
        defer value.deinit(tc.allocator);
        return parseOwnedString(tc.allocator, value);
    }

    pub fn deinitValue(self: CharactersGenerator, allocator: std.mem.Allocator, value: *[]u8) void {
        _ = self;
        allocator.free(value.*);
    }

    pub fn writeSchema(self: CharactersGenerator, encoder: *cbor.Encoder) cbor.Error!void {
        const text_params = TextParams{
            .min_size = 1,
            .max_size = 1,
            .codec = self.params.codec,
            .min_codepoint = self.params.min_codepoint,
            .max_codepoint = self.params.max_codepoint,
            .categories = self.params.categories,
            .exclude_categories = self.params.exclude_categories,
            .include_characters = self.params.include_characters,
            .exclude_characters = self.params.exclude_characters,
        };
        try writeTextSchema(encoder, text_params, true);
    }
};

pub fn characters(params: CharactersParams) CharactersGenerator {
    return .{ .params = params };
}

fn hasCharParams(params: TextParams) bool {
    return params.codec != null or
        params.min_codepoint != null or
        params.max_codepoint != null or
        params.categories != null or
        params.exclude_categories != null or
        params.include_characters != null or
        params.exclude_characters != null;
}

fn writeTextSchema(encoder: *cbor.Encoder, params: TextParams, comptime is_character: bool) cbor.Error!void {
    var fields: u64 = 2;
    if (params.max_size != null) fields += 1;
    if (params.alphabet != null) fields += 2;
    if (params.codec != null) fields += 1;
    if (params.min_codepoint != null) fields += 1;
    if (params.max_codepoint != null) fields += 1;
    if (params.categories != null) fields += 1;
    if (params.exclude_categories != null) fields += 1;
    if (params.include_characters != null) fields += 1;
    if (params.exclude_characters != null) fields += 1;
    try encoder.map(fields);
    try encoder.fieldText("type", "string");
    try encoder.fieldUnsigned("min_size", params.min_size);
    if (params.max_size) |max_size| try encoder.fieldUnsigned("max_size", max_size);
    if (params.alphabet) |alphabet| {
        try encoder.text("categories");
        try encoder.array(0);
        try encoder.fieldText("include_characters", alphabet);
    } else {
        try writeOptionalTextField(encoder, "codec", params.codec);
        try writeOptionalUnsignedField(encoder, "min_codepoint", params.min_codepoint);
        try writeOptionalUnsignedField(encoder, "max_codepoint", params.max_codepoint);
        try writeOptionalStringArrayField(encoder, "categories", params.categories);
        try writeOptionalStringArrayField(encoder, "exclude_categories", params.exclude_categories);
        try writeOptionalTextField(encoder, "include_characters", params.include_characters);
        try writeOptionalTextField(encoder, "exclude_characters", params.exclude_characters);
    }
    _ = is_character;
}

pub const BinaryParams = struct {
    min_size: usize = 0,
    max_size: ?usize = null,
};

pub fn binary(params: BinaryParams) HegelError!BinaryGenerator {
    if (params.max_size) |max_size| if (params.min_size > max_size) return HegelError.InvalidArgument;
    return .{ .params = params };
}

pub const BinaryGenerator = struct {
    pub const Value = []u8;
    pub const preserves_equality = true;
    params: BinaryParams,

    pub fn draw(self: BinaryGenerator, tc: *TestCase) HegelError![]u8 {
        var value = try tc.generate(self);
        defer value.deinit(tc.allocator);
        return parseOwnedBytes(tc.allocator, value);
    }

    pub fn deinitValue(self: BinaryGenerator, allocator: std.mem.Allocator, value: *[]u8) void {
        _ = self;
        allocator.free(value.*);
    }

    pub fn writeSchema(self: BinaryGenerator, encoder: *cbor.Encoder) cbor.Error!void {
        var fields: u64 = 2;
        if (self.params.max_size != null) fields += 1;
        try encoder.map(fields);
        try encoder.fieldText("type", "binary");
        try encoder.fieldUnsigned("min_size", self.params.min_size);
        if (self.params.max_size) |max_size| try encoder.fieldUnsigned("max_size", max_size);
    }
};

pub const RegexGenerator = struct {
    pub const Value = []u8;
    pub const preserves_equality = true;
    pattern: []const u8,
    fullmatch: bool,

    pub fn draw(self: RegexGenerator, tc: *TestCase) HegelError![]u8 {
        var value = try tc.generate(self);
        defer value.deinit(tc.allocator);
        return parseOwnedString(tc.allocator, value);
    }

    pub fn deinitValue(self: RegexGenerator, allocator: std.mem.Allocator, value: *[]u8) void {
        _ = self;
        allocator.free(value.*);
    }

    pub fn writeSchema(self: RegexGenerator, encoder: *cbor.Encoder) cbor.Error!void {
        try encoder.map(3);
        try encoder.fieldText("type", "regex");
        try encoder.fieldText("pattern", self.pattern);
        try encoder.fieldBool("fullmatch", self.fullmatch);
    }
};

pub fn fromRegex(pattern: []const u8, fullmatch: bool) RegexGenerator {
    return .{ .pattern = pattern, .fullmatch = fullmatch };
}

pub const StringFormatGenerator = struct {
    pub const Value = []u8;
    pub const preserves_equality = true;
    type_name: []const u8,
    max_length: ?usize = null,
    version: ?u8 = null,

    pub fn draw(self: StringFormatGenerator, tc: *TestCase) HegelError![]u8 {
        var value = try tc.generate(self);
        defer value.deinit(tc.allocator);
        return parseOwnedString(tc.allocator, value);
    }

    pub fn deinitValue(self: StringFormatGenerator, allocator: std.mem.Allocator, value: *[]u8) void {
        _ = self;
        allocator.free(value.*);
    }

    pub fn writeSchema(self: StringFormatGenerator, encoder: *cbor.Encoder) cbor.Error!void {
        var fields: u64 = 1;
        if (self.max_length != null) fields += 1;
        if (self.version != null) fields += 1;
        try encoder.map(fields);
        try encoder.fieldText("type", self.type_name);
        if (self.max_length) |max_length| try encoder.fieldUnsigned("max_length", max_length);
        if (self.version) |format_version| try encoder.fieldUnsigned("version", format_version);
    }
};

pub fn emails() StringFormatGenerator {
    return .{ .type_name = "email" };
}

pub fn domains(max_length: ?usize) HegelError!StringFormatGenerator {
    const length = max_length orelse 255;
    if (length < 4 or length > 255) return HegelError.InvalidArgument;
    return .{ .type_name = "domain", .max_length = length };
}

pub fn urls() StringFormatGenerator {
    return .{ .type_name = "url" };
}

pub fn ipAddresses(ip_version: ?u8) HegelError!StringFormatGenerator {
    if (ip_version) |v| if (v != 4 and v != 6) return HegelError.InvalidArgument;
    if (ip_version) |v| return .{ .type_name = "ip_address", .version = v };
    return .{ .type_name = "ip_address" };
}

pub fn dates() StringFormatGenerator {
    return .{ .type_name = "date" };
}

pub fn times() StringFormatGenerator {
    return .{ .type_name = "time" };
}

pub fn datetimes() StringFormatGenerator {
    return .{ .type_name = "datetime" };
}

fn parseOwnedString(allocator: std.mem.Allocator, value: cbor.Value) HegelError![]u8 {
    return switch (value) {
        .string => |s| allocator.dupe(u8, s) catch HegelError.OutOfMemory,
        .bytes => |b| allocator.dupe(u8, b) catch HegelError.OutOfMemory,
        else => HegelError.UnexpectedEngineValue,
    };
}

fn parseOwnedBytes(allocator: std.mem.Allocator, value: cbor.Value) HegelError![]u8 {
    return switch (value) {
        .bytes => |b| allocator.dupe(u8, b) catch HegelError.OutOfMemory,
        .string => |s| allocator.dupe(u8, s) catch HegelError.OutOfMemory,
        else => HegelError.UnexpectedEngineValue,
    };
}

fn writeOptionalTextField(encoder: *cbor.Encoder, key: []const u8, value: ?[]const u8) cbor.Error!void {
    if (value) |text_value| try encoder.fieldText(key, text_value);
}

fn writeOptionalUnsignedField(encoder: *cbor.Encoder, key: []const u8, value: anytype) cbor.Error!void {
    if (value) |number| try encoder.fieldUnsigned(key, number);
}

fn writeOptionalStringArrayField(
    encoder: *cbor.Encoder,
    key: []const u8,
    value: ?[]const []const u8,
) cbor.Error!void {
    if (value) |items| {
        try encoder.text(key);
        try encoder.array(items.len);
        for (items) |item| try encoder.text(item);
    }
}

pub fn VectorParams() type {
    return struct {
        min_size: usize = 0,
        max_size: ?usize = null,
        unique: bool = false,
    };
}

pub fn vectors(element: anytype, params: VectorParams()) HegelError!VectorGenerator(@TypeOf(element)) {
    if (params.max_size) |max_size| if (params.min_size > max_size) return HegelError.InvalidArgument;
    return .{ .element = element, .params = params };
}

pub fn VectorGenerator(comptime ElementGen: type) type {
    return struct {
        pub const Element = ElementGen.Value;
        pub const Value = []Element;
        pub const schema_backed = isSchemaBacked(ElementGen) and preservesEquality(ElementGen);
        pub const preserves_equality = schema_backed;
        element: ElementGen,
        params: VectorParams(),

        pub fn draw(self: @This(), tc: *TestCase) HegelError![]Element {
            if (comptime @This().schema_backed) {
                var value = try tc.generate(self);
                defer value.deinit(tc.allocator);
                return self.parseArray(tc.allocator, value);
            }
            return self.drawFallback(tc);
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *[]Element) void {
            for (value.*) |*item| rootDeinitValue(self.element, allocator, item);
            allocator.free(value.*);
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            if (comptime !@This().schema_backed) @compileError("element generator is not schema-backed and equality-preserving");
            var fields: u64 = 4;
            if (self.params.max_size != null) fields += 1;
            try encoder.map(fields);
            try encoder.fieldText("type", "list");
            try encoder.text("elements");
            try self.element.writeSchema(encoder);
            try encoder.fieldUnsigned("min_size", self.params.min_size);
            try encoder.fieldBool("unique", self.params.unique);
            if (self.params.max_size) |max_size| try encoder.fieldUnsigned("max_size", max_size);
        }

        pub fn parseValue(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError![]Element {
            return self.parseArray(allocator, value);
        }

        pub fn parseArray(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError![]Element {
            const items = switch (value) {
                .array => |array| array,
                else => return HegelError.UnexpectedEngineValue,
            };
            const result = try allocator.alloc(Element, items.len);
            errdefer allocator.free(result);
            var filled: usize = 0;
            errdefer while (filled > 0) {
                filled -= 1;
                rootDeinitValue(self.element, allocator, &result[filled]);
            };
            while (filled < items.len) : (filled += 1) {
                result[filled] = try parseGeneratedValue(self.element, allocator, items[filled]);
            }
            return result;
        }

        fn drawFallback(self: @This(), tc: *TestCase) HegelError![]Element {
            const max_size = self.params.max_size orelse 100;
            const length_gen = try integers(usize, .{ .min_value = self.params.min_size, .max_value = max_size });
            const len = try tc.draw(length_gen);
            const result = try tc.allocator.alloc(Element, len);
            errdefer tc.allocator.free(result);
            var filled: usize = 0;
            errdefer while (filled > 0) {
                filled -= 1;
                rootDeinitValue(self.element, tc.allocator, &result[filled]);
            };
            const attempts_max = if (self.params.unique) @max(@as(usize, 1), try attemptsBound(len, 10)) else len;
            var attempts: usize = 0;
            while (filled < len and attempts < attempts_max) : (attempts += 1) {
                var candidate = try tc.draw(self.element);
                if (self.params.unique) {
                    var duplicate = false;
                    for (result[0..filled]) |existing| {
                        if (generatedEqual(Element, existing, candidate)) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) {
                        rootDeinitValue(self.element, tc.allocator, &candidate);
                        continue;
                    }
                }
                result[filled] = candidate;
                filled += 1;
            }
            if (filled != len) return HegelError.AssumptionFailed;
            return result;
        }
    };
}

fn parseGeneratedValue(generator: anytype, allocator: std.mem.Allocator, value: cbor.Value) HegelError!@TypeOf(generator).Value {
    const Gen = @TypeOf(generator);
    if (comptime hasMethod(Gen, "parseValue")) return generator.parseValue(allocator, value);
    const T = Gen.Value;
    switch (@typeInfo(T)) {
        .bool => return switch (value) {
            .boolean => |b| b,
            else => HegelError.UnexpectedEngineValue,
        },
        .int => return parseInteger(T, value),
        .float => return parseFloat(T, value),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return parseOwnedString(allocator, value);
            return HegelError.UnsupportedType;
        },
        else => return HegelError.UnsupportedType,
    }
}

pub fn TupleGenerator(comptime Gens: type) type {
    return struct {
        pub const Value = TupleValue(Gens);
        pub const schema_backed = allSchemaBacked(Gens);
        pub const preserves_equality = allPreserveEquality(Gens);
        gens: Gens,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!Value {
            if (comptime allSchemaBacked(Gens)) {
                var value = try tc.generate(self);
                defer value.deinit(tc.allocator);
                return self.parseTuple(tc.allocator, value);
            }
            var result: Value = undefined;
            var initialized: usize = 0;
            errdefer inline for (comptime std.meta.fieldNames(Gens), 0..) |field_name, i| {
                if (initialized > i) {
                    rootDeinitValue(
                        @field(self.gens, field_name),
                        tc.allocator,
                        &@field(result, std.fmt.comptimePrint("{}", .{i})),
                    );
                }
            };
            inline for (comptime std.meta.fieldNames(Gens), 0..) |field_name, i| {
                @field(result, std.fmt.comptimePrint("{}", .{i})) = try tc.draw(@field(self.gens, field_name));
                initialized += 1;
            }
            return result;
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *Value) void {
            inline for (comptime std.meta.fieldNames(Gens), 0..) |field_name, i| {
                rootDeinitValue(@field(self.gens, field_name), allocator, &@field(value.*, std.fmt.comptimePrint("{}", .{i})));
            }
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            if (comptime !allSchemaBacked(Gens)) @compileError("tuple generator is not schema-backed");
            try encoder.map(2);
            try encoder.fieldText("type", "tuple");
            try encoder.text("elements");
            try encoder.array(std.meta.fieldNames(Gens).len);
            inline for (comptime std.meta.fieldNames(Gens)) |field_name| try @field(self.gens, field_name).writeSchema(encoder);
        }

        pub fn parseValue(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError!Value {
            return self.parseTuple(allocator, value);
        }

        fn parseTuple(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError!Value {
            const items = switch (value) {
                .array => |array| array,
                else => return HegelError.UnexpectedEngineValue,
            };
            if (items.len != std.meta.fieldNames(Gens).len) return HegelError.UnexpectedEngineValue;
            var result: Value = undefined;
            var initialized: usize = 0;
            errdefer inline for (comptime std.meta.fieldNames(Gens), 0..) |field_name, i| {
                if (initialized > i) {
                    rootDeinitValue(
                        @field(self.gens, field_name),
                        allocator,
                        &@field(result, std.fmt.comptimePrint("{}", .{i})),
                    );
                }
            };
            inline for (comptime std.meta.fieldNames(Gens), 0..) |field_name, i| {
                @field(result, std.fmt.comptimePrint("{}", .{i})) = try parseGeneratedValue(@field(self.gens, field_name), allocator, items[i]);
                initialized += 1;
            }
            return result;
        }
    };
}

pub fn tuples(gens: anytype) TupleGenerator(@TypeOf(gens)) {
    return .{ .gens = gens };
}

fn TupleValue(comptime Gens: type) type {
    const field_names = comptime std.meta.fieldNames(Gens);
    comptime var types: [field_names.len]type = undefined;
    inline for (field_names, 0..) |field_name, i| types[i] = @TypeOf(@field(@as(Gens, undefined), field_name)).Value;
    return @Tuple(&types);
}

fn allSchemaBacked(comptime Gens: type) bool {
    inline for (comptime std.meta.fieldNames(Gens)) |field_name| {
        const Gen = @TypeOf(@field(@as(Gens, undefined), field_name));
        if (!isSchemaBacked(Gen)) return false;
    }
    return true;
}

fn allPreserveEquality(comptime Gens: type) bool {
    inline for (comptime std.meta.fieldNames(Gens)) |field_name| {
        const Gen = @TypeOf(@field(@as(Gens, undefined), field_name));
        if (!preservesEquality(Gen)) return false;
    }
    return true;
}

pub fn SampledFrom(comptime T: type) type {
    return struct {
        pub const Value = T;
        pub const schema_backed = typeIsPlainData(T);
        pub const preserves_equality = false;
        values: []const T,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!T {
            var value = try tc.generate(self);
            defer value.deinit(tc.allocator);
            return self.parseValue(tc.allocator, value);
        }

        pub fn parseValue(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError!T {
            _ = allocator;
            const idx = try parseInteger(usize, value);
            if (idx >= self.values.len) return HegelError.UnexpectedEngineValue;
            return self.values[idx];
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            try encoder.map(3);
            try encoder.fieldText("type", "integer");
            try encoder.fieldUnsigned("min_value", 0);
            try encoder.fieldUnsigned("max_value", self.values.len - 1);
        }
    };
}

pub fn sampledFrom(comptime T: type, values: []const T) HegelError!SampledFrom(T) {
    comptime if (!typeIsPlainData(T)) @compileError("sampledFrom values must be plain data");
    if (values.len == 0) return HegelError.InvalidArgument;
    return .{ .values = values };
}

pub fn SetParams() type {
    return struct {
        min_size: usize = 0,
        max_size: ?usize = null,
    };
}

pub fn sets(element: anytype, params: SetParams()) HegelError!SetGenerator(@TypeOf(element)) {
    if (params.max_size) |max_size| if (params.min_size > max_size) return HegelError.InvalidArgument;
    return .{ .element = element, .params = params };
}

pub fn SetGenerator(comptime ElementGen: type) type {
    return struct {
        pub const Element = ElementGen.Value;
        pub const Value = []Element;
        pub const schema_backed = isSchemaBacked(ElementGen) and preservesEquality(ElementGen);
        pub const preserves_equality = schema_backed;
        element: ElementGen,
        params: SetParams(),

        pub fn draw(self: @This(), tc: *TestCase) HegelError![]Element {
            if (comptime @This().schema_backed) {
                var value = try tc.generate(self);
                defer value.deinit(tc.allocator);
                const vector_parser = VectorGenerator(ElementGen){ .element = self.element, .params = .{
                    .min_size = self.params.min_size,
                    .max_size = self.params.max_size,
                    .unique = true,
                } };
                return vector_parser.parseArray(tc.allocator, value);
            }
            return self.drawFallback(tc);
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *[]Element) void {
            for (value.*) |*item| rootDeinitValue(self.element, allocator, item);
            allocator.free(value.*);
        }

        fn drawFallback(self: @This(), tc: *TestCase) HegelError![]Element {
            const max_size = self.params.max_size orelse 20;
            const length_gen = try integers(usize, .{ .min_value = self.params.min_size, .max_value = max_size });
            const target_len = try tc.draw(length_gen);
            const result = try tc.allocator.alloc(Element, target_len);
            errdefer tc.allocator.free(result);
            var filled: usize = 0;
            errdefer while (filled > 0) {
                filled -= 1;
                rootDeinitValue(self.element, tc.allocator, &result[filled]);
            };
            const attempts_max = @max(@as(usize, 1), try attemptsBound(target_len, 10));
            var attempts: usize = 0;
            while (filled < target_len and attempts < attempts_max) : (attempts += 1) {
                var candidate = try tc.draw(self.element);
                var duplicate = false;
                for (result[0..filled]) |existing| {
                    if (generatedEqual(Element, existing, candidate)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) {
                    rootDeinitValue(self.element, tc.allocator, &candidate);
                    continue;
                }
                result[filled] = candidate;
                filled += 1;
            }
            if (filled != target_len) return HegelError.AssumptionFailed;
            return result;
        }

        pub fn parseValue(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError![]Element {
            const vector_parser = VectorGenerator(ElementGen){ .element = self.element, .params = .{
                .min_size = self.params.min_size,
                .max_size = self.params.max_size,
                .unique = true,
            } };
            return vector_parser.parseArray(allocator, value);
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            if (comptime !@This().schema_backed) @compileError("set element is not schema-backed and equality-preserving");
            var fields: u64 = 4;
            if (self.params.max_size != null) fields += 1;
            try encoder.map(fields);
            try encoder.fieldText("type", "list");
            try encoder.text("elements");
            try self.element.writeSchema(encoder);
            try encoder.fieldUnsigned("min_size", self.params.min_size);
            try encoder.fieldBool("unique", true);
            if (self.params.max_size) |max_size| try encoder.fieldUnsigned("max_size", max_size);
        }
    };
}

pub fn MapEntry(comptime K: type, comptime V: type) type {
    return struct { key: K, value: V };
}

pub fn MapsParams() type {
    return struct {
        min_size: usize = 0,
        max_size: ?usize = null,
    };
}

pub fn maps(key: anytype, value: anytype, params: MapsParams()) HegelError!MapsGenerator(@TypeOf(key), @TypeOf(value)) {
    if (params.max_size) |max_size| if (params.min_size > max_size) return HegelError.InvalidArgument;
    return .{ .key = key, .value = value, .params = params };
}

pub fn MapsGenerator(comptime KeyGen: type, comptime ValueGen: type) type {
    return struct {
        pub const Key = KeyGen.Value;
        pub const MapValue = ValueGen.Value;
        pub const Value = []MapEntry(Key, MapValue);
        pub const schema_backed = isSchemaBacked(KeyGen) and isSchemaBacked(ValueGen) and preservesEquality(KeyGen);
        pub const preserves_equality = schema_backed and preservesEquality(ValueGen);
        key: KeyGen,
        value: ValueGen,
        params: MapsParams(),

        pub fn draw(self: @This(), tc: *TestCase) HegelError!Value {
            if (comptime @This().schema_backed) {
                var value = try tc.generate(self);
                defer value.deinit(tc.allocator);
                return self.parseEntries(tc.allocator, value);
            }
            return self.drawFallback(tc);
        }

        fn parseEntries(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError!Value {
            const items = switch (value) {
                .array => |array| array,
                else => return HegelError.UnexpectedEngineValue,
            };
            const result = try allocator.alloc(MapEntry(Key, MapValue), items.len);
            errdefer allocator.free(result);
            var filled: usize = 0;
            errdefer while (filled > 0) {
                filled -= 1;
                rootDeinitValue(self.key, allocator, &result[filled].key);
                rootDeinitValue(self.value, allocator, &result[filled].value);
            };
            while (filled < items.len) : (filled += 1) {
                const pair = switch (items[filled]) {
                    .array => |array| array,
                    else => return HegelError.UnexpectedEngineValue,
                };
                if (pair.len != 2) return HegelError.UnexpectedEngineValue;
                var parsed_key = try parseGeneratedValue(self.key, allocator, pair[0]);
                const parsed_value = parseGeneratedValue(self.value, allocator, pair[1]) catch |err| {
                    rootDeinitValue(self.key, allocator, &parsed_key);
                    return err;
                };
                result[filled] = .{ .key = parsed_key, .value = parsed_value };
            }
            return result;
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *Value) void {
            for (value.*) |*entry| {
                rootDeinitValue(self.key, allocator, &entry.key);
                rootDeinitValue(self.value, allocator, &entry.value);
            }
            allocator.free(value.*);
        }

        fn drawFallback(self: @This(), tc: *TestCase) HegelError!Value {
            const max_size = self.params.max_size orelse 20;
            const length_gen = try integers(usize, .{ .min_value = self.params.min_size, .max_value = max_size });
            const target_len = try tc.draw(length_gen);
            const result = try tc.allocator.alloc(MapEntry(Key, MapValue), target_len);
            errdefer tc.allocator.free(result);
            var filled: usize = 0;
            errdefer while (filled > 0) {
                filled -= 1;
                rootDeinitValue(self.key, tc.allocator, &result[filled].key);
                rootDeinitValue(self.value, tc.allocator, &result[filled].value);
            };
            const attempts_max = @max(@as(usize, 1), try attemptsBound(target_len, 10));
            var attempts: usize = 0;
            while (filled < target_len and attempts < attempts_max) : (attempts += 1) {
                var key_value = try tc.draw(self.key);
                var duplicate = false;
                for (result[0..filled]) |existing| {
                    if (generatedEqual(Key, existing.key, key_value)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) {
                    rootDeinitValue(self.key, tc.allocator, &key_value);
                    continue;
                }
                const mapped_value = tc.draw(self.value) catch |err| {
                    rootDeinitValue(self.key, tc.allocator, &key_value);
                    return err;
                };
                result[filled] = .{ .key = key_value, .value = mapped_value };
                filled += 1;
            }
            if (filled != target_len) return HegelError.AssumptionFailed;
            return result;
        }

        pub fn parseValue(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError!Value {
            return self.parseEntries(allocator, value);
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            if (comptime !@This().schema_backed) @compileError("map key and value generators must be schema-backed and key equality-preserving");
            var fields: u64 = 4;
            if (self.params.max_size != null) fields += 1;
            try encoder.map(fields);
            try encoder.fieldText("type", "dict");
            try encoder.text("keys");
            try self.key.writeSchema(encoder);
            try encoder.text("values");
            try self.value.writeSchema(encoder);
            try encoder.fieldUnsigned("min_size", self.params.min_size);
            if (self.params.max_size) |max_size| try encoder.fieldUnsigned("max_size", max_size);
        }
    };
}

pub fn OneOfGenerator(comptime Gens: type) type {
    return struct {
        pub const Value = FirstValueType(Gens);
        pub const schema_backed = allSchemaBacked(Gens);
        pub const preserves_equality = false;
        gens: Gens,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!Value {
            if (comptime allSchemaBacked(Gens)) {
                var value = try tc.generate(self);
                defer value.deinit(tc.allocator);
                const items = switch (value) {
                    .array => |array| array,
                    else => return HegelError.UnexpectedEngineValue,
                };
                if (items.len != 2) return HegelError.UnexpectedEngineValue;
                const index = try parseInteger(usize, items[0]);
                return self.parseBranch(tc.allocator, index, items[1]);
            }
            const index_gen = try integers(usize, .{ .min_value = 0, .max_value = std.meta.fieldNames(Gens).len - 1 });
            const index = try tc.draw(index_gen);
            return self.drawBranch(tc, index);
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *Value) void {
            rootDeinitValue(@field(self.gens, std.meta.fieldNames(Gens)[0]), allocator, value);
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            if (comptime !allSchemaBacked(Gens)) @compileError("oneOf generator is not schema-backed");
            try encoder.map(2);
            try encoder.fieldText("type", "one_of");
            try encoder.text("generators");
            try encoder.array(std.meta.fieldNames(Gens).len);
            inline for (comptime std.meta.fieldNames(Gens)) |field_name| try @field(self.gens, field_name).writeSchema(encoder);
        }

        pub fn parseValue(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError!Value {
            const items = switch (value) {
                .array => |array| array,
                else => return HegelError.UnexpectedEngineValue,
            };
            if (items.len != 2) return HegelError.UnexpectedEngineValue;
            const index = try parseInteger(usize, items[0]);
            return self.parseBranch(allocator, index, items[1]);
        }

        fn parseBranch(self: @This(), allocator: std.mem.Allocator, index: usize, value: cbor.Value) HegelError!Value {
            inline for (comptime std.meta.fieldNames(Gens), 0..) |field_name, i| {
                if (index == i) return parseGeneratedValue(@field(self.gens, field_name), allocator, value);
            }
            return HegelError.UnexpectedEngineValue;
        }

        fn drawBranch(self: @This(), tc: *TestCase, index: usize) HegelError!Value {
            inline for (comptime std.meta.fieldNames(Gens), 0..) |field_name, i| {
                if (index == i) return tc.draw(@field(self.gens, field_name));
            }
            return HegelError.UnexpectedEngineValue;
        }
    };
}

pub fn oneOf(gens: anytype) HegelError!OneOfGenerator(@TypeOf(gens)) {
    if (std.meta.fieldNames(@TypeOf(gens)).len == 0) return HegelError.InvalidArgument;
    comptime assertSameValueTypes(@TypeOf(gens));
    return .{ .gens = gens };
}

pub fn VariantGenerator(comptime Union: type, comptime Gens: type) type {
    return struct {
        pub const Value = Union;
        pub const schema_backed = allSchemaBacked(Gens);
        pub const preserves_equality = allPreserveEquality(Gens);
        gens: Gens,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!Union {
            if (comptime allSchemaBacked(Gens)) {
                var value = try tc.generate(self);
                defer value.deinit(tc.allocator);
                const items = switch (value) {
                    .array => |array| array,
                    else => return HegelError.UnexpectedEngineValue,
                };
                if (items.len != 2) return HegelError.UnexpectedEngineValue;
                const index = try parseInteger(usize, items[0]);
                return self.parseBranch(tc.allocator, index, items[1]);
            }
            const index_gen = try integers(usize, .{ .min_value = 0, .max_value = std.meta.fieldNames(Gens).len - 1 });
            const index = try tc.draw(index_gen);
            return self.drawBranch(tc, index);
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            if (comptime !allSchemaBacked(Gens)) @compileError("variant generator is not schema-backed");
            try encoder.map(2);
            try encoder.fieldText("type", "one_of");
            try encoder.text("generators");
            try encoder.array(std.meta.fieldNames(Gens).len);
            inline for (comptime std.meta.fieldNames(Gens)) |field_name| try @field(self.gens, field_name).writeSchema(encoder);
        }

        pub fn parseValue(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError!Union {
            const items = switch (value) {
                .array => |array| array,
                else => return HegelError.UnexpectedEngineValue,
            };
            if (items.len != 2) return HegelError.UnexpectedEngineValue;
            const index = try parseInteger(usize, items[0]);
            return self.parseBranch(allocator, index, items[1]);
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *Union) void {
            switch (value.*) {
                inline else => |*payload, tag| {
                    const name = @tagName(tag);
                    const gen = @field(self.gens, name);
                    rootDeinitValue(gen, allocator, payload);
                },
            }
        }

        fn parseBranch(self: @This(), allocator: std.mem.Allocator, index: usize, value: cbor.Value) HegelError!Union {
            inline for (comptime std.meta.fieldNames(Union), 0..) |field_name, i| {
                if (index == i) {
                    const parsed = try parseGeneratedValue(@field(self.gens, field_name), allocator, value);
                    return @unionInit(Union, field_name, parsed);
                }
            }
            return HegelError.UnexpectedEngineValue;
        }

        fn drawBranch(self: @This(), tc: *TestCase, index: usize) HegelError!Union {
            inline for (comptime std.meta.fieldNames(Union), 0..) |field_name, i| {
                if (index == i) {
                    const parsed = try tc.draw(@field(self.gens, field_name));
                    return @unionInit(Union, field_name, parsed);
                }
            }
            return HegelError.UnexpectedEngineValue;
        }
    };
}

pub fn variant(comptime Union: type, gens: anytype) HegelError!VariantGenerator(Union, @TypeOf(gens)) {
    const union_field_names = comptime std.meta.fieldNames(Union);
    const gen_field_names = comptime std.meta.fieldNames(@TypeOf(gens));
    if (union_field_names.len == 0 or union_field_names.len != gen_field_names.len) return HegelError.InvalidArgument;
    inline for (union_field_names) |field_name| {
        if (!@hasField(@TypeOf(gens), field_name)) @compileError("variant generator tuple must use union field names");
    }
    return .{ .gens = gens };
}

fn FirstValueType(comptime Gens: type) type {
    const field_names = comptime std.meta.fieldNames(Gens);
    return @TypeOf(@field(@as(Gens, undefined), field_names[0])).Value;
}

fn assertSameValueTypes(comptime Gens: type) void {
    const First = FirstValueType(Gens);
    inline for (comptime std.meta.fieldNames(Gens)) |field_name| {
        const This = @TypeOf(@field(@as(Gens, undefined), field_name)).Value;
        if (This != First) @compileError("oneOf requires all generators to have the same Value type");
    }
}

pub fn OptionalGenerator(comptime Gen: type) type {
    return struct {
        pub const Child = Gen.Value;
        pub const Value = ?Child;
        pub const schema_backed = isSchemaBacked(Gen);
        pub const preserves_equality = preservesEquality(Gen);
        gen: Gen,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!?Child {
            if (comptime isSchemaBacked(Gen)) {
                var value = try tc.generate(self);
                defer value.deinit(tc.allocator);
                return self.parseValue(tc.allocator, value);
            }
            const none = try tc.draw(booleans());
            if (none) return null;
            return try tc.draw(self.gen);
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *?Child) void {
            if (value.*) |*inner| rootDeinitValue(self.gen, allocator, inner);
        }

        pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
            if (comptime !isSchemaBacked(Gen)) @compileError("optional child is not schema-backed");
            try encoder.map(2);
            try encoder.fieldText("type", "one_of");
            try encoder.text("generators");
            try encoder.array(2);
            try encoder.map(2);
            try encoder.fieldText("type", "constant");
            try encoder.text("value");
            try encoder.nil();
            try self.gen.writeSchema(encoder);
        }

        pub fn parseValue(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError!?Child {
            const items = switch (value) {
                .array => |array| array,
                else => return HegelError.UnexpectedEngineValue,
            };
            if (items.len != 2) return HegelError.UnexpectedEngineValue;
            const idx = try parseInteger(usize, items[0]);
            if (idx == 0) return null;
            if (idx == 1) return try parseGeneratedValue(self.gen, allocator, items[1]);
            return HegelError.UnexpectedEngineValue;
        }
    };
}

pub fn optional(gen: anytype) OptionalGenerator(@TypeOf(gen)) {
    return .{ .gen = gen };
}

pub fn MappedGenerator(comptime SourceGen: type, comptime F: type) type {
    const Base = struct {
        pub const Source = SourceGen.Value;
        pub const Value = ReturnPayload(FnReturn(F));
        source: SourceGen,
        f: F,

        pub fn drawFunctionBacked(self: @This(), tc: *TestCase) HegelError!Value {
            const source = try tc.draw(self.source);
            var mutable_source = source;
            defer rootDeinitValue(self.source, tc.allocator, &mutable_source);
            return callMapped(self.f, source);
        }
    };

    if (comptime isSchemaBacked(SourceGen)) {
        return struct {
            pub const Source = Base.Source;
            pub const Value = Base.Value;
            source: SourceGen,
            f: F,

            pub fn draw(self: @This(), tc: *TestCase) HegelError!Value {
                var value = try tc.generate(self);
                defer value.deinit(tc.allocator);
                return self.parseValue(tc.allocator, value);
            }

            pub fn writeSchema(self: @This(), encoder: *cbor.Encoder) cbor.Error!void {
                try self.source.writeSchema(encoder);
            }

            pub const preserves_equality = false;

            pub fn parseValue(self: @This(), allocator: std.mem.Allocator, value: cbor.Value) HegelError!Value {
                var source_value = try parseGeneratedValue(self.source, allocator, value);
                defer rootDeinitValue(self.source, allocator, &source_value);
                return callMapped(self.f, source_value);
            }
        };
    }

    return struct {
        pub const Source = Base.Source;
        pub const Value = Base.Value;
        source: SourceGen,
        f: F,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!Value {
            const base: Base = .{ .source = self.source, .f = self.f };
            return base.drawFunctionBacked(tc);
        }
    };
}

pub fn map(source: anytype, f: anytype) MappedGenerator(@TypeOf(source), @TypeOf(f)) {
    const Return = ReturnPayload(FnReturn(@TypeOf(f)));
    comptime if (!typeIsPlainData(Return)) {
        @compileError("map output must be pointer-free plain data; use compose for heap-owned or borrowed mapped values");
    };
    return .{ .source = source, .f = f };
}

fn FnReturn(comptime F: type) type {
    const Fn = switch (@typeInfo(F)) {
        .pointer => |ptr| ptr.child,
        else => F,
    };
    return @typeInfo(Fn).@"fn".return_type.?;
}

fn ReturnPayload(comptime Return: type) type {
    return switch (@typeInfo(Return)) {
        .error_union => |err_union| err_union.payload,
        else => Return,
    };
}

fn callMapped(f: anytype, value: anytype) HegelError!ReturnPayload(FnReturn(@TypeOf(f))) {
    const Return = FnReturn(@TypeOf(f));
    if (comptime @typeInfo(Return) == .error_union) {
        return f(value) catch |err| mapAnyError(err);
    }
    return f(value);
}

fn mapAnyError(err: anyerror) HegelError {
    return switch (err) {
        error.AssumptionFailed => HegelError.AssumptionFailed,
        error.StopTest => HegelError.StopTest,
        error.PropertyFailed => HegelError.PropertyFailed,
        error.InvalidArgument => HegelError.InvalidArgument,
        error.Backend => HegelError.Backend,
        error.InvalidHandle => HegelError.InvalidHandle,
        error.AlreadyComplete => HegelError.AlreadyComplete,
        error.NotComplete => HegelError.NotComplete,
        error.Internal => HegelError.Internal,
        error.UnknownReturnCode => HegelError.UnknownReturnCode,
        error.UnexpectedEngineValue => HegelError.UnexpectedEngineValue,
        error.UnsupportedType => HegelError.UnsupportedType,
        error.OutOfMemory => HegelError.OutOfMemory,
        else => HegelError.Backend,
    };
}

pub fn FilterGenerator(comptime Gen: type, comptime Pred: type) type {
    return struct {
        pub const Value = Gen.Value;
        gen: Gen,
        pred: Pred,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!Value {
            var attempts: usize = 0;
            while (attempts < 3) : (attempts += 1) {
                const value = try tc.draw(self.gen);
                if (self.pred(value)) return value;
                var mutable = value;
                rootDeinitValue(self.gen, tc.allocator, &mutable);
            }
            return HegelError.AssumptionFailed;
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *Value) void {
            rootDeinitValue(self.gen, allocator, value);
        }
    };
}

pub fn filter(gen: anytype, pred: anytype) FilterGenerator(@TypeOf(gen), @TypeOf(pred)) {
    return .{ .gen = gen, .pred = pred };
}

pub fn FlatMapGenerator(comptime Gen: type, comptime F: type) type {
    return struct {
        pub const Source = Gen.Value;
        pub const ChildGen = ReturnPayload(FnReturn(F));
        pub const Value = ChildGen.Value;
        gen: Gen,
        f: F,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!Value {
            const source = try tc.draw(self.gen);
            var mutable_source = source;
            defer rootDeinitValue(self.gen, tc.allocator, &mutable_source);
            const child = callFlatMap(self.f, source) catch |err| return err;
            return tc.draw(child);
        }
    };
}

pub fn flatMap(gen: anytype, f: anytype) FlatMapGenerator(@TypeOf(gen), @TypeOf(f)) {
    const Source = @TypeOf(gen).Value;
    const ChildGen = ReturnPayload(FnReturn(@TypeOf(f)));
    comptime {
        if (!typeIsPlainData(Source)) {
            @compileError("flatMap source values must be pointer-free plain data; use compose for heap-owned dependent generation");
        }
        if (!typeIsPlainData(ChildGen.Value)) {
            @compileError("flatMap output values must be pointer-free plain data; use compose for heap-owned dependent generation");
        }
    }
    return .{ .gen = gen, .f = f };
}

fn callFlatMap(f: anytype, value: anytype) HegelError!ReturnPayload(FnReturn(@TypeOf(f))) {
    const Return = FnReturn(@TypeOf(f));
    if (comptime @typeInfo(Return) == .error_union) {
        return f(value) catch |err| mapAnyError(err);
    }
    return f(value);
}

pub fn ComposedGenerator(comptime F: type) type {
    return struct {
        pub const Value = ReturnPayload(FnReturn(F));
        f: F,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!Value {
            const Return = FnReturn(F);
            if (comptime @typeInfo(Return) == .error_union) {
                return self.f(tc) catch |err| mapAnyError(err);
            }
            return self.f(tc);
        }
    };
}

pub fn compose(f: anytype) ComposedGenerator(@TypeOf(f)) {
    return .{ .f = f };
}

pub fn builds(comptime T: type, gens: anytype) BuildsGenerator(T, @TypeOf(gens)) {
    comptime validateBuildFields(T, @TypeOf(gens));
    return .{ .gens = gens };
}

pub fn BuildsGenerator(comptime T: type, comptime Gens: type) type {
    return struct {
        pub const Value = T;
        gens: Gens,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!T {
            var result: T = undefined;
            var initialized: usize = 0;
            errdefer inline for (comptime std.meta.fieldNames(Gens), 0..) |gen_field_name, i| {
                if (initialized > i) {
                    rootDeinitValue(
                        @field(self.gens, gen_field_name),
                        tc.allocator,
                        &@field(result, std.meta.fieldNames(T)[i]),
                    );
                }
            };
            inline for (comptime std.meta.fieldNames(Gens), 0..) |gen_field_name, i| {
                @field(result, std.meta.fieldNames(T)[i]) = try tc.draw(@field(self.gens, gen_field_name));
                initialized += 1;
            }
            return result;
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *T) void {
            inline for (comptime std.meta.fieldNames(Gens), 0..) |gen_field_name, i| {
                rootDeinitValue(
                    @field(self.gens, gen_field_name),
                    allocator,
                    &@field(value.*, std.meta.fieldNames(T)[i]),
                );
            }
        }
    };
}

fn validateBuildFields(comptime T: type, comptime Gens: type) void {
    const t_info = @typeInfo(T);
    if (t_info != .@"struct") @compileError("builds requires a struct result type");
    const target_field_types = comptime std.meta.fieldTypes(T);
    const gen_field_names = comptime std.meta.fieldNames(Gens);
    if (target_field_types.len != gen_field_names.len) @compileError("builds generator count must match struct field count");
    inline for (gen_field_names, 0..) |gen_field_name, i| {
        const Expected = target_field_types[i];
        const Actual = @TypeOf(@field(@as(Gens, undefined), gen_field_name)).Value;
        if (Actual != Expected) @compileError("builds generator value type must match the target field type");
    }
}

pub fn Field(comptime field_name: []const u8, comptime Gen: type) type {
    return struct {
        pub const name = field_name;
        pub const Generator = Gen;
        generator: Gen,
    };
}

pub fn field(comptime field_name: []const u8, generator: anytype) Field(field_name, @TypeOf(generator)) {
    return .{ .generator = generator };
}

pub fn buildsAgg(comptime T: type, fields: anytype) BuildsAggGenerator(T, @TypeOf(fields)) {
    comptime {
        validateFieldSpecs(T, @TypeOf(fields));
        validateAllFieldsSpecified(T, @TypeOf(fields));
    }
    return .{ .fields = fields };
}

pub fn builds_agg(comptime T: type, fields: anytype) BuildsAggGenerator(T, @TypeOf(fields)) {
    return buildsAgg(T, fields);
}

pub fn BuildsAggGenerator(comptime T: type, comptime Fields: type) type {
    return struct {
        pub const Value = T;
        fields: Fields,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!T {
            var result: T = undefined;
            var initialized: usize = 0;
            errdefer inline for (comptime std.meta.fieldNames(Fields), 0..) |field_spec_name, i| {
                if (initialized > i) {
                    const spec = @field(self.fields, field_spec_name);
                    rootDeinitValue(spec.generator, tc.allocator, &@field(result, @TypeOf(spec).name));
                }
            };
            inline for (comptime std.meta.fieldNames(Fields)) |field_spec_name| {
                const spec = @field(self.fields, field_spec_name);
                @field(result, @TypeOf(spec).name) = try tc.draw(spec.generator);
                initialized += 1;
            }
            return result;
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *T) void {
            inline for (comptime std.meta.fieldNames(Fields)) |field_spec_name| {
                const spec = @field(self.fields, field_spec_name);
                rootDeinitValue(spec.generator, allocator, &@field(value.*, @TypeOf(spec).name));
            }
        }
    };
}

fn validateAllFieldsSpecified(comptime T: type, comptime Fields: type) void {
    inline for (comptime std.meta.fieldNames(T)) |target_field_name| {
        comptime var found = false;
        inline for (comptime std.meta.fieldNames(Fields)) |field_spec_name| {
            const Spec = @TypeOf(@field(@as(Fields, undefined), field_spec_name));
            if (std.mem.eql(u8, target_field_name, Spec.name)) found = true;
        }
        if (!found) @compileError("buildsAgg requires one field(...) specification for every result field");
    }
}

fn validateFieldSpecs(comptime T: type, comptime Fields: type) void {
    if (@typeInfo(T) != .@"struct") @compileError("field-based generation requires a struct result type");
    inline for (comptime std.meta.fieldNames(Fields), 0..) |field_spec_name, i| {
        const Spec = @TypeOf(@field(@as(Fields, undefined), field_spec_name));
        if (!@hasDecl(Spec, "name") or !@hasDecl(Spec, "Generator")) {
            @compileError("buildsAgg and overrides require field(...) specifications");
        }
        inline for (comptime std.meta.fieldNames(Fields), 0..) |other_field_spec_name, j| {
            if (i < j) {
                const Other = @TypeOf(@field(@as(Fields, undefined), other_field_spec_name));
                if (std.mem.eql(u8, Spec.name, Other.name)) {
                    @compileError("field specifications must not name the same field twice");
                }
            }
        }
        if (!@hasField(T, Spec.name)) @compileError("field specification names a field that does not exist on the result type");
        if (Spec.Generator.Value != @FieldType(T, Spec.name)) {
            @compileError("field generator value type must match the target field type");
        }
    }
}

pub fn defaultGenerator(comptime T: type) HegelError!DefaultGenerator(T) {
    return .{};
}

pub fn DefaultGenerator(comptime T: type) type {
    return struct {
        pub const Value = T;

        pub fn override(self: @This(), fields: anytype) OverriddenDefaultGenerator(T, @TypeOf(fields)) {
            comptime validateFieldSpecs(T, @TypeOf(fields));
            return .{ .base = self, .fields = fields };
        }

        pub fn draw(self: @This(), tc: *TestCase) HegelError!T {
            _ = self;
            switch (@typeInfo(T)) {
                .void => return {},
                .bool => return tc.draw(booleans()),
                .int => return tc.draw(try integers(T, .{})),
                .float => return tc.draw(try floats(T, .{})),
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child == u8) return tc.draw(try text(.{}));
                    if (ptr.size == .slice) {
                        const child = try defaultGenerator(ptr.child);
                        return tc.draw(try vectors(child, .{}));
                    }
                    return HegelError.UnsupportedType;
                },
                .optional => |opt| {
                    const child = try defaultGenerator(opt.child);
                    return tc.draw(optional(child));
                },
                .@"enum" => {
                    const values = comptime std.enums.values(T);
                    const gen = try sampledFrom(T, values);
                    return tc.draw(gen);
                },
                .@"struct" => |s| {
                    var result: T = undefined;
                    var initialized: usize = 0;
                    errdefer inline for (s.field_names, 0..) |field_name, i| {
                        if (initialized > i) defaultDeinitValue(tc.allocator, &@field(result, field_name));
                    };
                    inline for (s.field_names, s.field_types) |field_name, field_type| {
                        const gen = try defaultGenerator(field_type);
                        @field(result, field_name) = try tc.draw(gen);
                        initialized += 1;
                    }
                    return result;
                },
                .@"union" => |u| {
                    if (u.tag_type == null) return HegelError.UnsupportedType;
                    if (u.field_names.len == 0) return HegelError.UnsupportedType;
                    const index_gen = try integers(usize, .{ .min_value = 0, .max_value = u.field_names.len - 1 });
                    const index = try tc.draw(index_gen);
                    inline for (u.field_names, u.field_types, 0..) |field_name, field_type, i| {
                        if (index == i) {
                            const gen = try defaultGenerator(field_type);
                            const value = try tc.draw(gen);
                            return @unionInit(T, field_name, value);
                        }
                    }
                    return HegelError.UnexpectedEngineValue;
                },
                else => return HegelError.UnsupportedType,
            }
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *T) void {
            _ = self;
            defaultDeinitValue(allocator, value);
        }
    };
}

pub fn OverriddenDefaultGenerator(comptime T: type, comptime Fields: type) type {
    return struct {
        pub const Value = T;
        base: DefaultGenerator(T),
        fields: Fields,

        pub fn draw(self: @This(), tc: *TestCase) HegelError!T {
            _ = self.base;
            var result: T = undefined;
            var initialized: usize = 0;
            errdefer inline for (comptime std.meta.fieldNames(T), 0..) |target_field_name, i| {
                if (initialized > i) self.deinitField(tc.allocator, &result, target_field_name);
            };
            inline for (comptime std.meta.fieldNames(T), comptime std.meta.fieldTypes(T)) |target_field_name, target_field_type| {
                try self.drawField(tc, &result, target_field_name, target_field_type);
                initialized += 1;
            }
            return result;
        }

        pub fn deinitValue(self: @This(), allocator: std.mem.Allocator, value: *T) void {
            inline for (comptime std.meta.fieldNames(T)) |target_field_name| {
                self.deinitField(allocator, value, target_field_name);
            }
        }

        fn drawField(
            self: @This(),
            tc: *TestCase,
            result: *T,
            comptime field_name: []const u8,
            comptime FieldType: type,
        ) HegelError!void {
            inline for (comptime std.meta.fieldNames(Fields)) |field_spec_name| {
                const spec = @field(self.fields, field_spec_name);
                if (comptime std.mem.eql(u8, @TypeOf(spec).name, field_name)) {
                    @field(result.*, field_name) = try tc.draw(spec.generator);
                    return;
                }
            }
            const gen = try defaultGenerator(FieldType);
            @field(result.*, field_name) = try tc.draw(gen);
        }

        fn deinitField(self: @This(), allocator: std.mem.Allocator, value: *T, comptime field_name: []const u8) void {
            inline for (comptime std.meta.fieldNames(Fields)) |field_spec_name| {
                const spec = @field(self.fields, field_spec_name);
                if (comptime std.mem.eql(u8, @TypeOf(spec).name, field_name)) {
                    rootDeinitValue(spec.generator, allocator, &@field(value.*, field_name));
                    return;
                }
            }
            defaultDeinitValue(allocator, &@field(value.*, field_name));
        }
    };
}

pub const HegelRandom = struct {
    prng: std.Random.DefaultPrng,

    pub fn random(self: *HegelRandom) std.Random {
        return std.Random.init(self, fillRandom);
    }

    fn fillRandom(ptr: *HegelRandom, buffer: []u8) void {
        ptr.prng.random().bytes(buffer);
    }
};

pub const RandomsParams = struct {};

pub const RandomsGenerator = struct {
    pub const Value = HegelRandom;
    params: RandomsParams,

    pub fn draw(self: RandomsGenerator, tc: *TestCase) HegelError!HegelRandom {
        _ = self;
        const seed = try tc.draw(try integers(u64, .{}));
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }
};

pub fn randoms(params: RandomsParams) RandomsGenerator {
    return .{ .params = params };
}

pub fn version(allocator: std.mem.Allocator) HegelError![]u8 {
    return ffi.versionAlloc(allocator) catch |err| mapFfiError(err);
}

test "links native hegel library" {
    const allocator = std.testing.allocator;
    const v = try version(allocator);
    defer allocator.free(v);
    try std.testing.expect(v.len > 0);
}

test "integer property shrinks through native engine" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = try integers(i64, .{});
            const value = try tc.draw(gen);
            if (value >= 10) try tc.fail("value >= 10");
        }
    }.run;
    var result = try check(allocator, property, .{
        .test_cases = 100,
        .seed = 1,
        .database = .disabled,
        .suppress_health_checks = &.{.filter_too_much},
    });
    defer result.deinit(allocator);
    switch (result) {
        .failed => |report| {
            try std.testing.expectEqualStrings("value >= 10", report.message);
            try std.testing.expect(report.generated.len > 0);
            try std.testing.expectEqualStrings("10", report.generated[0]);
        },
        else => return error.TestExpectedFailure,
    }
}

test "vectors draw and deinit heap-owned values" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const elem = try integers(i32, .{ .min_value = 0, .max_value = 3 });
            const gen = try vectors(elem, .{ .min_size = 2, .max_size = 4 });
            var value = try tc.draw(gen);
            defer deinitValue(gen, tc.allocator, &value);
            try tc.assume(value.len >= 2);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 2, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "schema combinators draw values" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const small = try integers(i32, .{ .min_value = 0, .max_value = 2 });
            const alternatives = try oneOf(.{ small, try integers(i32, .{ .min_value = 10, .max_value = 12 }) });
            const choice = try tc.draw(alternatives);
            try tc.assume((choice >= 0 and choice <= 2) or (choice >= 10 and choice <= 12));

            const maybe = optional(small);
            var optional_value = try tc.draw(maybe);
            defer deinitValue(maybe, tc.allocator, &optional_value);

            const tuple_gen = tuples(.{ small, booleans() });
            var tuple_value = try tc.draw(tuple_gen);
            defer deinitValue(tuple_gen, tc.allocator, &tuple_value);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 4, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "set and map generators draw unique schema-backed structures" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const small = try integers(i32, .{ .min_value = 0, .max_value = 10 });
            const set_gen = try sets(small, .{ .min_size = 2, .max_size = 4 });
            var set_value = try tc.draw(set_gen);
            defer deinitValue(set_gen, tc.allocator, &set_value);
            try tc.assume(set_value.len >= 2);

            const value_gen = try text(.{ .max_size = 3 });
            const map_gen = try maps(small, value_gen, .{ .min_size = 1, .max_size = 3 });
            var map_value = try tc.draw(map_gen);
            defer deinitValue(map_gen, tc.allocator, &map_value);
            try tc.assume(map_value.len >= 1);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 5, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "variant and default generators instantiate" {
    const allocator = std.testing.allocator;
    const Value = union(enum) { number: i32, flag: bool };
    const Record = struct { x: i32, ok: bool };
    const property = struct {
        fn run(tc: *TestCase) !void {
            const variant_gen = try variant(Value, .{
                .number = try integers(i32, .{ .min_value = 0, .max_value = 2 }),
                .flag = booleans(),
            });
            var variant_value = try tc.draw(variant_gen);
            defer deinitValue(variant_gen, tc.allocator, &variant_value);

            const record_gen = try defaultGenerator(Record);
            var record_value = try tc.draw(record_gen);
            defer deinitValue(record_gen, tc.allocator, &record_value);

            const default_variant_gen = try defaultGenerator(Value);
            var default_variant_value = try tc.draw(default_variant_gen);
            defer deinitValue(default_variant_gen, tc.allocator, &default_variant_value);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 6, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

fn doubleInt(value: i32) i32 {
    return value * 2;
}

fn positive(value: i32) bool {
    return value > 0;
}

fn boundedInteger(len: i32) IntegerGenerator(i32) {
    return integers(i32, .{ .min_value = 0, .max_value = len }) catch unreachable;
}

test "function-backed map filter and flatMap instantiate" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const base = try integers(i32, .{ .min_value = 1, .max_value = 3 });
            const mapped = map(base, &doubleInt);
            const mapped_value = try tc.draw(mapped);
            try tc.assume(mapped_value >= 2);

            const filtered = filter(base, &positive);
            const filtered_value = try tc.draw(filtered);
            try tc.assume(filtered_value > 0);

            const dependent = flatMap(base, &boundedInteger);
            const dependent_value = try tc.draw(dependent);
            try tc.assume(dependent_value >= 0);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 7, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "default generator supports enums and slices" {
    const allocator = std.testing.allocator;
    const Mode = enum { a, b, c };
    const property = struct {
        fn run(tc: *TestCase) !void {
            const enum_gen = try defaultGenerator(Mode);
            _ = try tc.draw(enum_gen);

            const slice_gen = try defaultGenerator([]i16);
            var slice_value = try tc.draw(slice_gen);
            defer deinitValue(slice_gen, tc.allocator, &slice_value);
            try tc.assume(slice_value.len <= 100);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 8, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

fn squareI32(value: i32) i32 {
    return value * value;
}

fn composedPoint(tc: *TestCase) !struct { x: i32, y: i32 } {
    const gen = try integers(i32, .{ .min_value = 0, .max_value = 5 });
    return .{ .x = try tc.draw(gen), .y = try tc.draw(gen) };
}

test "C++ parity builders and default overrides" {
    const allocator = std.testing.allocator;
    const Point = struct { x: i32, y: i32 };
    const property = struct {
        fn run(tc: *TestCase) !void {
            const int_gen = try integers(i32, .{ .min_value = 1, .max_value = 3 });

            const positional = builds(Point, .{ int_gen, int_gen });
            var positional_value = try tc.draw(positional);
            defer deinitValue(positional, tc.allocator, &positional_value);
            try tc.assume(positional_value.x >= 1 and positional_value.y >= 1);

            const aggregate = buildsAgg(Point, .{
                field("x", int_gen),
                field("y", int_gen),
            });
            var aggregate_value = try tc.draw(aggregate);
            defer deinitValue(aggregate, tc.allocator, &aggregate_value);
            try tc.assume(aggregate_value.x >= 1 and aggregate_value.y >= 1);

            const defaults = try defaultGenerator(Point);
            const overridden = defaults.override(.{field("x", int_gen)});
            var overridden_value = try tc.draw(overridden);
            defer deinitValue(overridden, tc.allocator, &overridden_value);
            try tc.assume(overridden_value.x >= 1 and overridden_value.x <= 3);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 9, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "map preserves schema-backed source protocol" {
    const int_gen = try integers(i32, .{ .min_value = 0, .max_value = 10 });
    const mapped = map(int_gen, &squareI32);
    try std.testing.expect(@hasDecl(@TypeOf(mapped), "writeSchema"));
    try std.testing.expect(isSchemaBacked(@TypeOf(mapped)));
    const vector_gen = try vectors(mapped, .{ .min_size = 1, .max_size = 3 });
    try std.testing.expect(!@TypeOf(vector_gen).schema_backed);
}

test "compose creates function-backed generator" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = compose(&composedPoint);
            const point = try tc.draw(gen);
            try tc.assume(point.x >= 0 and point.y >= 0);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 10, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "settings helper parity" {
    try std.testing.expectEqualStrings("quiet", verbosityToString(.quiet));
    try std.testing.expectEqualStrings("normal", verbosityToString(.normal));
    try std.testing.expectEqualStrings("filter_too_much", healthCheckToString(.filter_too_much));
    try std.testing.expectEqual(@as(usize, 4), allHealthChecks.len);
    try std.testing.expectEqual(c.PHASE_ALL, Phases.all().mask());
    try std.testing.expectEqual(c.PHASE_GENERATE | c.PHASE_SHRINK, (Phases{
        .explicit = false,
        .reuse = false,
        .target = false,
    }).mask());
}

test "settings and diagnostics return structured data without native output" {
    try std.testing.expect(Settings.default().database == .disabled);

    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = try integers(i32, .{ .min_value = 1, .max_value = 3 });
            const value = try tc.draw(gen);
            try tc.note("value was generated");
            if (value >= 2) try tc.fail("value too large");
        }
    }.run;
    var result = try check(allocator, property, .{
        .test_cases = 25,
        .seed = 11,
        .database = .disabled,
        .verbosity = .normal,
        .suppress_health_checks = &.{.filter_too_much},
    });
    defer result.deinit(allocator);
    switch (result) {
        .failed => |report| {
            try std.testing.expectEqualStrings("value too large", report.message);
            try std.testing.expect(report.generated.len >= 1);
            try std.testing.expectEqual(@as(usize, 1), report.notes.len);
            try std.testing.expectEqualStrings("value was generated", report.notes[0]);
        },
        else => return error.TestExpectedFailure,
    }
}

test "format and parameter edge validation" {
    try std.testing.expectError(HegelError.InvalidArgument, integers(i8, .{ .min_value = 4, .max_value = 3 }));
    try std.testing.expectError(HegelError.InvalidArgument, floats(f64, .{ .min_value = 0, .allow_nan = true }));
    try std.testing.expectError(HegelError.InvalidArgument, text(.{ .alphabet = "abc", .min_codepoint = 'a' }));
    try std.testing.expectError(HegelError.InvalidArgument, binary(.{ .min_size = 3, .max_size = 2 }));
    try std.testing.expectError(HegelError.InvalidArgument, domains(3));
    try std.testing.expectError(HegelError.InvalidArgument, domains(256));
    try std.testing.expectError(HegelError.InvalidArgument, ipAddresses(5));

    const domain_gen = try domains(null);
    try std.testing.expectEqual(@as(usize, 255), domain_gen.max_length.?);
    _ = emails();
    _ = urls();
    _ = try ipAddresses(null);
    _ = try ipAddresses(4);
    _ = try ipAddresses(6);
    _ = dates();
    _ = times();
    _ = datetimes();
    _ = fromRegex("[a-z]+", true);
}

test "formats and randoms draw through native engine" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const text_gen = try text(.{ .min_size = 1, .max_size = 4, .alphabet = "abc" });
            var text_value = try tc.draw(text_gen);
            defer deinitValue(text_gen, tc.allocator, &text_value);
            try tc.assume(text_value.len >= 1 and text_value.len <= 4);

            const byte_gen = try binary(.{ .min_size = 2, .max_size = 4 });
            var bytes = try tc.draw(byte_gen);
            defer deinitValue(byte_gen, tc.allocator, &bytes);
            try tc.assume(bytes.len >= 2 and bytes.len <= 4);

            const domain_gen = try domains(32);
            var domain = try tc.draw(domain_gen);
            defer deinitValue(domain_gen, tc.allocator, &domain);
            try tc.assume(domain.len > 0 and domain.len <= 32);

            var rng = try tc.draw(randoms(.{}));
            _ = rng.random().int(u32);
            var second_rng = try tc.draw(randoms(.{}));
            _ = second_rng.random().int(u32);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 12, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "function-backed collection fallbacks are bounded" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const base = try integers(i32, .{ .min_value = 0, .max_value = 5 });
            const mapped = map(base, &squareI32);

            const vector_gen = try vectors(mapped, .{ .min_size = 1, .max_size = 3, .unique = true });
            var vector_value = try tc.draw(vector_gen);
            defer deinitValue(vector_gen, tc.allocator, &vector_value);
            try tc.assume(vector_value.len >= 1 and vector_value.len <= 3);

            const set_gen = try sets(mapped, .{ .min_size = 1, .max_size = 3 });
            var set_value = try tc.draw(set_gen);
            defer deinitValue(set_gen, tc.allocator, &set_value);
            try tc.assume(set_value.len >= 1 and set_value.len <= 3);

            const map_gen = try maps(mapped, try text(.{ .max_size = 3 }), .{ .min_size = 1, .max_size = 3 });
            var map_value = try tc.draw(map_gen);
            defer deinitValue(map_gen, tc.allocator, &map_value);
            try tc.assume(map_value.len >= 1 and map_value.len <= 3);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 13, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "buildsAgg shrinks separated fields through native draws" {
    const allocator = std.testing.allocator;
    const MixedRecord = struct {
        first: i64,
        filler_text: []u8,
        filler_bool: bool,
        filler_int: i64,
        last: i64,
    };
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = buildsAgg(MixedRecord, .{
                field("first", try integers(i64, .{ .min_value = 0, .max_value = 1000 })),
                field("filler_text", try text(.{})),
                field("filler_bool", booleans()),
                field("filler_int", try integers(i64, .{})),
                field("last", try integers(i64, .{ .min_value = 0, .max_value = 1000 })),
            });
            var value = try tc.draw(gen);
            defer deinitValue(gen, tc.allocator, &value);
            if (value.first + value.last > 1000) try tc.fail("first + last > 1000");
        }
    }.run;
    var result = try check(allocator, property, .{
        .test_cases = 1000,
        .seed = 14,
        .database = .disabled,
        .suppress_health_checks = &.{ .filter_too_much, .too_slow, .large_initial_test_case },
    });
    defer result.deinit(allocator);
    switch (result) {
        .failed => |report| {
            try std.testing.expectEqualStrings("first + last > 1000", report.message);
            try std.testing.expect(report.generated.len >= 5);
            try std.testing.expectEqualStrings("1", report.generated[0]);
            try std.testing.expectEqualStrings("1000", report.generated[4]);
        },
        else => return error.TestExpectedFailure,
    }
}

test "settings defaults custom counts and health suppression" {
    const allocator = std.testing.allocator;
    const count_property = struct {
        fn run(tc: *TestCase) !void {
            _ = try tc.draw(try integers(i32, .{}));
        }
    }.run;

    var default_result = try check(allocator, count_property, .{ .database = .disabled });
    defer default_result.deinit(allocator);
    switch (default_result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 100), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }

    var custom_result = try check(allocator, count_property, .{ .test_cases = 17, .database = .disabled });
    defer custom_result.deinit(allocator);
    switch (custom_result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 17), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }

    const filtered_property = struct {
        fn run(tc: *TestCase) !void {
            const n = try tc.draw(try integers(i32, .{ .min_value = 0, .max_value = 100 }));
            try tc.assume(n < 90);
        }
    }.run;
    var filtered_result = try check(allocator, filtered_property, .{
        .test_cases = 25,
        .database = .disabled,
        .suppress_health_checks = &allHealthChecks,
    });
    defer filtered_result.deinit(allocator);
    switch (filtered_result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 25), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "fallback equality compares slice contents and detects overflow" {
    const allocator = std.testing.allocator;
    const left = try allocator.dupe(u8, "same");
    defer allocator.free(left);
    const right = try allocator.dupe(u8, "same");
    defer allocator.free(right);
    const other = try allocator.dupe(u8, "other");
    defer allocator.free(other);

    try std.testing.expect(generatedEqual([]u8, left, right));
    try std.testing.expect(!generatedEqual([]u8, left, other));
    try std.testing.expectError(HegelError.InvalidArgument, attemptsBound(std.math.maxInt(usize), 10));
}

test "just and sampledFrom parse native schema values to captured plain values" {
    const allocator = std.testing.allocator;
    const null_value: cbor.Value = .null;
    const just_gen = just(i32, 42);
    try std.testing.expectEqual(@as(i32, 42), try just_gen.parseValue(allocator, null_value));

    const index_value: cbor.Value = .{ .uint = 1 };
    const sampled = try sampledFrom(i32, &.{ 10, 20, 30 });
    try std.testing.expectEqual(@as(i32, 20), try sampled.parseValue(allocator, index_value));
}

fn generatedI64(text_value: []const u8) !i64 {
    return std.fmt.parseInt(i64, text_value, 10);
}

fn expectFindDefaultI64(comptime predicate: fn (i64) bool, seed: u64) !void {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const value = try tc.draw(try integers(i64, .{}));
            if (predicate(value)) try tc.fail("matched");
        }
    }.run;
    var result = try check(allocator, property, .{
        .test_cases = 500,
        .seed = seed,
        .database = .disabled,
        .suppress_health_checks = &.{ .filter_too_much, .too_slow },
    });
    defer result.deinit(allocator);
    switch (result) {
        .failed => {},
        else => return error.TestExpectedFailure,
    }
}

fn expectMinimalDefaultI64(comptime predicate: fn (i64) bool, expected: i64, seed: u64) !void {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const value = try tc.draw(try integers(i64, .{}));
            if (predicate(value)) try tc.fail("matched");
        }
    }.run;
    var result = try check(allocator, property, .{
        .test_cases = 500,
        .seed = seed,
        .database = .disabled,
        .suppress_health_checks = &.{ .filter_too_much, .too_slow },
    });
    defer result.deinit(allocator);
    switch (result) {
        .failed => |report| try std.testing.expectEqual(expected, try generatedI64(report.generated[0])),
        else => return error.TestExpectedFailure,
    }
}

fn isZero(value: i64) bool {
    return value == 0;
}
fn isNonZero(value: i64) bool {
    return value != 0;
}
fn isPositive(value: i64) bool {
    return value > 0;
}
fn isGreaterThanOne(value: i64) bool {
    return value > 1;
}
fn isNegative(value: i64) bool {
    return value < 0;
}
fn isLessThanNegativeOne(value: i64) bool {
    return value < -1;
}
fn isAtLeastThirteen(value: i64) bool {
    return value >= 13;
}
fn isLargePositive(value: i64) bool {
    return value > 1000;
}
fn isLargeNegative(value: i64) bool {
    return value < -1000;
}

fn alwaysI64(_: i64) bool {
    return true;
}

test "C++ find integers can produce zero" {
    try expectFindDefaultI64(isZero, 101);
}
test "C++ find integers can produce non-zero" {
    try expectFindDefaultI64(isNonZero, 102);
}
test "C++ find integers can produce large positive" {
    try expectFindDefaultI64(isLargePositive, 103);
}
test "C++ find integers can produce large negative" {
    try expectFindDefaultI64(isLargeNegative, 104);
}
test "C++ shrink integers minimize positive boundary" {
    try expectMinimalDefaultI64(isPositive, 1, 105);
}
test "C++ shrink integers minimize positive two boundary" {
    try expectMinimalDefaultI64(isGreaterThanOne, 2, 106);
}
test "C++ shrink integers minimize negative boundary" {
    try expectMinimalDefaultI64(isNegative, -1, 107);
}
test "C++ shrink integers minimize negative two boundary" {
    try expectMinimalDefaultI64(isLessThanNegativeOne, -2, 108);
}
test "C++ shrink integers minimize down to thirteen" {
    try expectMinimalDefaultI64(isAtLeastThirteen, 13, 109);
}

test "C++ shrink bounded integer range to zero" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const value = try tc.draw(try integers(i64, .{ .min_value = -10, .max_value = 10 }));
            if (alwaysI64(value)) try tc.fail("matched");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 100, .seed = 110, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .failed => |report| try std.testing.expectEqual(@as(i64, 0), try generatedI64(report.generated[0])),
        else => return error.TestExpectedFailure,
    }
}

test "C++ shrink bounded integer from minimum" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const value = try tc.draw(try integers(i64, .{ .min_value = 101 }));
            if (alwaysI64(value)) try tc.fail("matched");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 100, .seed = 111, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .failed => |report| try std.testing.expectEqual(@as(i64, 101), try generatedI64(report.generated[0])),
        else => return error.TestExpectedFailure,
    }
}

test "C++ floats find nan and infinities" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const value = try tc.draw(try floats(f64, .{}));
            if (std.math.isNan(value) or std.math.isInf(value)) try tc.fail("special float");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 500, .seed = 112, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .failed => {},
        else => return error.TestExpectedFailure,
    }
}

test "C++ floats validate bounded finite configuration" {
    const gen = try floats(f64, .{ .min_value = -1.5, .max_value = 2.5 });
    try std.testing.expectEqual(@as(?f64, -1.5), gen.min_value);
    try std.testing.expectEqual(@as(?f64, 2.5), gen.max_value);
    try std.testing.expect(!gen.allow_nan);
    try std.testing.expect(!gen.allow_infinity);
}

test "C++ text generator can produce constrained ascii strings" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = try text(.{ .min_size = 3, .max_size = 8, .alphabet = "abc" });
            var value = try tc.draw(gen);
            defer deinitValue(gen, tc.allocator, &value);
            try tc.assume(value.len >= 3 and value.len <= 8);
            for (value) |ch| try tc.assume(ch == 'a' or ch == 'b' or ch == 'c');
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 25, .seed = 114, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "C++ binary generator can produce large enough byte strings" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = try binary(.{ .min_size = 32, .max_size = 64 });
            var value = try tc.draw(gen);
            defer deinitValue(gen, tc.allocator, &value);
            try tc.assume(value.len >= 32 and value.len <= 64);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 115, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "C++ collection generator can produce long lists" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = try vectors(try integers(i64, .{}), .{ .min_size = 20, .max_size = 25 });
            var value = try tc.draw(gen);
            defer deinitValue(gen, tc.allocator, &value);
            try tc.assume(value.len >= 20 and value.len <= 25);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 116, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "C++ collection unique vector has no duplicates" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = try vectors(try integers(i32, .{ .min_value = 0, .max_value = 20 }), .{ .min_size = 5, .max_size = 8, .unique = true });
            var value = try tc.draw(gen);
            defer deinitValue(gen, tc.allocator, &value);
            for (value, 0..) |left, i| for (value[i + 1 ..]) |right| try tc.assume(left != right);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 117, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "C++ collection set has no duplicates" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = try sets(try integers(i32, .{ .min_value = 0, .max_value = 20 }), .{ .min_size = 5, .max_size = 8 });
            var value = try tc.draw(gen);
            defer deinitValue(gen, tc.allocator, &value);
            for (value, 0..) |left, i| for (value[i + 1 ..]) |right| try tc.assume(left != right);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 118, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "C++ collection map keys are unique" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = try maps(try integers(i32, .{ .min_value = 0, .max_value = 20 }), booleans(), .{ .min_size = 5, .max_size = 8 });
            var value = try tc.draw(gen);
            defer deinitValue(gen, tc.allocator, &value);
            for (value, 0..) |left, i| for (value[i + 1 ..]) |right| try tc.assume(left.key != right.key);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 119, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "C++ oneOf reaches both integer branches" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = try oneOf(.{ try integers(i64, .{ .min_value = -5, .max_value = -1 }), try integers(i64, .{ .min_value = 5, .max_value = 9 }) });
            const value = try tc.draw(gen);
            if (value < 0) try tc.fail("negative branch");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 50, .seed = 120, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .failed => {},
        else => return error.TestExpectedFailure,
    }
}

test "C++ optional reaches present branch" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const gen = optional(try integers(i32, .{ .min_value = 1, .max_value = 3 }));
            var value = try tc.draw(gen);
            defer deinitValue(gen, tc.allocator, &value);
            if (value != null) try tc.fail("present optional");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 50, .seed = 121, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .failed => {},
        else => return error.TestExpectedFailure,
    }
}

test "C++ diagnostics quiet suppresses structured logs" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            _ = try tc.draw(try integers(i32, .{ .min_value = 1, .max_value = 1 }));
            try tc.note("hidden");
            try tc.fail("quiet failure");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 1, .verbosity = .quiet, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .failed => |report| {
            try std.testing.expectEqual(@as(usize, 0), report.generated.len);
            try std.testing.expectEqual(@as(usize, 0), report.notes.len);
        },
        else => return error.TestExpectedFailure,
    }
}

test "C++ diagnostics debug keeps structured logs" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            _ = try tc.draw(try integers(i32, .{ .min_value = 1, .max_value = 1 }));
            try tc.note("debug note");
            try tc.fail("debug failure");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 1, .verbosity = .debug, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .failed => |report| {
            try std.testing.expect(report.generated.len >= 1);
            try std.testing.expectEqual(@as(usize, 1), report.notes.len);
        },
        else => return error.TestExpectedFailure,
    }
}

test "C++ report multiple failures exposes failure count" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            _ = try tc.draw(try integers(i32, .{ .min_value = 1, .max_value = 3 }));
            try tc.fail("always fails");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .report_multiple_failures = true, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .failed => |report| try std.testing.expect(report.failure_count >= 1),
        else => return error.TestExpectedFailure,
    }
}

fn alwaysFailAfterSingleDraw(tc: *TestCase) !void {
    _ = try tc.draw(try integers(i32, .{ .min_value = 0, .max_value = 1000 }));
    try tc.fail("seeded failure");
}

test "C++ settings seed makes failure replay deterministic" {
    const allocator = std.testing.allocator;
    var first = try check(allocator, alwaysFailAfterSingleDraw, .{ .test_cases = 50, .seed = 130, .database = .disabled });
    defer first.deinit(allocator);
    var second = try check(allocator, alwaysFailAfterSingleDraw, .{ .test_cases = 50, .seed = 130, .database = .disabled });
    defer second.deinit(allocator);
    switch (first) {
        .failed => |first_report| switch (second) {
            .failed => |second_report| try std.testing.expectEqualStrings(first_report.generated[0], second_report.generated[0]),
            else => return error.TestExpectedFailure,
        },
        else => return error.TestExpectedFailure,
    }
}

test "C++ settings derandomize makes unseeded runs repeatable" {
    const allocator = std.testing.allocator;
    var first = try check(allocator, alwaysFailAfterSingleDraw, .{ .test_cases = 50, .derandomize = true, .database = .disabled });
    defer first.deinit(allocator);
    var second = try check(allocator, alwaysFailAfterSingleDraw, .{ .test_cases = 50, .derandomize = true, .database = .disabled });
    defer second.deinit(allocator);
    switch (first) {
        .failed => |first_report| switch (second) {
            .failed => |second_report| try std.testing.expectEqualStrings(first_report.generated[0], second_report.generated[0]),
            else => return error.TestExpectedFailure,
        },
        else => return error.TestExpectedFailure,
    }
}

test "C++ database explicit path and key are accepted" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/hegel-db", .{tmp.sub_path});
    defer allocator.free(path);

    const property = struct {
        fn run(tc: *TestCase) !void {
            _ = try tc.draw(try integers(i32, .{ .min_value = 0, .max_value = 3 }));
        }
    }.run;
    var result = try check(allocator, property, .{
        .test_cases = 5,
        .database = .{ .path = path },
        .database_key = "zig-db-parity",
    });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expect(passed.test_cases >= 1 and passed.test_cases <= 5),
        else => return error.TestUnexpectedResult,
    }
}

test "C++ database unset and disabled modes are explicit" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            _ = try tc.draw(booleans());
        }
    }.run;
    var unset_result = try check(allocator, property, .{ .test_cases = 2, .database = .unset });
    defer unset_result.deinit(allocator);
    switch (unset_result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 2), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
    var disabled_result = try check(allocator, property, .{ .test_cases = 2, .database = .disabled });
    defer disabled_result.deinit(allocator);
    switch (disabled_result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 2), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "C++ assumptions do not become property failures" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const value = try tc.draw(try integers(i32, .{ .min_value = 0, .max_value = 10 }));
            try tc.assume(value <= 10);
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expectEqual(@as(u64, 10), passed.test_cases),
        else => return error.TestUnexpectedResult,
    }
}

test "C++ user errors surface as run failures with fallback message" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            _ = try tc.draw(try integers(i32, .{ .min_value = 0, .max_value = 0 }));
            return error.UserFailure;
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 1, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .failed => |report| try std.testing.expectEqualStrings("Hegel test failed", report.message),
        else => return error.TestExpectedFailure,
    }
}

test "C++ target accepts finite scores and rejects non-finite scores" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            try tc.target("score", 1.25);
            try std.testing.expectError(HegelError.InvalidArgument, tc.target("bad", std.math.inf(f64)));
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 3, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => |passed| try std.testing.expect(passed.test_cases >= 1 and passed.test_cases <= 3),
        else => return error.TestUnexpectedResult,
    }
}

test "C++ string format generators produce basic valid shapes" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const email_gen = emails();
            var email = try tc.draw(email_gen);
            defer deinitValue(email_gen, tc.allocator, &email);
            if (std.mem.indexOfScalar(u8, email, '@') == null) try tc.fail("email missing at sign");

            const url_gen = urls();
            var url = try tc.draw(url_gen);
            defer deinitValue(url_gen, tc.allocator, &url);
            if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
                try tc.fail("url missing scheme");
            }
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 131, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "C++ date time format generators produce parseable shapes" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const date_gen = dates();
            var date = try tc.draw(date_gen);
            defer deinitValue(date_gen, tc.allocator, &date);
            if (date.len < 10 or date[4] != '-' or date[7] != '-') try tc.fail("date shape");

            const time_gen = times();
            var time = try tc.draw(time_gen);
            defer deinitValue(time_gen, tc.allocator, &time);
            if (time.len < 8 or time[2] != ':' or time[5] != ':') try tc.fail("time shape");

            const datetime_gen = datetimes();
            var datetime = try tc.draw(datetime_gen);
            defer deinitValue(datetime_gen, tc.allocator, &datetime);
            if (std.mem.indexOfScalar(u8, datetime, 'T') == null) try tc.fail("datetime shape");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 132, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "C++ regex generator honors fullmatch shape" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const regex_gen = fromRegex("[ab]{2}", true);
            var value = try tc.draw(regex_gen);
            defer deinitValue(regex_gen, tc.allocator, &value);
            if (value.len != 2) try tc.fail("regex length");
            for (value) |ch| if (ch != 'a' and ch != 'b') try tc.fail("regex alphabet");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 133, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "C++ characters generator returns one UTF-8 scalar" {
    const allocator = std.testing.allocator;
    const property = struct {
        fn run(tc: *TestCase) !void {
            const char_gen = characters(.{});
            var value = try tc.draw(char_gen);
            defer deinitValue(char_gen, tc.allocator, &value);
            if (!std.unicode.utf8ValidateSlice(value)) try tc.fail("character is not UTF-8");
            const codepoints = std.unicode.utf8CountCodepoints(value) catch return HegelError.UnexpectedEngineValue;
            if (codepoints != 1) try tc.fail("character codepoint count");
        }
    }.run;
    var result = try check(allocator, property, .{ .test_cases = 10, .seed = 134, .database = .disabled });
    defer result.deinit(allocator);
    switch (result) {
        .passed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "plain-data helpers recurse through fixed arrays" {
    try std.testing.expect(typeContainsPointer([2][]u8));
    try std.testing.expect(typeNeedsDeinit([2][]u8));
    try std.testing.expect(!typeIsPlainData([2][]u8));

    const left = [_]i32{ 1, 2, 3 };
    const same = [_]i32{ 1, 2, 3 };
    const different = [_]i32{ 1, 2, 4 };
    try std.testing.expect(generatedEqual([3]i32, left, same));
    try std.testing.expect(!generatedEqual([3]i32, left, different));
}

test "default deinit recurses through fixed arrays" {
    const allocator = std.testing.allocator;
    var value = [_][]u8{
        try allocator.dupe(u8, "left"),
        try allocator.dupe(u8, "right"),
    };
    defaultDeinitValue(allocator, &value);
}

test "plain-data helpers recurse through error-union payloads" {
    const PointerErrorUnion = error{Example}![]u8;
    try std.testing.expect(typeContainsPointer(PointerErrorUnion));
    try std.testing.expect(typeNeedsDeinit(PointerErrorUnion));
    try std.testing.expect(!typeIsPlainData(PointerErrorUnion));
    try std.testing.expect(typeContainsPointer([1]PointerErrorUnion));
    try std.testing.expect(typeContainsPointer(struct { value: PointerErrorUnion }));

    const IntErrorUnion = error{Example}!i32;
    const left: IntErrorUnion = 5;
    const same: IntErrorUnion = 5;
    const different: IntErrorUnion = 6;
    const failed: IntErrorUnion = error.Example;
    try std.testing.expect(generatedEqual(IntErrorUnion, left, same));
    try std.testing.expect(!generatedEqual(IntErrorUnion, left, different));
    try std.testing.expect(!generatedEqual(IntErrorUnion, left, failed));
    try std.testing.expect(generatedEqual(IntErrorUnion, failed, error.Example));
}

test "default deinit recurses through error-union payloads" {
    const allocator = std.testing.allocator;
    var value: error{Example}![]u8 = try allocator.dupe(u8, "payload");
    defaultDeinitValue(allocator, &value);
}
