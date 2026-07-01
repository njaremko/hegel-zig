# Hegel C++ → Zig parity matrix
This matrix is the current closure record for the Zig port. It covers every public hegel-cpp header obligation inventoried from `/Users/njaremko/Development/hegel-cpp/include/hegel` and records the Zig API or Zig-idiomatic replacement.
## Current closure status
- Rows closed: 78/78.
- Implemented rows: 50.
- Intentional Zig redesign rows: 28.
- Partial rows: 0. Missing rows: 0.
- Runtime evidence: 75 Zig tests cover the native link, runner, settings, diagnostics, schemas, generators, combinators, defaults/builders, CBOR boundaries, and package example.
- Build evidence is recorded in `docs/agent-notes/zig_port_implementation_map.md` and the final task report.

## Upstream behavioral evidence closure
- **Core runner/diagnostics/output:** C++ text/GTest output is replaced by Zig `CheckResult` data and error unions. Tests cover pass counts, failures, replayed generated values, notes, assumptions, user errors, target scores, quiet/debug structured logs, and `testProperty`.
- **Settings/database/health/verbosity:** Tests cover default/custom counts, all-health suppression, seed and derandomize determinism, explicit database disabled/unset/path+key modes, and helper strings. Zig defaults database use to disabled to avoid hidden filesystem I/O; `.unset` and `.path` are explicit opt-ins.
- **Numeric and primitive quality:** Tests cover integer validation, default and bounded integer find/shrink behavior, special float generation, bounded float configuration, booleans, `just`, and `sampledFrom`.
- **Collections and combinators:** Tests cover vector/set/map uniqueness, fallback equality and retry bounds, tuple/optional/oneOf/variant/sampledFrom, schema-preserving `map`, function-backed fallback behavior, `filter`, `flatMap`, and `compose`.
- **Default/build APIs:** Tests cover `builds`, `field`, `buildsAgg`/`builds_agg`, separated-field shrink, `defaultGenerator` for supported categories, and `override` ownership/deinit.
- **Formats/randoms/strings:** Tests cover every exposed format constructor family, parameter validation, text/binary/character/regex generation, email/url/date/time/datetime shape oracles, and the single Zig `randoms` mode.
- **Build/docs/package:** `build.zig` links the native `hegeltest-c` library from the configured `hegel-rust` checkout, `src/main.zig` validates consumer import, and README/design document the shipped Zig surface.

## Intentional Zig redesign policy
Zig does not port C++ macros, virtual wrapper classes, exceptions, GTest output hooks, or public JSON wrapper types directly. The equivalent obligations are represented as concrete comptime generator values, explicit allocator/deinit ownership, error unions, and structured `CheckResult` data. Heap-owned or borrowed transformation outputs use `compose`; `map`, `flatMap`, `just`, and `sampledFrom` are restricted to pointer-free plain data so invalid aliasing states are unrepresentable.

## Header-grouped closure matrix

### `config.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| HEGEL_HAS_REFLECTION | config.h:5-18 | defaultGenerator(T) comptime; no macro src/root.zig | intentional Zig redesign | Closed by Zig-idiomatic redesign: no runtime C++ wrapper/macro/JSON type is part of the public Zig surface; behavior is documented in README/design and exercised through concrete generator tests where observable. |
| HEGEL_REQUIRES | config.h:20-27 | Zig comptime checks/errors e.g. src/root.zig | intentional Zig redesign | Closed by Zig-idiomatic redesign: no runtime C++ wrapper/macro/JSON type is part of the public Zig surface; behavior is documented in README/design and exercised through concrete generator tests where observable. |
| always_false_v | config.h:29-34 | No public Zig helper | intentional Zig redesign | Closed by Zig-idiomatic redesign: no runtime C++ wrapper/macro/JSON type is part of the public Zig surface; behavior is documented in README/design and exercised through concrete generator tests where observable. |

