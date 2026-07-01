# Parity completion review closure

The initial post-implementation review identified design and safety items. This file is a closure ledger for those historical items.

## Closure summary

- Schema-backed capability is explicit and parser-closed for the shipped public generator surface.
- `map`, `flatMap`, `just`, and `sampledFrom` are pointer-free plain-data APIs; heap-owned or borrowed transformations use `compose`.
- Collection uniqueness delegates to native schemas only for equality-preserving generators and otherwise uses bounded Zig fallback equality.
- `buildsAgg` requires every field exactly once and does not zero-initialize partially specified structs.
- Default overrides draw each field once with its selected generator and deinitialize with the matching generator.
- Failure and CBOR error paths clean partially owned values and have explicit resource bounds.
- `HegelRandom` cannot panic from a hidden draw inside `std.Random` callbacks.
- Settings, database, and diagnostics are documented as Zig structured-result redesigns and covered by tests.

See `docs/agent-notes/parity_completion_rereview_results.md` for per-item evidence and `docs/agent-notes/cpp_to_zig_parity_matrix.md` for the 78-row public API closure matrix.
