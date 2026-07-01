# hegel Zig port implementation map

This note originally held pre-implementation reconnaissance. It now records the current completed implementation map.

## Current implementation

- `build.zig` links the Zig package against `hegeltest-c` from `git@github.com:hegeldev/hegel-rust.git`, cloning to `.deps/hegel-rust` with `jj git clone` when no checkout is supplied.
- `src/c.zig` declares the native C ABI and `src/ffi.zig` owns the handle wrappers.
- `src/cbor.zig` encodes native generator schemas, decodes generated CBOR values, and enforces size/depth/node/render bounds at the trust boundary.
- `src/root.zig` exposes the public Zig API: runner/settings/results, `TestCase`, schema-backed generators, function-backed combinators, field builders, default derivation, and random support.
- `README.md` and `docs/design.md` describe the current Zig-idiomatic public surface and deliberate differences from hegel-cpp.

## Current parity tracking

The active C++ to Zig parity matrix is:

- `docs/agent-notes/cpp_to_zig_parity_matrix.md`
- `docs/agent-notes/cpp_to_zig_parity_matrix.csv`

It records 78/78 closed public header rows: 50 implemented rows and 28 intentional Zig redesign rows.

## Verification evidence

Latest validation commands run against the linked native engine:

- `zig build -fincremental -Dno-bin -Dhegel-rust-path=/tmp/hegel-rust-inspect test --summary all` — passed, 75/75 tests.
- `zig build -Dno-bin -Dhegel-rust-path=/tmp/hegel-rust-inspect test --summary all` — passed, 75/75 tests.
- `zig build -Dno-bin -Dhegel-rust-path=/tmp/hegel-rust-inspect -Doptimize=ReleaseSafe test --summary all` — passed, 75/75 tests.
- `zig build -fincremental -Dno-bin test --summary all` — passed, 75/75 tests, using the default `.deps/hegel-rust` checkout.
- `zig build -Dno-bin test --summary all` — passed, 75/75 tests, using the default `.deps/hegel-rust` checkout.
- `zig fmt --check build.zig build.zig.zon src/*.zig` — passed.
