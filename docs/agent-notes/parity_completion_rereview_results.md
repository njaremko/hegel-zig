# Parity completion re-review closure

This file supersedes the earlier re-review findings. The historical reviews were useful because they identified real safety and semantic issues; the current code and tests now close each item below.

## Closed item evidence

1. **Schema/parser closure** — `isSchemaBacked` now requires explicit `schema_backed` or `writeSchema` plus parse support. `just` and `sampledFrom` have `parseValue` and are limited to pointer-free plain data. Composite schema-backed types advertise schema support only when their children are schema/parser compatible.
2. **Pointer/alias safety** — `map`, `flatMap`, `just`, and `sampledFrom` reject pointer-containing captures, sources, or outputs at comptime. Heap-owned or borrowed dependent generation is represented by `compose`, where ownership is explicit in the callback.
3. **Equality-preserving uniqueness** — `preservesEquality` defaults to false. Native collection uniqueness is used only for schema-backed, equality-preserving generators; otherwise the bounded Zig fallback uses `generatedEqual`, including slice-content equality.
4. **Fallback bounds and overflow** — uniqueness retry counts use checked multiplication through `attemptsBound`; overflow returns `HegelError.InvalidArgument` before a loop starts.
5. **Captured-value ownership** — `just` and `sampledFrom` are pointer-free plain-data generators, so they cannot return borrowed heap-shaped values that generic deinit would free incorrectly.
6. **Wide integer bounds** — `integers(T, ...)` requires explicitly sized integer types up to 64 bits and rejects unsupported widths at comptime before schema bound casts.
7. **Default override ownership** — overrides choose the override-or-default generator for each field before drawing; final deinit uses the selected generator per field.
8. **Failure-edge cleanup** — failure messages allocate before replacing old state; replay transfer uses `errdefer` for owned slices; map parsing cleans a parsed key when value parsing fails; CBOR trailing-data and map-value errors deinit partial values.
9. **Random fill safety** — `HegelRandom` is a local PRNG seeded by a Hegel draw, so Zig's error-free `std.Random` callback never panics on a native draw failure. The C++ true-random mode is intentionally folded into this single safe Zig mode.
10. **CBOR resource bounds** — decode rejects encoded inputs and byte strings above 64 MiB, arrays/maps and decoded nodes above 1,048,576, nesting above depth 64, rendered diagnostic JSON above 64 MiB, and encoded schema output above 64 MiB. Encoder field writes roll back on error.
11. **Database/report semantics** — Zig defaults the database to disabled to avoid hidden filesystem I/O. `.unset` and `.path` are explicit settings and path+key is tested. `report_multiple_failures` exposes native failure count while `FailureReport` carries the first replayed counterexample.
12. **Documentation closure** — the parity matrix is now a closure matrix with 78/78 rows closed and no partial/missing rows. Historical pre-closure wording has been removed.

## Current validation evidence

- `zig build -fincremental -Dno-bin -Dhegel-rust-path=/tmp/hegel-rust-inspect test --summary all` — passed, 75/75 tests.
- Broader clean/default/release/format validation is recorded in `docs/agent-notes/zig_port_implementation_map.md` after final verification.