### `core.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| default_parse_raw | core.h:24-47 | Private CBOR decode/TestCase.generate covered by primitive/schema draw tests src/root.zig src/cbor.zig | implemented | Closed by current Zig tests and documented public-surface mapping. |
| BasicGenerator | core.h:52-87 | writeSchema plus optional parseValue schema protocol; schema-preserving map src/root.zig | implemented | Closed by current Zig tests and documented public-surface mapping. |
| IGenerator | core.h:92-129 | No dynamic interface; comptime concrete generator structs | intentional Zig redesign | Closed by Zig-idiomatic redesign: no runtime C++ wrapper/macro/JSON type is part of the public Zig surface; behavior is documented in README/design and exercised through concrete generator tests where observable. |
| Generator | core.h:133-176 | Concrete generator values; deinitValue src/root.zig | intentional Zig redesign | Closed by Zig-idiomatic redesign: no runtime C++ wrapper/macro/JSON type is part of the public Zig surface; behavior is documented in README/design and exercised through concrete generator tests where observable. |
| Generator.map | core.h:178-207;307-329 | map preserves schema-backed sources for plain-data outputs src/root.zig | intentional Zig redesign | Closed by current Zig tests and documented public-surface mapping. |
| Generator.flat_map | core.h:209-245 | flatMap available for plain-data source/output values src/root.zig; use compose for heap-owned dependent generation | intentional Zig redesign | Closed by current Zig tests and documented public-surface mapping. |
| Generator.filter | core.h:247-283 | filter src/root.zig bounded 3 attempts | implemented | Closed by current Zig tests and documented public-surface mapping. |
| compose | core.h:338-363 | compose/ComposedGenerator src/root.zig | implemented | Closed by current Zig tests and documented public-surface mapping. |
| TestCase.draw | core.h:367-372 | TestCase.draw src/root.zig | implemented | Closed by current Zig tests and documented public-surface mapping. |

### `generators/builds.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| builds | builds.h:13-41 | builds(T, gens) src/root.zig | implemented | Closed by build/default tests: positional and field builders, all-fields-required buildsAgg, separated-field shrink oracle, default derivation for supported types, and override draw/deinit ownership. |
| Field | builds.h:45-53 | Field(field_name, Gen) src/root.zig | implemented | Closed by build/default tests: positional and field builders, all-fields-required buildsAgg, separated-field shrink oracle, default derivation for supported types, and override draw/deinit ownership. |
| field | builds.h:56-74 | field("name", gen) src/root.zig | implemented | Closed by build/default tests: positional and field builders, all-fields-required buildsAgg, separated-field shrink oracle, default derivation for supported types, and override draw/deinit ownership. |
| builds_agg | builds.h:78-117 | buildsAgg/builds_agg src/root.zig | implemented | Closed by build/default tests: positional and field builders, all-fields-required buildsAgg, separated-field shrink oracle, default derivation for supported types, and override draw/deinit ownership. |

### `generators/collections.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| VectorsParams | collections.h:18-25;81-94 | VectorParams() src/root.zig; vectors(element, params: VectorParams()) src/root.zig | implemented | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |
| SetsParams | collections.h:27-33;135-149 | SetParams() src/root.zig; sets(element, params: SetParams()) src/root.zig | implemented | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |
| MapsParams | collections.h:35-42;197-211 | MapsParams() src/root.zig; maps(key, value, params: MapsParams()) src/root.zig | implemented | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |
| vectors | collections.h:47-99;230-243 | vectors supports schema-backed native path and bounded fallback including unique src/root.zig | implemented | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |
| sets | collections.h:102-154;246-262 | sets supports schema-backed native path and bounded function-backed fallback src/root.zig | implemented | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |
| maps | collections.h:158-217;265-290 | maps returns []MapEntry; schema-backed native path plus bounded function-backed fallback src/root.zig | intentional Zig redesign | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |
| tuples | collections.h:294-384 | tuples src/root.zig | implemented | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |

