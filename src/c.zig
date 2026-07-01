pub const result_t = c_int;

pub const OK: c_int = 0;
pub const E_STOP_TEST: c_int = -1;
pub const E_ASSUME: c_int = -2;
pub const E_BACKEND: c_int = -3;
pub const E_INVALID_HANDLE: c_int = -4;
pub const E_INVALID_ARG: c_int = -5;
pub const E_ALREADY_COMPLETE: c_int = -6;
pub const E_NOT_COMPLETE: c_int = -7;
pub const E_INTERNAL: c_int = -8;

pub const MODE_TEST_RUN: c_int = 0;
pub const MODE_SINGLE_TEST_CASE: c_int = 1;

pub const VERBOSITY_QUIET: c_int = 0;
pub const VERBOSITY_NORMAL: c_int = 1;
pub const VERBOSITY_VERBOSE: c_int = 2;
pub const VERBOSITY_DEBUG: c_int = 3;

pub const STATUS_VALID: c_int = 0;
pub const STATUS_INVALID: c_int = 1;
pub const STATUS_OVERRUN: c_int = 2;
pub const STATUS_INTERESTING: c_int = 3;

pub const RUN_STATUS_PASSED: c_int = 0;
pub const RUN_STATUS_FAILED: c_int = 1;
pub const RUN_STATUS_ERROR: c_int = 2;

pub const PHASE_EXPLICIT: u32 = 1 << 0;
pub const PHASE_REUSE: u32 = 1 << 1;
pub const PHASE_GENERATE: u32 = 1 << 2;
pub const PHASE_TARGET: u32 = 1 << 3;
pub const PHASE_SHRINK: u32 = 1 << 4;
pub const PHASE_ALL: u32 = 31;

pub const HC_FILTER_TOO_MUCH: u32 = 1 << 0;
pub const HC_TOO_SLOW: u32 = 1 << 1;
pub const HC_TEST_CASES_TOO_LARGE: u32 = 1 << 2;
pub const HC_LARGE_INITIAL_TEST_CASE: u32 = 1 << 3;

pub const LABEL_LIST: u64 = 1;
pub const LABEL_LIST_ELEMENT: u64 = 2;
pub const LABEL_SET: u64 = 3;
pub const LABEL_SET_ELEMENT: u64 = 4;
pub const LABEL_MAP: u64 = 5;
pub const LABEL_MAP_ENTRY: u64 = 6;
pub const LABEL_TUPLE: u64 = 7;
pub const LABEL_ONE_OF: u64 = 8;
pub const LABEL_OPTIONAL: u64 = 9;
pub const LABEL_FIXED_DICT: u64 = 10;
pub const LABEL_FLAT_MAP: u64 = 11;
pub const LABEL_FILTER: u64 = 12;
pub const LABEL_MAPPED: u64 = 13;
pub const LABEL_SAMPLED_FROM: u64 = 14;
pub const LABEL_ENUM_VARIANT: u64 = 15;
pub const LABEL_FEATURE_FLAG: u64 = 16;

pub const context_t = opaque {};
pub const settings_t = opaque {};
pub const run_t = opaque {};
pub const test_case_t = opaque {};
pub const run_result_t = opaque {};
pub const failure_t = opaque {};

pub extern fn hegel_context_new() ?*context_t;
pub extern fn hegel_context_free(ctx: ?*context_t) result_t;
pub extern fn hegel_context_last_error(ctx: ?*const context_t) ?[*:0]const u8;

