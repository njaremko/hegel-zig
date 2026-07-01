# Hegel Zig design

## Problem statement

This package is a Zig port of the hegel-cpp user-facing testing library backed by the native Hegel engine from `git@github.com:hegeldev/hegel-rust.git`. The port preserves the useful Hegel model—schema-backed generation, shrinking, replay, assumptions, health checks, and diagnostics—while using Zig idioms: explicit allocation, error unions, comptime type derivation, bounded resource use, and no hidden library I/O.

## Governing invariants

- A generator denotes a value distribution plus the native engine's shrink preorder for the schema-backed choices it performs.
- A test run denotes a bounded search for a counterexample to a user property.
- Rejected examples (`assume(false)`) do not fail the property and do not count as valid cases.
- Every public loop introduced by the Zig layer has an explicit bound: test cases come from settings, filters retry three times, collection fallbacks have max sizes and checked bounded uniqueness attempts, and generated heap values have explicit ownership.
- Generated heap-owned values are allocated with the caller/test allocator and can be released with `deinitValue`.
- Diagnostics are data returned in `CheckResult`; the library keeps native output quiet and does not print from public APIs.
- The CBOR boundary rejects oversized data on both sides of the native interface: encoded schema output, encoded input, byte strings, and rendered diagnostic JSON are capped at 64 MiB; arrays/maps and decoded node counts are capped at 1,048,576; nesting/render recursion is capped at depth 64. Encoder writes preflight capacity and roll back field writes on error.
- Filesystem persistence is opt-in through `Settings.database`; the Zig default disables the native database so test libraries do not perform hidden I/O. `.unset` delegates to the native engine default and `.path` uses an explicit caller-provided directory.

## Algebra sketch

Carrier types:

- `Generator(T)`: any Zig value with `pub const Value = T` and `draw(self, *TestCase) HegelError!T`. Schema-backed generators additionally provide `writeSchema`, and optionally `parseValue` for composed schemas.
- `TestCase`: a borrowed native engine case plus in-memory generated-value and note logs for structured diagnostics.
- `CheckResult`: either `passed` with run counts, `failed` with the native engine's replayed minimal counterexample report, or `run_error` when run bounds/health/replay fail before a verdict.

Denotation:

- `draw(g, tc)` consumes one or more bounded native-engine choices from `tc` and returns a value in `T` satisfying `g`'s validation parameters. Generators that borrow construction data, such as `sampledFrom`, require that borrowed data to outlive the generator.
- Schema-backed generators denote a Hegel schema plus a Zig parser; the native engine owns shrinking for those schemas.
- `map` preserves schema-backing when the source generator is schema-backed by delegating the same schema and composing the parser in Zig.
- Function-backed generators (`compose`, `builds`, `buildsAgg`, default struct derivation, `filter`, `flatMap`) denote ordinary Zig transformations over one or more draws. They keep the underlying draws visible to the engine so individual fields/choices can still shrink. `map`, `flatMap`, `just`, and `sampledFrom` are restricted to pointer-free plain data where the Zig layer can prove it will not return aliases into deinitialized source values.
- `check(property, settings)` delegates the generate/shrink/replay loop to `hegeltest-c`, then converts the native outcome into structured Zig data.

## Zig replacements for C++ idioms

- C++ `Generator<T>`/virtual dispatch becomes comptime duck-typed concrete generator values.
- C++ exceptions become `HegelError` error unions and `CheckResult` variants.
- C++ pointer-to-member `field<&T::member>` becomes `field("member", gen)` with comptime field-name validation.
- C++ default-generator overrides become `try defaultGenerator(T).override(.{ field("name", gen) })`.
- C++ output/diagnostic side effects become returned `FailureReport` fields.
- C++ per-call Hegel-backed and true-random engine modes become one Zig mode: a local `std.Random` engine seeded by a Hegel draw, because Zig's `std.Random` fill callback cannot report draw errors without panicking.

## Rejected simplifications

- A pure-Zig random fuzzer without native shrinking was rejected because it loses Hegel's defining behavior: a failing run returns a smaller replayable counterexample, not merely any counterexample.
- A hidden global allocator or hidden stderr output was rejected because it violates Zig ownership/I/O idioms and makes library use unsafe in tests and embedding applications.