### `generators/combinators.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| sampled_from | combinators.h:15-31;91-132 | sampledFrom supports pointer-free plain-data values and parseValue src/root.zig | intentional Zig redesign | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |
| one_of | combinators.h:37-84;134-167 | oneOf src/root.zig | implemented | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |
| variant | combinators.h:173-268;319-337 | variant over Zig tagged unions src/root.zig | intentional Zig redesign | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |
| optional | combinators.h:272-316;340-358 | optional src/root.zig | implemented | Closed by collection/combinator tests: vectors/sets/maps/tuples/optional/oneOf/variant/sampledFrom, uniqueness, fallback equality, bounded retries, schema-preserving map behavior, and compose/map/filter/flatMap. |

### `generators/default.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| default_generator availability | default.h:5-8;298 | defaultGenerator always available for supported types src/root.zig | intentional Zig redesign | Closed by build/default tests: positional and field builders, all-fields-required buildsAgg, separated-field shrink oracle, default derivation for supported types, and override draw/deinit ownership. |
| DefaultGenerator | default.h:67-199 | DefaultGenerator supports void/bool/int/float/slice/optional/enum/struct/tuple/tagged union src/root.zig | implemented | Closed by build/default tests: positional and field builders, all-fields-required buildsAgg, separated-field shrink oracle, default derivation for supported types, and override draw/deinit ownership. |
| DerivedGenerator | default.h:211-228 | OverriddenDefaultGenerator src/root.zig | implemented | Closed by build/default tests: positional and field builders, all-fields-required buildsAgg, separated-field shrink oracle, default derivation for supported types, and override draw/deinit ownership. |
| DerivedGenerator.override | default.h:231-261 | defaultGenerator(T).override(.{field(...)}) chooses override-or-default before drawing each field | implemented | Closed by build/default tests: positional and field builders, all-fields-required buildsAgg, separated-field shrink oracle, default derivation for supported types, and override draw/deinit ownership. |
| default_generator | default.h:267-291 | defaultGenerator src/root.zig including override src/root.zig | implemented | Closed by build/default tests: positional and field builders, all-fields-required buildsAgg, separated-field shrink oracle, default derivation for supported types, and override draw/deinit ownership. |

### `generators/formats.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| DomainsParams | formats.h:14-18;43-50 | domains(?usize), with null default max length src/root.zig | intentional Zig redesign | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| IpAddressesParams | formats.h:21-24;68-81 | No params struct; ipAddresses(?u8) src/root.zig | intentional Zig redesign | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| emails | formats.h:28-39 | emails src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| domains | formats.h:41-50 | domains(?usize), with domains(null) default equivalent src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| urls | formats.h:52-60 | urls src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| ip_addresses | formats.h:62-81 | ipAddresses(?u8) src/root.zig; null/4/6/invalid tested | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| dates | formats.h:86-97 | dates src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| times | formats.h:100-108 | times src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| datetimes | formats.h:111-121 | datetimes src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |

### `generators/numeric.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| IntegersParams | numeric.h:16-25;52-62 | IntegerParams src/root.zig | implemented | Closed by validation/find/shrink tests for integers/floats/booleans/just, including bounds, special floats, deterministic replay, and primitive schema parsing. |
| FloatsParams | numeric.h:27-39;76-84 | FloatParams src/root.zig | implemented | Closed by validation/find/shrink tests for integers/floats/booleans/just, including bounds, special floats, deterministic replay, and primitive schema parsing. |
| integers | numeric.h:43-63;115-133 | integers src/root.zig | implemented | Closed by validation/find/shrink tests for integers/floats/booleans/just, including bounds, special floats, deterministic replay, and primitive schema parsing. |
| floats | numeric.h:67-108;136-155 | floats src/root.zig | implemented | Closed by validation/find/shrink tests for integers/floats/booleans/just, including bounds, special floats, deterministic replay, and primitive schema parsing. |

