# Latch Specification

This document defines the Latch document format for literate patches and
its patch application semantics.

The goal of Latch is to let a literate patch carry both narrative
explanation and machine-applicable patches.

## Status

This specification is normative for Latch document parsing, patch
assembly, dependency ordering, and application semantics.

`latch draft` is non-normative convenience tooling. It helps authors
produce Latch documents, but the exact draft layout is not part of the
format contract.

## Terms

- A **Latch document** is a Markdown document that contains one or more
  patch fences. A Latch document is a literate patch.
- A **patch fence** is a fenced code block recognized as a patch by the
  rules in this specification.
- A **patch fragment** is one patch fence before fragment assembly.
- A **patch** is the assembled unit identified by an `id`.

## Patch Fence Recognition

A fenced code block is a patch fence if and only if its info string
starts with `diff`.

Info strings that begin with another language name are ignored by the
Latch parser, even if the fence body looks like a unified diff.

Patch fences may appear anywhere in the Markdown document.

## Fence Metadata Grammar

After the leading `diff` token, the remainder of the info string is
parsed as space-separated `key=value` tokens.

Example:

````md
```diff id=core depends-on=setup,tests part=2
diff --git a/src/main.zig b/src/main.zig
...
```
````

Supported keys:

- `id`
  Required. Names the logical patch.
- `depends-on`
  Optional. Contains a comma-separated list of patch ids.
- `part`
  Optional. Contains a base-10 positive integer.

Unsupported metadata keys are invalid.

Metadata tokens that are not in `key=value` form are invalid.

An `id` is invalid if it is omitted or empty.

A `part` value is invalid if it is not a positive integer.

For `depends-on`, commas separate dependency ids. Empty dependency
entries produced by trimming whitespace are ignored.

## Patch Fragment Assembly

Each patch fence produces one patch fragment with:

- an `id`
- zero or more dependencies
- an optional `part`
- a diff body taken from the fence contents

Fragments are grouped by `id`.

If an `id` appears in exactly one fragment and that fragment has no
`part`, that fragment becomes one patch unchanged.

If an `id` appears in multiple fragments:

- at least one fragment having no `part` is invalid
- all fragments must have `part`
- `part` values must form a contiguous sequence `1..N`
- each `part` value may appear at most once

Fragments belonging to the same patch are assembled in `part` order by
concatenating their diff bodies.

If a split patch declares `depends-on`, it must do so only on `part=1`.
Dependencies on later parts are invalid.

## Patch Ordering

Assembled patches are ordered by dependency, not by Markdown position.

The dependency graph is formed from each patch `id` and its
`depends-on` list.

The document is invalid if:

- a patch depends on an unknown patch id
- a patch depends on itself
- the dependency graph contains a cycle

When multiple patches are ready to apply at the same time, the next
patch is chosen by lexical ordering of `id`.

## Application Semantics

Each assembled patch is applied in dependency order to a target tree.

The diff body of each patch is interpreted as a unified diff. If the
body does not end in a trailing newline, one newline is appended before
application.

If patch application fails for any patch, application stops and the
document is not considered successfully applied.

## Validation Summary

A Latch document is invalid if any of the following hold:

- it contains no patch fences
- a patch fence is missing `id`
- a patch fence uses unsupported metadata
- a metadata token is not in `key=value` form
- `part` is missing from one or more fragments of a split patch
- `part` is repeated within one patch
- `part` is zero, non-numeric, or outside the contiguous `1..N` range
- `depends-on` appears on a split fragment other than `part=1`
- duplicate unsplit patches share the same `id`
- a dependency refers to an unknown patch id
- a patch depends on itself
- dependencies contain a cycle

## Minimal Example

````md
# Add JSON output

The first patch updates tests to make the contract explicit.

```diff id=tests
diff --git a/test/cli_test.zig b/test/cli_test.zig
...
```

The second patch implements the flag handling.

```diff id=impl depends-on=tests
diff --git a/src/cli.zig b/src/cli.zig
...
```
````