pub extern fn hegel_settings_new(ctx: ?*context_t, out_settings: *?*settings_t) result_t;
pub extern fn hegel_settings_free(ctx: ?*context_t, s: ?*settings_t) result_t;
pub extern fn hegel_settings_set_mode(ctx: ?*context_t, s: ?*settings_t, mode: c_int) result_t;
pub extern fn hegel_settings_set_test_cases(ctx: ?*context_t, s: ?*settings_t, n: u64) result_t;
pub extern fn hegel_settings_set_verbosity(ctx: ?*context_t, s: ?*settings_t, v: c_int) result_t;
pub extern fn hegel_settings_set_seed(ctx: ?*context_t, s: ?*settings_t, seed: u64, has_seed: bool) result_t;
pub extern fn hegel_settings_set_derandomize(ctx: ?*context_t, s: ?*settings_t, derandomize: bool) result_t;
pub extern fn hegel_settings_set_report_multiple_failures(ctx: ?*context_t, s: ?*settings_t, yes: bool) result_t;
pub extern fn hegel_settings_set_database(ctx: ?*context_t, s: ?*settings_t, database: ?[*:0]const u8) result_t;
pub extern fn hegel_settings_set_database_key(ctx: ?*context_t, s: ?*settings_t, key: ?[*:0]const u8) result_t;
pub extern fn hegel_settings_set_phases(ctx: ?*context_t, s: ?*settings_t, phases: u32) result_t;
pub extern fn hegel_settings_set_suppress_health_check(ctx: ?*context_t, s: ?*settings_t, checks: u32) result_t;

pub extern fn hegel_run_start(ctx: ?*context_t, settings: ?*const settings_t, out_run: *?*run_t) result_t;
pub extern fn hegel_next_test_case(ctx: ?*context_t, run: ?*run_t, out_test_case: *?*test_case_t) result_t;
pub extern fn hegel_run_result(ctx: ?*context_t, run: ?*run_t, out_result: *?*const run_result_t) result_t;
pub extern fn hegel_run_free(ctx: ?*context_t, run: ?*run_t) result_t;

pub extern fn hegel_test_case_from_blob(ctx: ?*context_t, settings: ?*const settings_t, blob: [*:0]const u8, out_test_case: *?*test_case_t) result_t;
pub extern fn hegel_test_case_free(ctx: ?*context_t, tc: ?*test_case_t) result_t;

pub extern fn hegel_generate(
    ctx: ?*context_t,
    tc: ?*test_case_t,
    schema_cbor: [*]const u8,
    schema_len: usize,
    out_value_cbor: *?[*]const u8,
    out_value_len: *usize,
) result_t;

pub extern fn hegel_start_span(ctx: ?*context_t, tc: ?*test_case_t, label: u64) result_t;
pub extern fn hegel_stop_span(ctx: ?*context_t, tc: ?*test_case_t, discard: bool) result_t;
pub extern fn hegel_primitive_boolean(ctx: ?*context_t, tc: ?*test_case_t, p: f64, forced: bool, has_forced: bool, out_value: *bool) result_t;
pub extern fn hegel_target(ctx: ?*context_t, tc: ?*test_case_t, value: f64, label: [*:0]const u8) result_t;
pub extern fn hegel_mark_complete(ctx: ?*context_t, tc: ?*test_case_t, status: c_int, origin: ?[*:0]const u8) result_t;

pub extern fn hegel_run_result_status(ctx: ?*context_t, r: ?*const run_result_t, out_status: *c_int) result_t;
pub extern fn hegel_run_result_error(ctx: ?*context_t, r: ?*const run_result_t, out_error: *?[*:0]const u8) result_t;
pub extern fn hegel_run_result_failure_count(ctx: ?*context_t, r: ?*const run_result_t, out_count: *usize) result_t;
pub extern fn hegel_run_result_failure(ctx: ?*context_t, r: ?*const run_result_t, index: usize, out_failure: *?*const failure_t) result_t;
pub extern fn hegel_failure_origin(ctx: ?*context_t, f: ?*const failure_t, out_origin: *?[*:0]const u8) result_t;
pub extern fn hegel_failure_reproduction_blob(ctx: ?*context_t, f: ?*const failure_t, out_blob: *?[*:0]const u8) result_t;
pub extern fn hegel_version(ctx: ?*context_t, out_version: *?[*:0]const u8) result_t;
