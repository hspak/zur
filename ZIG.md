# Zig Coding Style Guide

Shared conventions, including the [Zig language reference style
guide](https://ziglang.org/documentation/master/#Style-Guide). `zig fmt` is the
last word on indentation, braces, and punctuation. It does not wrap to a column
limit — aim for 100, use common sense. A list longer than two items goes one
per line, with a trailing comma.

This document covers the choices the formatter cannot make.

---

## Files and modules

The filename is a visibility signal.

| Kind of file | Name | Shape |
|---|---|---|
| The file **is** a type | `TitleCase.zig` | `const Foo = @This();` plus fields at file scope |
| Namespace of functions or peer types | `snake_case.zig` | no file-scope fields |
| Generic type factory | `snake_case.zig` | `pub fn Name(...) type { return struct { const Self = @This(); ... }; }` |

Do not invent a TitleCase file for a bag of free functions, and do not invent
a snake_case file for a primary datatype.

Directory names are `snake_case`. The exception is the sibling folder of a
TitleCase type file, which keeps the type's name so the path matches the FQN:

```
Foo.zig          // the type / façade
Foo/
  Bar.zig        // another type, re-exported as Foo.Bar
  helper.zig     // usually private
```

When a named concern outgrows one file, keep that sibling façade and nest
children under it. Split on the concern, not on file length. Small nested
types stay in the parent. Callers import the parent and write `Foo.Bar`.

`usingnamespace` does not appear. Re-export names explicitly:

```zig
pub const Config = @import("Foo/Config.zig");
const helper = @import("Foo/helper.zig");
pub const doThing = helper.doThing;
```

Do not flatten a child's entire namespace into the parent.

`@This()` aliases:

- File-as-type: `const Foo = @This();` then use `Foo` in signatures.
- Generic factory: `const Self = @This();`.

Keep imports in one block. `std` (and aliases peeled from it) before project
imports. Paths are filesystem-relative to the importing file. Do not put
imports in the middle of the file.

---

## Naming

| Kind | Style | Examples |
|---|---|---|
| Types, type aliases, unions, enums, error sets | TitleCase | `Widget`, `OpenOptions`, `ResolveError` |
| Namespace: 0-field struct, never instantiated | snake_case | `json`, `mem` |
| Type function (`fn (...) type`) | TitleCase | `ArrayList`, `ShortList` |
| Other functions | camelCase | `toSlice`, `hasRuntimeBits` |
| Fields, locals, log scopes, constants | snake_case | `root_src_path`, `default_quota` |
| Enum / union tags | snake_case | `.in_progress`, `.out_of_memory` |
| Comptime type params | short TitleCase | `T`, `K`, `V`, `Child` |
| Comptime value params | snake_case | `fixed_size`, `n` |

Error names describe **why** (`OutOfMemory`, `IndexOutOfBounds`), not `Failed`.

Do not put these words in type names: `Value`, `Data`, `Context`, `Manager`,
`State`, `utils`, `misc`, or somebody's initials. Everything is a value;
nothing is communicated. The `Context` parameter on `std.HashMap` is an
established exception — do not invent more. Declarations tempted toward
`utils` belong at the root of the module that needs them.

Name from the fully-qualified namespace. Do not repeat a segment:
`json.Value`, not `json.JsonValue`. Files are part of that namespace.

No underscore prefixes. Zig has no private fields; do not pretend otherwise.
Name fields by their meaning and document the invariants. Keyword collisions
use `@"if"` syntax, not `_if`. Prefer a longer name at an outer scope and a
shorter one inside, rather than `foo` and `_foo`.

Acronyms, initialisms, and proper nouns follow the same case rules as any
other word: `XmlParser`, `readU32Be`, `xml_document`. Two-letter acronyms
are not special. Follow an established exception such as `ENOENT`.

---

## Types

A file-as-type keeps fields first, then nested types, then methods. Nested
types that deserve their own file become
`pub const Child = @import("Parent/Child.zig");`.

Give fields defaults so a short literal is enough. Options bags are their own
struct rather than a long parameter list. Unmanaged containers default to
`.empty`. Prefer enum literals (`.empty`, `.init`) over calling constructors.

| Form | When |
|---|---|
| `enum` / `enum(uN)` | Closed classification, no payload |
| `union(enum)` | One-of with payload |
| `packed struct(uN)` | Flags or values stored as a single integer |
| `extern struct` | Stable memory image or C layout |

Always specify the backing integer on packed structs. Pad unused bits
explicitly.

On a tagged union, unit variants are bare tags (`crash`), not `crash: void`,
unless symmetry requires it. Multi-field payloads are inline structs.

---

## Memory and ownership

Unmanaged lists and maps do not store an allocator. Pass it into every
mutating call and into `deinit`.

`init` initializes existing storage. `deinit` frees owned resources, not the
struct itself. After `deinit`, poison the value:

```zig
thing.items.deinit(gpa);
thing.* = undefined;
```

Methods take the receiver first. Free functions take allocator(s) before
inputs.

Reserve capacity before fallible work you cannot roll back. `errdefer`
immediately under the line that acquired the resource. Cleanup is the inverse
of the last successful step. If rollback is impossible:

```zig
const ptr = try gpa.create(T);
errdefer gpa.destroy(ptr);

const index = try table.add(gpa, ptr);
errdefer comptime unreachable; // table entries are not removed
```

Write down who owns a pointer and what happens on error. Default string type
is `[]const u8`. Use a sentinel only when a consumer requires it.

---

## Errors

Named, closed sets at API boundaries. Merge with `||`. Inferred `!T` is fine
on local helpers. Do not put `anyerror` on new core APIs.

```zig
pub const AddError =
    Allocator.Error ||
    error{
        CollectionFull,
        SetSizeFailed,
    };
```

| Situation | Shape |
|---|---|
| Absence is normal | `?T` |
| Recoverable failure | named error |
| Impossible / programmer bug | `assert` or `unreachable` |

`error.OutOfMemory` is first-class. Propagate it on library APIs. Do not hide
it in `else =>`.

---

## Control flow

Guard early, then do the work. Flatten with `continue` / `return` / `orelse`.
`const` unless mutated.

Labeled blocks name the **result**, not `blk`:

```zig
const target = target: {
    var result = b.standardTargetOptions(.{});
    if (result.result.os.tag == .ios) return error.UnsupportedTarget;
    break :target result;
};
```

`if (comptime cond)` for compile-time OS and feature cuts.

Switches are exhaustive. Prefer listing every tag.

- `else => unreachable` when remaining tags are a programmer error.
- `inline else` when each prong instantiates a different type.
- Comment the unreachable arm when it is not obvious why.
- `comptime unreachable` for type-level impossible arms and for `errdefer`
  that must never fire.

`@branchHint(.cold)` on fail paths and other rare cases in hot functions.

---

## Assertions

| Mechanism | Use |
|---|---|
| `assert(cond)` | Safety-checked internal invariant |
| `unreachable` | Switch/tag that cannot happen |
| `return error.X` | Recoverable failure |

If setup around an assert is expensive and has been seen to survive
ReleaseFast, wrap it in `std.debug.runtime_safety`.

Unsupported platforms and misused comptime APIs are `@compileError`.

---

## comptime and generics

Typical uses:

1. Type functions — `pub fn Name(comptime T: type, ...) type`.
2. Invariant checks in the type body — `comptime { assert(...); }`.
3. Backend / feature selection — `switch` or `if` on a comptime option.
4. `inline for` / `inline switch` when each prong is a different type.

`@setEvalBranchQuota` sits next to the loop that needs it, not at the top of
the file by habit.

Optional subsystems are compile-time capabilities. Disabled features become
`void` or a dummy `struct {}` so call sites still type-check; they are not a
missing import.

Prefer a comptime type parameter or a tagged union for internal polymorphism.
Do not invent a vtable when either of those will do.

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

- **assume** — violating this is unchecked Illegal Behavior
- **assert** — violating this is safety-checked Illegal Behavior

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

Every substantial file has a scoped logger:

```zig
const log = std.log.scoped(.foo);
```

Scope names are `snake_case` and match the subsystem (`.foo`, `.foo_detail`).

---

## Tests

Tests live in the same file, at the bottom (or immediately after a small
type). Use `std.testing.allocator` and `defer` immediately after every
resource. Name tests with a descriptive string, written for `-Dtest-filter=`:

```zig
test "put evicts the oldest" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var set = try WidgetSet.init(gpa, 2);
    defer set.deinit(gpa);
    // ...
    try testing.expectEqual(@as(usize, 2), set.items.items.len);
}
```

`test { _ = @import("child.zig"); }` pulls a child file into the test binary.
Skip unavailable platforms or features with `return error.SkipZigTest`.

---

## Checklist

1. One primary type? `Name.zig` + `const Name = @This();`. Otherwise `snake_name.zig`.
2. Directories are `snake_case`, except the sibling folder of a TitleCase type file.
3. Cross-package import goes through the parent façade.
4. Names come from the FQN: no repeated segment, no `Value`/`Data`/`Context`/`Manager`/`State`/`utils`, no `_` prefix. Acronyms are ordinary words.
5. Type functions are TitleCase; namespace structs are snake_case.
6. `//!` / `///` explain contract and why; `//` is for the surprising line below. Delete comments that add no information. Copy real contracts onto similar functions. **assume** vs **assert** in `///`.
7. Unmanaged collections take an allocator on each mutating call and on `deinit`.
8. `init` / `deinit` for values; poison after `deinit`.
9. Named error sets composed with `Allocator.Error || error{...}`.
10. `?T` for absence; errors for invalid / OOM; defaults on fields.
11. Packed structs have an explicit backing integer and explicit padding.
12. Generics are `fn Name(comptime T: type) type`. Prefer comptime or a tagged union over a vtable.
13. `errdefer` under every acquire; `comptime unreachable` when rollback cannot happen.
14. Document who frees what.
15. `[]const u8` unless a sentinel is required.
16. Tests are in-file, named for `-Dtest-filter`, `defer` immediately.
17. Aim for 100 columns; `zig fmt`.