### `generators/primitives.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| booleans | primitives.h:10-14 | booleans src/root.zig | implemented | Closed by validation/find/shrink tests for integers/floats/booleans/just, including bounds, special floats, deterministic replay, and primitive schema parsing. |
| just | primitives.h:17-29;35-46 | just supports pointer-free plain-data captures and parseValue src/root.zig | intentional Zig redesign | Closed by validation/find/shrink tests for integers/floats/booleans/just, including bounds, special floats, deterministic replay, and primitive schema parsing. |
| just const char* | primitives.h:48-56 | No overload; explicit Zig string/slice types | intentional Zig redesign | Closed by validation/find/shrink tests for integers/floats/booleans/just, including bounds, special floats, deterministic replay, and primitive schema parsing. |

### `generators/random.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| RandomsParams | random.h:13-20 | RandomsParams is an empty Zig options struct; C++ true-random mode is intentionally folded into the single safe Zig PRNG mode src/root.zig | intentional Zig redesign | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| HegelRandom | random.h:23-76 | HegelRandom exposes std.Random as local PRNG seeded by Hegel draw src/root.zig | intentional Zig redesign | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| randoms | random.h:86-117 | randoms returns PRNG seeded by Hegel draw src/root.zig | intentional Zig redesign | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |

### `generators/strings.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| TextParams | strings.h:12-37 | TextParams src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| CharactersParams | strings.h:39-54 | CharactersParams src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| BinaryParams | strings.h:56-63 | BinaryParams src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| text | strings.h:67-72 | text src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| characters | strings.h:74-79 | characters src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| binary | strings.h:81-86 | binary src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |
| from_regex | strings.h:88-112 | fromRegex src/root.zig | implemented | Closed by format/string/random tests: invalid parameters, text/binary size, character UTF-8 scalar, regex fullmatch, email/url/date/time/datetime shapes, domain/IP edges, and the single Zig randoms mode. |

### `hegel.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| umbrella include | hegel.h:1-239 | Zig module build.zig README.md:3-45 | implemented | Closed by runner tests: pass counts, failures, replayed generated values, notes, assumptions, user errors, target scores, and structured CheckResult/testProperty behavior. |
| test | hegel.h:242-278 | check/testProperty src/root.zig | intentional Zig redesign | Closed by runner tests: pass counts, failures, replayed generated values, notes, assumptions, user errors, target scores, and structured CheckResult/testProperty behavior. |

### `internal.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| generate_from_schema | internal.h:14-18 | TestCase.generate/hegel_generate src/root.zig c.zig:94 | implemented | Closed by runner tests: pass counts, failures, replayed generated values, notes, assumptions, user errors, target scores, and structured CheckResult/testProperty behavior. |
| HegelReject | internal.h:20-31 | HegelError.AssumptionFailed src/root.zig src/root.zig | intentional Zig redesign | Closed by runner tests: pass counts, failures, replayed generated values, notes, assumptions, user errors, target scores, and structured CheckResult/testProperty behavior. |
| HegelStopTest | internal.h:33-42 | HegelError.StopTest/backend handling src/root.zig src/root.zig src/root.zig src/ffi.zig src/ffi.zig | intentional Zig redesign | Closed by runner tests: pass counts, failures, replayed generated values, notes, assumptions, user errors, target scores, and structured CheckResult/testProperty behavior. |

### `json.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| json_raw_ref | json.h:21-41 | No public JSON; private cbor.Value | intentional Zig redesign | Closed by Zig-idiomatic redesign: no runtime C++ wrapper/macro/JSON type is part of the public Zig surface; behavior is documented in README/design and exercised through concrete generator tests where observable. |
| json | json.h:44-78 | No public owning JSON | intentional Zig redesign | Closed by Zig-idiomatic redesign: no runtime C++ wrapper/macro/JSON type is part of the public Zig surface; behavior is documented in README/design and exercised through concrete generator tests where observable. |
| json_ref | json.h:81-98 | No public initializer helper | intentional Zig redesign | Closed by Zig-idiomatic redesign: no runtime C++ wrapper/macro/JSON type is part of the public Zig surface; behavior is documented in README/design and exercised through concrete generator tests where observable. |

