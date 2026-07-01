# Final review closure

The final read-only reviews identified a small set of closure items after the parity matrix was first closed. This file records their closure.

## Closed findings

1. **Fixed-array recursion** — `typeContainsPointer`, `typeNeedsDeinit`, `generatedEqual`, and `defaultDeinitValue` now recurse through fixed arrays. Tests cover pointer-containing arrays, array equality, and array deinit.
2. **Error-union recursion** — the same helpers now recurse through error-union payloads. Tests cover pointer-bearing payload rejection, nested pointer-bearing forms, equality, and deinit.
3. **`sampledFrom` borrowed choices** — docs now state that borrowed construction data must outlive the generator. The generated values remain pointer-free plain data.
4. **Random mode law** — `RandomsParams` is now an empty Zig options struct. The C++ two-mode distinction is intentionally replaced by one safe Zig mode: a local PRNG seeded by a Hegel draw.
5. **Database state model** — the ambiguous extra database-default variant was removed. Zig defaults to `.disabled`; `.unset` delegates to native default behavior and `.path` is explicit.
6. **Phases state model** — the phase setting is now a typed `Phases` struct with a `mask()` observation.
7. **CBOR encode/decode bounds** — encoder output is capped at 64 MiB using exact capacity reservation, encode-side string/bytes and array/map lengths are bounded, field writers roll back on error, render output uses exact capacity reservation, and tests cover encode/decode caps plus no partial mutation.
8. **README database syntax** — docs now use `.database = .{ .path = path }` for the payload union case.

Fresh final validation after these fixes passes 75/75 tests across incremental, clean, ReleaseSafe, and default dependency-path builds.
