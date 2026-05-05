# Latch Specification

This document defines the Latch document format for literate patches and
its patch application semantics.

The goal of Latch is to let a literate patch carry both narrative
explanation and machine-applicable patches.

## Status

This specification is normative for Latch document parsing, patch
assembly, dependency ordering, review extraction, and application
semantics.

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
- A **review fence** is a fenced code block recognized as reviewer
  commentary by the rules in this specification.
- A **review** is one review fence after review metadata has been parsed.
- A **compact Latch recipe** is Markdown stored in a Git commit body that
  contains `latch-ref` fences instead of executable `diff` fences.
- A **latch-ref fence** is a compact placeholder for a diff fence. It is
  expanded from the commit's canonical parent diff by `latch show`.

## Patch Fence Recognition

A fenced code block is a patch fence if and only if its info string
starts with `diff`.

Info strings that begin with another language name are ignored by the
Latch parser, even if the fence body looks like a unified diff.

Patch fences may appear anywhere in the Markdown document.

Review fences and other non-patch content do not affect patch parsing,
assembly, ordering, or application.

## Review Fence Recognition

A fenced code block is a review fence if and only if its info string
starts with `review`.

Info strings that begin with another language name are ignored by review
extraction, even if the fence body looks like reviewer commentary.

Review fences may appear anywhere in the Markdown document. They are
non-executable reviewer commentary. They are ignored by patch assembly
and `latch apply`.

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

Unsupported metadata keys are invalid for patch fences.

Metadata tokens that are not in `key=value` form are invalid.

An `id` is invalid if it is omitted or empty.

A `part` value is invalid if it is not a positive integer.

For `depends-on`, commas separate dependency ids. Empty dependency
entries produced by trimming whitespace are ignored.

## Review Metadata Grammar

After the leading `review` token, the remainder of the info string is
parsed as space-separated `key=value` tokens.

Example:

````md
```review reviewer=tim@timculverhouse.com id=core
Can this diagnostic include the unsupported metadata key?
```
````

All metadata keys are allowed on review fences. The `id` key has special
meaning: it names the patch id that the review targets. If `id` is
omitted, the review targets the document as a whole.

An `id` value is invalid for review extraction if it is present but
empty. If multiple `id` tokens appear, the last `id` token determines
the review target. Consumers should preserve all review metadata tokens
in source order.

Metadata tokens that are not in `key=value` form are invalid for review
extraction, but they do not affect patch parsing or application because
review fences are non-executable.

Review fence bodies are reviewer-authored text. If a review body needs
to contain a fenced code block, use a longer outer fence:

`````md
````review id=core
Consider this shape:

```zig
try run();
```
````
`````

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

## Review Extraction

Review extraction collects every review fence in Markdown order. Each
review contains:

- an optional target `id`
- all metadata tokens in source order
- a body taken from the fence contents
- the source line range of the fence, when available

Review extraction does not require the document to contain patch fences.
Review extraction does not validate that a review target `id` refers to
an existing patch id.

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

## Compact Git Carriage

A compact Latch commit stores the code change in the normal Git commit
tree and a compact Latch recipe in the Git commit message body. The
first H1 of the source Latch document becomes the Git commit subject;
the stored recipe omits that H1. `latch show` restores the subject as an
H1 before expanding the recipe.

A compact recipe uses fenced code blocks whose info string starts with
`latch-ref`. A `latch-ref` fence supports the normal patch metadata
keys `id`, `depends-on`, and `part`, plus a required `ranges` key.
Unsupported metadata keys are invalid.

The `ranges` value is a comma-separated list of line ranges:

```text
ranges=<block>:<start>..<end>[,<block>:<start>..<end>...]
```

- `block` is a 1-based canonical diff block index.
- `start` is a 1-based line number within that block.
- `end` is a 1-based line number or `$` for the final line of that
  block.
- line ranges are inclusive.

For compact carriage, the canonical parent diff is produced with
`--no-ext-diff`, `--no-color`, `--no-renames`,
`--diff-algorithm=histogram`, `--no-indent-heuristic`, `--unified=3`,
`--src-prefix=a/`, and `--dst-prefix=b/`, then split into canonical diff
blocks. A block is either a whole file diff with no hunks, or one file
prelude plus one hunk. This mirrors the block structure emitted by
`latch draft`.

`latch show <commit>` reconstructs a full Latch document by replacing
each `latch-ref` fence with a `diff` fence carrying the same `id`,
`depends-on`, and `part` metadata. The diff fence body is the
concatenation of the referenced canonical block line ranges.

Compact carriage can represent arbitrary splits on diff line boundaries.
It cannot represent Latch patches whose intermediate diff text is not
present in the final parent-to-commit diff.

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

For review extraction, a review fence is invalid if any metadata token
after `review` is not in `key=value` form or if it contains an empty
`id=` value. Review-fence errors do not make patch parsing or
application invalid.

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