### `settings.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| Verbosity | settings.h:12-19 | Verbosity plus verbosityToString; native output intentionally quiet with structured FailureReport src/root.zig,45-52,330-333 | intentional Zig redesign | Closed by settings/diagnostics tests: helper strings, default/custom counts, health suppression, seed/derandomize determinism, explicit database disabled/unset/path+key, and structured verbosity behavior. |
| verbosity_to_string | settings.h:21-35 | verbosityToString src/root.zig | implemented | Closed by settings/diagnostics tests: helper strings, default/custom counts, health suppression, seed/derandomize determinism, explicit database disabled/unset/path+key, and structured verbosity behavior. |
| HealthCheck | settings.h:41-48 | HealthCheck src/root.zig | implemented | Closed by settings/diagnostics tests: helper strings, default/custom counts, health suppression, seed/derandomize determinism, explicit database disabled/unset/path+key, and structured verbosity behavior. |
| health_check_to_string | settings.h:50-62 | healthCheckToString src/root.zig | implemented | Closed by settings/diagnostics tests: helper strings, default/custom counts, health suppression, seed/derandomize determinism, explicit database disabled/unset/path+key, and structured verbosity behavior. |
| all_health_checks | settings.h:65-73 | allHealthChecks src/root.zig | implemented | Closed by settings/diagnostics tests: helper strings, default/custom counts, health suppression, seed/derandomize determinism, explicit database disabled/unset/path+key, and structured verbosity behavior. |
| Database | settings.h:77-110 | Database union; Zig default disabled to avoid hidden I/O, explicit path/unset available src/root.zig,352-366 | intentional Zig redesign | Closed by settings/diagnostics tests: helper strings, default/custom counts, health suppression, seed/derandomize determinism, explicit database disabled/unset/path+key, and structured verbosity behavior. |
| in_ci | settings.h:115-147 | Private inCi src/root.zig | implemented | Closed by settings/diagnostics tests: helper strings, default/custom counts, health suppression, seed/derandomize determinism, explicit database disabled/unset/path+key, and structured verbosity behavior. |
| Settings | settings.h:154-177 | Settings applied to native engine; default/custom counts, helpers, health suppression tested src/root.zig,323-371 | implemented | Closed by settings/diagnostics tests: helper strings, default/custom counts, health suppression, seed/derandomize determinism, explicit database disabled/unset/path+key, and structured verbosity behavior. |

### `test_case.h`
| C++ API / feature | C++ refs | Zig API / redesign | Status | Closure evidence |
|---|---:|---|---|---|
| TestCase | test_case.h:15-45 | Borrowed TestCase handle with explicit callback lifetime; random engines are local PRNG values seeded during draw README/design src/root.zig | intentional Zig redesign | Closed by runner tests: pass counts, failures, replayed generated values, notes, assumptions, user errors, target scores, and structured CheckResult/testProperty behavior. |
| TestCase.draw | test_case.h:47-48;core.h:367-372 | TestCase.draw src/root.zig | implemented | Closed by runner tests: pass counts, failures, replayed generated values, notes, assumptions, user errors, target scores, and structured CheckResult/testProperty behavior. |
| TestCase.assume | test_case.h:50-62 | TestCase.assume src/root.zig | implemented | Closed by runner tests: pass counts, failures, replayed generated values, notes, assumptions, user errors, target scores, and structured CheckResult/testProperty behavior. |
| TestCase.note | test_case.h:64-70 | TestCase.note src/root.zig src/root.zig | intentional Zig redesign | Closed by runner tests: pass counts, failures, replayed generated values, notes, assumptions, user errors, target scores, and structured CheckResult/testProperty behavior. |
