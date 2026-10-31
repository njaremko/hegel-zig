# Hegel for Zig

A Zig binding for Hegel's native property-testing engine. The build links the `hegeltest-c` static library from `git@github.com:hegeldev/hegel-rust.git` and exposes a Zig-style API with explicit allocators, error unions, comptime generators, and structured results.

## Build

```sh
zig build test
```

By default the build clones `git@github.com:hegeldev/hegel-rust.git` into `.deps/hegel-rust` with `jj git clone`, then runs:

```sh
cargo build -p hegeltest-c --release --manifest-path .deps/hegel-rust/Cargo.toml
```

To use an existing checkout instead:

```sh
zig build -Dhegel-rust-path=/path/to/hegel-rust test
```

To consume a native archive already built for the selected target:

```sh
zig build test -Dhegel-rust-library=/path/to/libhegel_c.a
```

This explicit option skips cloning and Cargo. Relative archive paths resolve
against this package's root. The caller supplies an archive matching its Hegel
source revision, Rust toolchain, target and build configuration; CI can establish
that match with an exact cache key or a successful build in the current job.
Missing or incompatible archives fail when linked. Without the option, the normal
Cargo build remains responsible for freshness. Downstream builds continue to
depend on the named `hegel-rust` step before linking the `hegel_zig` module.

## Example

```zig
const std = @import("std");
const hegel = @import("hegel_zig");

fn property(tc: *hegel.TestCase) !void {
    const gen = try hegel.integers(i32, .{ .min_value = 0, .max_value = 100 });
    const value = try tc.draw(gen);
    if (value < 0) try tc.fail("expected non-negative value");
}

test "property" {
    var result = try hegel.check(std.testing.allocator, property, .{ .database = .disabled });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .passed => {},
        else => return error.PropertyDidNotPass,
    }
}
```

Generated heap-owned values, such as text, binary data, vectors, sets, maps, and structs containing those values, must be released with `hegel.deinitValue(generator, allocator, &value)`.

## Ported API surface

The Zig port uses concrete/comptime generators instead of C++ virtual `Generator<T>` wrappers:

- runner: `check`, `testProperty`, `CheckResult`, `FailureReport`, `TestCase.draw`, `assume`, `fail`, `note`, `target`
- settings: `Settings`, `Database`, `Phases`, `Verbosity`, `verbosityToString`, `HealthCheck`, `healthCheckToString`, `allHealthChecks`
- primitives/numeric: `booleans`, `just`, `integers`, `floats`
- strings/formats: `text`, `characters`, `binary`, `fromRegex`, `emails`, `domains`, `urls`, `ipAddresses`, `dates`, `times`, `datetimes`
- collections/combinators: `vectors`, `sets`, `maps`, `tuples`, `sampledFrom`, `oneOf`, `variant`, `optional`, `map`, `filter`, `flatMap`, `compose`
- construction/defaults: `builds`, `field`, `buildsAgg`, `builds_agg`, `defaultGenerator(...).override(...)`
- random: `randoms`, returning a `HegelRandom` that can produce a `std.Random`

## Zig-idiomatic differences from hegel-cpp

- Results are returned as `CheckResult` data instead of throwing exceptions or printing diagnostics.
- Native engine verbosity is kept quiet by the library boundary; notes/generated values are collected in `FailureReport` according to Zig `Verbosity`.
- The default database setting is disabled to avoid hidden filesystem I/O. Use `.database = .{ .path = path }` or `.database = .unset` explicitly when persistence is desired.
- `maps` returns a slice of `MapEntry(K, V)` values, preserving explicit allocation/deallocation instead of choosing a global map container type.
- `just`, `sampledFrom`, `map`, and `flatMap` are limited to pointer-free plain-data captures/outputs unless ownership is made explicit with `compose`; the slice passed to `sampledFrom` must outlive the generator.
- `map` preserves native schemas only for pointer-free plain-data outputs; heap-owned or borrowed mapped outputs should be written with `compose` so ownership is explicit.
- `flatMap` is limited to pointer-free source and output values; heap-owned dependent generation should use `compose`.
- `randoms` returns a single Zig mode: a local PRNG seeded by a Hegel draw, avoiding hidden panics from `std.Random`'s error-free fill callback.
- `field("name", gen)` uses comptime field names rather than C++ pointer-to-member syntax.
