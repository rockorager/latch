---
name: latch
description: Use when turning code changes into a literate patch narrative, or when asked to write a code story for a diff
---

# Latch

Use this skill when the task is to present code changes as a readable, runnable
narrative instead of a raw diff.

## Purpose

`latch` turns a diff into a Markdown document with `diff` fences. The generated
draft is mechanical, but it already includes the patch bodies inline inside
those `diff` fences. Your job is to turn that draft into a clear code story
without breaking apply semantics.

## When To Use It

- The user wants a narrative of code changes, not just a diff summary.
- The user asks for a Latch document, literate patch, or code story.
- You have local changes, a commit, a revision range, or a unified diff that
  should become a readable patch document.

## Workflow

1. Collect the change source.
   Run `latch draft [git-spec]` to generate the draft document. By
   default it writes to stdout.
   The output already contains the diff content inside `diff` fences, so
   treat it as an editable first pass, not a blank template.
2. Save the draft under `.latch/` at the repo root.
   Prefer a path like `.latch/change.latch.md`, then edit that file in
   place.
   Example:
   `mkdir -p .latch && latch draft HEAD~1 > .latch/change.latch.md`
3. Treat the generated file as scaffolding.
   It is not the final story, but it does already contain the concrete
   patch text that `latch apply` will use.
4. Rewrite the document into narrative order.
   Start with the clearest explanation of behavior, docs, or externally
   visible effects, then move into internal machinery.
5. Keep the `diff` fences intact.
   Preserve patch ids while moving sections. Only change dependencies
   when the new narrative order no longer matches the generated apply
   order.
6. Treat `review` fences as temporary reviewer instructions.
   Resolve them by updating code, diffs, prose, ordering, or dependencies,
   then remove review fences that have been handled.
7. Add context between fences.
   Explain intent, contracts, and why the change is structured this way.
   If the diff is missing important context, add non-diff code fences.
8. Split patches when the story needs finer structure.
   Reuse the same `id` across multiple fences and add contiguous
   `part=1`, `part=2`, and so on.
9. Apply the document when verification matters.
   Use `latch apply` to materialize the document onto a target tree.

## Authoring Rules

- Reorder sections for comprehension, not diff order.
- Prefer headings that describe behavior or intent.
- Do not narrate every changed line. Summarize the point of each patch.
- Leave tests or proof points near the end unless they explain the
  change best up front.
- Keep `diff` fences as `diff` fences.
- Keep `id=...` stable when moving a patch.
- `depends-on=...` controls apply order, not Markdown position.
- Review fences use `review [id=patch-id]` and are not executable.
- Remove review fences after addressing them unless the user asks to keep
  unresolved comments.
- To split one logical patch across multiple fences, reuse the same `id`
  and add contiguous `part=1`, `part=2`, and so on.
- Split patches wherever the narrative benefits from it. The boundary is
  editorial, not semantic, as long as the parts stay contiguous.
- If a split patch needs `depends-on=...`, put it only on `part=1`.

## Fence Grammar

Latch treats any fenced code block whose info string starts with `diff`
as a patch fence. Preserve this shape:

````md
```diff id=patch-id [depends-on=other-id,another-id] [part=N]
diff --git a/path b/path
...
```
````

- The fence info string starts with `diff`.
- Metadata comes after `diff` as space-separated `key=value` tokens.
- Supported keys are `id`, `depends-on`, and `part`.
- Repeated `id`s are only valid when every repeated fence is a fragment
  of the same logical patch using `part=...`.

## Commands

- `latch draft`: generate a first-pass Latch document from stdin, a Git
  spec, or the current worktree diff.
- `latch apply`: apply patches from a Latch document.
- `latch review`: extract reviewer comments from a Latch document.

## Examples

```sh
mkdir -p .latch
latch draft > .latch/change.latch.md
latch draft HEAD~1 > .latch/change.latch.md
git diff | latch draft > .latch/change.latch.md
latch review .latch/change.latch.md
latch apply .latch/change.latch.md
```
