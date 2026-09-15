# This is a AUR (Arch Linux) helper written in Zig.

Goals:
- All operations scoped within ~/.zur
- File operations are generally explicit
- Minimal user input, though always surface key install info for the user to
review
- All log statements are debug level, this is a CLI application

# Zig Coding Style Guide

Shared conventions, including the [Zig language reference style
guide](https://ziglang.org/documentation/master/#Style-Guide). `zig fmt` is the
last word on indentation, braces, and punctuation. It does not wrap to a column
limit — aim for 100, use common sense. Keep short function calls and parameter
lists inline when readable. Data lists longer than two items go one item per
line, with a trailing comma.

This document covers the choices the formatter cannot make.

---

## Files and modules

The filename signals the module's purpose. Declaration visibility is
controlled by `pub`, not by the filename.

| Kind of file | Name | Shape |
|---|---|---|
| The file **is** a type | `TitleCase.zig` | `const Foo = @This();` plus fields at file scope |
| Namespace of functions or peer types | `snake_case.zig` | no file-scope fields |
| Generic type factory | `snake_case.zig` | exports a TitleCase function returning a type |

When a module represents one concrete struct, make the file itself that type.
Namespaces and factory modules use snake_case even if they export just one
type. Enums and unions remain declarations in a namespace or containing type;
a source file itself is a struct.

Directory names are `snake_case`. The exception is the sibling folder of a
TitleCase type file, which keeps the type's name so the path matches the
fully-qualified name (FQN):

```
Foo.zig          // the type / façade
Foo/
  Bar.zig        // another type, re-exported as Foo.Bar
  helper.zig     // usually private
```

When a named concern outgrows one file, keep a public entry module (the façade)
and put its implementation files in a sibling directory. A namespace follows
the same pattern with snake_case, such as `parser.zig` and `parser/`. Split on
the concern, not on file length. Small nested types stay in the parent.
External callers import the façade and write `Foo.Bar`; implementation files
within the same component may import one another directly.

`usingnamespace` does not appear. Re-export names explicitly:

```zig
pub const Bar = @import("Foo/Bar.zig");
const helper = @import("Foo/helper.zig");
pub const doThing = helper.doThing;
```

Do not flatten a child's entire namespace into the parent.

`@This()` aliases:

- File-as-type: `const Foo = @This();` then use `Foo` in signatures.
- Generic factory: `const Self = @This();`.
- Named nested struct: use its declared name; another alias is unnecessary.

Keep ordinary imports in a preamble: `std` and `builtin`, aliases from them,
then project imports. File paths are relative to the importing file. Named
modules such as `std` or a build-provided package name are not file paths.
Test-only imports may appear in test blocks, including blocks that collect
child-module tests. Keep production dependencies out of those blocks.

---

## Naming

| Kind | Style | Examples |
|---|---|---|
| Types, type aliases, unions, enums, error sets | TitleCase | `Widget`, `OpenOptions`, `ResolveError` |
| Namespace struct used only to group declarations | snake_case | `json`, `mem` |
| Type function (`fn (...) type`) | TitleCase | `ArrayList`, `ShortList` |
| Other functions | camelCase | `toSlice`, `hasRuntimeBits` |
| Fields, locals, log scopes, other constants | snake_case | `root_src_path`, `default_quota` |
| Enum / union tags | snake_case | `.in_progress`, `.out_of_memory` |
| Comptime type params | short TitleCase | `T`, `K`, `V`, `Child` |
| Comptime value params | snake_case | `fixed_size`, `n` |

Aliases use the style of the declaration they expose: TitleCase for types and
type factories, camelCase for other functions, and snake_case for namespaces.

Error values describe **why**, such as `OutOfMemory` or `IndexOutOfBounds`.
Avoid names such as `Failed` or `AddFailed` that only repeat the operation.

Do not put these words in type names: `Value`, `Data`, `Context`, `Manager`,
`State`, `utils`, `misc`, or somebody's initials. Everything is a value;
nothing is communicated. The `Context` parameter on `std.HashMap` is an
established exception — do not invent more. Declarations tempted toward
`utils` belong at the root of the module that needs them.

Name from the fully-qualified namespace. Do not repeat a segment:
`json.Token`, not `json.JsonToken`. Files are part of that namespace.

No underscore prefixes. Zig has no private fields; do not pretend otherwise.
Name fields by their meaning and document the invariants. Keyword collisions
use `@"if"` syntax, not `_if`. Prefer a longer name at an outer scope and a
shorter one inside, rather than `foo` and `_foo`.

Acronyms, initialisms, and proper nouns follow the same case rules as any
other word: `XmlParser`, `readU32Be`, `xml_document`. Two-letter acronyms
are not special. Names mandated by a language hook, dependency interface, or
foreign ABI retain their required spelling, such as `ENOENT`.

---

## Types

A file-as-type puts its imports and `@This()` alias in the preamble, followed
by fields, nested types, and methods. Imported type aliases and re-exports
belong with the imports; locally defined nested types follow the fields.
Types extracted to their own files become
`pub const Child = @import("Parent/Child.zig");`.

Give a field a default only when it remains valid independently of overrides
to other fields. When fields must agree, use an initializer or a named whole
value such as `.empty`. Require callers to supply options that have no safe
general default. Group related or easily confused arguments in an options
struct; unrelated dependencies can remain positional.

Initialize unmanaged containers with their provided `.empty` value. The forms
`.empty` and `.init` can be declaration literals selecting named values;
`.init(args)` calls an initializer and can perform work or fail. Prefer these
forms when the expected type is known; otherwise spell out `Type.empty` or
`Type.init(args)`. Use them only when that declaration exists on the type.
See [declaration literals](https://ziglang.org/download/0.14.0/release-notes.html#Decl-Literals).

| Form | When |
|---|---|
| `enum` / `enum(uN)` | Closed classification, no payload |
| `union(enum)` | One-of with payload |
| `packed struct(uN)` | Flags or values stored as a single integer |
| `extern struct` | C-compatible layout for the selected target |

Always specify the backing integer on packed structs. Pad unused bits
explicitly.

An `extern struct` alone does not define a portable disk or wire format;
those formats also need explicit padding, byte order, and layout checks.

On a tagged union, unit variants are bare tags (`crash`). Use inline structs
for multi-field payloads unless the payload type is shared independently.

---

## Memory and ownership

Unmanaged lists and maps do not store an allocator. Pass an allocator to
operations that allocate or release storage, as required by their API.
Mutation within existing storage does not inherently require an allocator.

`init` prepares a value and may allocate resources it owns. It can return the
initialized value or initialize caller-provided `*T` storage; use the latter
when initialization requires the object's final address. `deinit` releases
owned resources while leaving the struct's storage to its owner.

After `deinit`, treat the value as invalid until reinitialized. In `deinit`
implementations you own, poison the receiver after cleanup:

```zig
thing.items.deinit(gpa);
thing.* = undefined;
```

Methods take the receiver first. Free functions put comptime type parameters
before runtime arguments, and allocator arguments before other runtime inputs.

Validate inputs and reserve capacity before committing changes that cannot be
rolled back. Put `errdefer` immediately after acquiring a resource this scope
still owns on error. Use `defer` for a temporary resource needed only in this
scope. Release resources in reverse acquisition order.

For example, inside a function returning an index, suppose `table.add` takes
ownership only on success and table entries cannot be removed:

```zig
const ptr = try gpa.create(T);
errdefer gpa.destroy(ptr);
ptr.* = initial_value;

const index = try table.add(gpa, ptr);
errdefer comptime unreachable;
return index;
```

The final `errdefer` requires the remainder of the scope to have no reachable
error return after ownership transfers. It does not provide rollback. If more
fallible work is needed, move it before the transfer or implement rollback.

Write down who owns a pointer and what happens on error. Default string type
is `[]const u8`. Use a sentinel only when a consumer requires it.

Keep one authoritative representation of mutable state. Avoid unnecessary
aliases and cached copies that can get out of sync. Declare variables in the
smallest practical scope, only when needed. Calculate and validate values
close to where they are used, minimizing the gap between checking and use.

---

## Errors

For public APIs that return errors, declare named, closed error sets. Include
only failures the API can return and merge sets with `||`. Inferred `!T` is
fine on private helpers and program entry points. An interface that mandates a particular
error type keeps that signature; otherwise do not add `anyerror` to core APIs.

```zig
pub const AddError =
    Allocator.Error ||
    error{
        CollectionFull,
        DuplicateItem,
    };
```

| Situation | Shape |
|---|---|
| Absence is normal | `?T` |
| Recoverable failure | named error |
| Impossible / programmer bug | `assert` or `unreachable` |

`error.OutOfMemory` is first-class. Propagate it on library APIs. Do not hide
it in `else =>`.

Validate external input and report invalid input as an error. Assertions and
`unreachable` express internal contracts; they do not replace required input
validation or recoverable error handling.

---

## Control flow

Guard early, then do the work. Flatten with `continue` / `return` / `orelse`.
Use `var` only when the variable itself is mutated, including mutation through
`&variable`. A pointer binding remains `const` when only its pointee changes.

Centralize workflow decisions and changes to shared domain state in the parent
function. Push `if`s up and `for`s down: let the parent select the operation
and helpers carry it out. Helpers retain the local checks and branches needed
for their own contracts.

Keep leaf computation helpers pure: results depend on explicit inputs, with
no hidden mutation or I/O. Container mutation, allocation, and I/O APIs are
explicitly effectful operations. Choose the simplest return type that fully
expresses the contract, preserving meaningful absence and failure states.

Labeled blocks name the **result**, not `blk`:

```zig
const target = target: {
    const result = b.standardTargetOptions(.{});
    if (result.result.os.tag == .ios) return error.UnsupportedTarget;
    break :target result;
};
```

Use `if (comptime cond)` for compile-time OS and feature selection.

List every tag when switching over a closed classification so new tags require
a decision. Default arms are appropriate only for the following cases:

- `else => unreachable` when an established internal invariant rules out all
  remaining tags. Explain that invariant if it is not obvious.
- `inline else` when the same operation works for every remaining case but
  requires specialization for each case's type or compile-time value.
- An explicit rejection or fallback for open inputs, such as integers or
  non-exhaustive enums. Invalid external values are not unreachable.

Use `comptime unreachable` only in branches compile-time specialization must
eliminate, or in `errdefer` to forbid subsequent reachable error returns.
Runtime-impossible branches use ordinary `unreachable`.

Use `@branchHint(.cold)` on failure paths and other known rare cases in hot
functions; a case is not necessarily rare just because it returns an error.

---

## Assertions

| Mechanism | Use |
|---|---|
| `assert(cond)` | Internal invariant; violation is illegal behavior |
| `unreachable` | Impossible control-flow path; reaching it is illegal behavior |
| `return error.X` | Recoverable failure |

Here `assert` means `std.debug.assert`. Runtime safety settings determine
whether these violations are detected or become unchecked illegal behavior;
do not rely on them to report recoverable failures in every build mode.
Use `std.testing.expect*` for test expectations.

If profiling shows expensive assertion-only setup survives optimization, gate
both that setup and its assertion with the project's compile-time verification
option. Keep required validation and state changes outside the gate.
`std.debug.runtime_safety` describes the standard library's build mode and is
deprecated as a query for the caller's settings. A module's `builtin.mode`
can define a default verification policy, but does not report local
`@setRuntimeSafety` overrides. See the [standard-library definition][debug-safety].

Use `@compileError` for unsupported targets detected while compiling a module
and for misused comptime APIs. Invalid options supplied to a running build
script or application are configuration errors, handled through its error API.

---

## comptime and generics

Typical uses:

1. Type functions — `pub fn Name(comptime T: type, ...) type`.
2. Invariant checks in the type body — `comptime { assert(...); }`.
3. Backend / feature selection — `switch` or `if` on a comptime option.
4. `inline for` or inline switch prongs when each iteration or case needs
   compile-time specialization.

`@setEvalBranchQuota` sits next to the loop that needs it, not at the top of
the file by habit.

Optional subsystems are compile-time capabilities. Use `void` or `struct {}`
for storage that disappears when a feature is disabled, and guard operations
on it with the same compile-time condition. If callers need an unconditional
interface, supply a no-op implementation with the required methods; an empty
type alone does not provide those methods. Keep the feature's module available
to imports in either configuration.

Prefer a comptime type parameter or a tagged union for internal polymorphism.
Do not invent a vtable when either of those will do.

---

## Performance

Design for performance before profiling is possible. Sketch bandwidth and
latency costs for network, disk, memory, and CPU. Prioritize the slowest
resource after accounting for how often it is used. Address known latency
spikes and exponential algorithms during design; use measurements to check
the model as the implementation becomes available.

Batch work to amortize network, disk, memory, and CPU overhead while respecting
the operation's ordering, latency, and memory requirements. Separate the
control plane (deciding what work to do) from the data plane (processing the
data). Move operation selection out of inner loops so each batch can run
through a predictable loop over similar items.

Express the intended fast path directly. Extract hot loops into standalone
functions with primitive arguments and buffers, keeping their inputs explicit.
Choose memory layouts for the access pattern. Consider cache-line alignment,
contiguous storage, separate arrays for frequently accessed fields,
prefetching, and SIMD (one instruction processing several values). Validate
these choices with measurements. Make data access and computation clear enough
that both the reader and the compiler can identify redundant work without
having to reason through an entire receiver object.

---

## Comments

| Form | Use |
|---|---|
| `//!` | File or package purpose. One short paragraph. Not a changelog. |
| `///` | Public API: contract, ownership, when `null` is legal |
| `//` | Why, constraints, the surprising or load-bearing line below |

Explain contract, ownership, and why — not the next three obvious lines.

Omit anything the name already says. Copy a real contract onto each similar
function — IDEs show one declaration at a time.

In `///` comments:

- **assume** — the caller must uphold this precondition; the API does not
  promise a runtime check. Violation is illegal behavior.
- **assert** — the implementation checks this precondition with an assertion;
  detection depends on the applicable runtime safety settings.

Use these words only when the implementation matches the stated contract.
State recoverable validation errors separately.

A comment that a reader already knows from the identifiers and the code
has no job. If it would still be true as a caption of the next line, delete
it:

```zig
// Adds 1 to a
a += 1;
```

The same bar applies to test comments that only restate the `expect` below
them, and to function headers that repeat the function name.

`// TODO:` says what is missing and what blocks it. Do not file a TODO that
just says "fix this."

---

## Logging

Files that emit log messages use a subsystem-scoped logger:

```zig
const log = std.log.scoped(.foo);
```

Scope names are `snake_case` and match the subsystem (`.foo`, `.foo_detail`).

---

## Tests

Unit tests live with the implementation, at the bottom of the file or just
after the small type they exercise. Integration and end-to-end tests may live
in separate suites that own their shared setup. Test placement does not
determine which test level to choose.

Use `std.testing.allocator` for allocations owned by an in-process test and
register cleanup immediately. Name behavioral tests with descriptive strings
that identify the behavior and work as substring filters. For example:

```zig
const std = @import("std");

test "append preserves insertion order" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var items: std.ArrayListUnmanaged(u8) = .empty;
    defer items.deinit(gpa);

    try items.append(gpa, 7);
    try items.append(gpa, 3);
    try testing.expectEqualSlices(u8, &.{ 7, 3 }, items.items);
}
```

Use the repository's test command. Direct `zig test` supports
`--test-filter "substring"`; a `zig build` option such as `-Dtest-filter`
exists only when the project's build script defines it.

`test { _ = @import("child.zig"); }` pulls a child file into the test binary.
Anonymous test blocks are reserved for collecting imports, rather than for
behavioral test cases.
Skip unavailable platforms or features with `return error.SkipZigTest`.

Tests are durable specifications. Do not delete, weaken, or rewrite an existing
test merely to make a bug fix or behavior change pass. Change a test only when
the intended contract changes or a refactor forces a structural change; preserve
its behavioral coverage and state why the test had to change.

Regression tests are stricter still. A regression test must reproduce the
reported failure, fail against the code before the fix, and pass after the fix
without being changed between those runs. Afterwards, preserve the regression
scenario and its behavioral coverage through refactors. Adapt expectations
only for a deliberate contract change, explaining why; remove the coverage
only when the tested contract is deliberately removed. If the failure cannot
be demonstrated before the fix, explain why and test the nearest externally
observable invariant.

Every behavioral test must distinguish a plausible broken implementation from
a correct one. Do not add tautological tests, assertions derived by repeating
the production logic, or checks equivalent to proving `1 + 1 == 2`. Assert
meaningful behavior, state transitions, side effects, error handling, or
boundary conditions.

Use the highest practical test level: prefer end-to-end tests over integration
tests, and integration tests over unit tests. Use a lower level when the higher
level cannot exercise the behavior reliably, would make the failure materially
harder to diagnose, or is too expensive for routine validation.

---

## Commits

Use the following Linux-inspired commit-message format:

- Use an imperative subject in the form `subsystem: concise summary`. Keep it
  under 75 characters and do not end it with a period.
- Separate the subject from the body with a blank line.
- For a non-trivial change, explain the existing behavior or problem first and
  why it matters. Then explain how the change resolves it and note important
  constraints or tradeoffs.
- Describe the reason for the change instead of restating the diff. Keep each
  commit to one logical change and wrap body text at about 75 columns.

---

## Checklist

1. Apply repository-specific rules first and use the pinned toolchain.
2. File-as-struct types use `Name.zig`; namespaces and factories use snake_case.
3. Match sibling directory names to their façade; external callers use that façade.
4. Use the specified `@This()` alias and keep ordinary imports in the preamble.
5. Follow the naming table, banned-name rules, and required external spelling exceptions.
6. Keep fields before locally defined nested types and methods; defaults preserve invariants.
7. Distinguish named initial values from initializer calls; use the type's actual API.
8. Pass allocators where storage is allocated or released; document ownership transfers.
9. Choose value-returning or in-place `init` deliberately; treat deinitialized values as invalid.
10. Pair owned acquisitions with cleanup. After an irreversible ownership transfer,
    allow no further error returns.
11. Use `[]const u8` unless a consumer requires a sentinel.
12. Use named public error sets, optionals for absence, and errors for recoverable failures.
13. Reserve assertions and unreachable paths for internal contracts; account for safety settings.
14. Keep scopes small and checks close to use; avoid duplicate mutable representations.
15. Centralize workflow decisions; keep computation helpers pure and side effects explicit.
16. Preserve meaningful absence and failure states when simplifying return types.
17. Specialize generics deliberately; disabled capabilities use guarded or no-op interfaces.
18. Sketch resource costs during design and validate the model with measurements.
19. Batch within latency, ordering, and memory requirements; keep control decisions
    outside hot loops.
20. Give hot loops explicit inputs and choose memory layouts for their access patterns.
21. Write useful contracts and rationale; use assumption/assertion terminology accurately.
22. Scope log messages to their subsystem.
23. Use the highest practical test level, appropriate placement, and behavioral assertions.
24. Preserve regression coverage and use the same test for the before-fix/after-fix comparison.
25. Use the documented commit format, explain why, and keep commits to one logical change.
26. Run `zig fmt`, keep short calls and parameter lists inline, wrap data lists over two items,
    and aim for 100 columns using common sense.

[debug-safety]: https://github.com/ziglang/zig/blob/0.14.1/lib/std/debug.zig#L161-L167
