---
name: latch
description: Use when turning code changes into a literate patch narrative, or when asked to write a code story for a diff
---

# Latch

Use this skill to turn code changes into a readable Markdown patch narrative
that still applies with `latch apply` and can be carried through Git with
`latch commit` / `latch show`.

## When To Use It

Use this skill when any of these are true:

- The user wants a narrative of code changes, not just a diff summary.
- The user asks for a Latch document, literate patch, or code story.
- The user provides local changes, a commit, a revision range, or a unified diff
  that should become a readable patch document.
- The user asks you to revise an existing Latch document or address its review
  fences.

## Create a New Latch Document

Follow these steps in order when you are creating a new Latch document. Do not
start from a blank document; always begin with the mechanical draft from
`latch draft`.

1. Identify the change source.
   - If the user gave a Git spec or revision range, use that spec.
   - If the user gave a unified diff, pipe that diff into `latch draft`.
   - If the user did not name a source, use the current worktree diff.

2. Generate the draft under `.latch/` at the repository root.
   - Create the directory first:
     ```sh
     mkdir -p .latch
     ```
   - For the current worktree, run:
     ```sh
     latch draft > .latch/change.latch.md
     ```
   - For a Git spec, run:
     ```sh
     latch draft <git-spec> > .latch/change.latch.md
     ```
   - For a diff on stdin, run:
     ```sh
     git diff | latch draft > .latch/change.latch.md
     ```
   - Treat this file as the required starting point. It already contains the
     concrete patch text inside `diff` fences.
   - Do not expect review comments in a fresh draft; `review` fences belong to
     a later review pass or an existing Latch document.

3. Read the generated draft before editing it.
   - Find every `diff` fence.
   - Note each fence's `id`, `depends-on`, and `part` metadata.
   - Identify what each patch changes and which patches must apply before
     others.

4. Choose the narrative order.
   - Start with the clearest externally visible behavior, public contract,
     user-facing documentation, or top-level design change.
   - Move through implementation details only after the reader understands the
     behavior.
   - Put tests and proof points near the end unless they explain the change
     best up front.
   - Order sections for comprehension; use `depends-on` to preserve apply order
     when Markdown order differs from patch order.

5. Reorder the draft without breaking patches.
   - Move whole Markdown sections and their associated `diff` fences.
   - Keep each `diff` fence as a `diff` fence.
   - Keep each patch `id` stable when moving it.
   - Do not edit patch bodies unless you are intentionally splitting a patch or
     correcting a real patch problem.
   - Change `depends-on` only when apply order requires it.

6. Rewrite the prose into a code story.
   - Replace mechanical draft prose with explanations of intent, behavior,
     contracts, tradeoffs, and why the change is structured this way.
   - Do not narrate every changed line.
   - Use headings that describe behavior or intent, not file names alone.
   - Add non-diff code fences when extra context helps the reader; never use a
     `diff` fence for non-patch context.

7. Split patches only when the story needs finer structure.
   - Reuse the same `id` for every fragment of the original patch.
   - Add contiguous `part=1`, `part=2`, and so on.
   - Keep all parts of the same patch contiguous in the document.
   - If the split patch needs `depends-on=...`, put it only on `part=1`.
   - Do not split for style alone; split when it improves the reader's path
     through the change.

8. Validate the document when applyability matters.
   - Run:
     ```sh
     latch apply .latch/change.latch.md
     ```
   - Apply onto the appropriate target tree or clean worktree.
   - If apply fails, fix the patch text, fence metadata, split parts, or
     dependencies, then run `latch apply` again.
   - If you do not validate, say so explicitly in the final response.

9. Commit the document only when the user asks.
   - Use:
     ```sh
     latch commit .latch/change.latch.md
     ```
   - `latch commit` creates a Git commit from the Latch document and stores a
     compact recipe in the commit body instead of full diff bodies.
   - The document's first H1 becomes the Git commit subject.
   - The tracked worktree must be clean before running `latch commit`; if it is
     not clean, either ask the user how to proceed or preserve the diff before
     cleaning/resetting.
   - After committing, verify reconstructability when practical:
     ```sh
     latch show > /tmp/change.latch.md
     ```

10. Deliver the result.
   - Provide the path to the finished `.latch/*.latch.md` file, or paste the
     finished Latch document if the user asked for inline output.
   - Mention whether `latch apply` was run successfully.
   - If you ran `latch commit`, report the commit hash and whether `latch show`
     reconstruction was checked.

## Commit and Show Latch Documents

Use this workflow when the user asks to commit a Latch document or reconstruct
one from a compact Latch commit.

1. Commit from a finished Latch document with:
   ```sh
   latch commit .latch/change.latch.md
   ```
   Do not use `git commit` for this workflow; `latch commit` writes the code
   tree and compact Latch recipe together.

2. Reconstruct from the latest compact Latch commit with:
   ```sh
   latch show > .latch/change.latch.md
   ```
   `latch show` defaults to `HEAD`, like `git show`. Use `latch show <commit>`
   for another commit.

3. Prefer `latch show` over `latch draft <commit>` when the commit was created
   by `latch commit`. `latch show` reconstructs the authored narrative;
   `latch draft` only creates a new mechanical draft from the commit diff.

4. A compact recipe contains `latch-ref` fences with `ranges=...`. Do not edit
   those by hand unless you are intentionally working on compact carriage. Use
   `latch show` to materialize normal executable `diff` fences for authoring.

## Revise a Reviewed Latch Document

Use this workflow only when the user gives you an existing Latch document or
asks you to address review fences. Do not run these steps for a fresh
`latch draft` unless review fences have been added after drafting.

1. Open the existing Latch document.
   - Read the document that contains the review comments.
   - Keep its existing `diff` fence ids and patch structure as the baseline.

2. Extract the reviewer instructions.
   - Run:
     ```sh
     latch review <path-to-latch-doc>
     ```
   - Read each `review` fence in the document.
   - Match `review id=patch-id` comments to the corresponding `diff` fence.

3. Address each review comment.
   - Update code, patch text, prose, section order, or `depends-on` metadata as
     needed.
   - Keep reviewer instructions out of executable `diff` fences.
   - Preserve patch ids unless the review explicitly requires a structural
     change.

4. Remove resolved review fences.
   - Delete a `review` fence after you have handled it.
   - Leave an unresolved `review` fence only when the user explicitly asks you
     to keep unresolved comments.

5. Validate and deliver the revised document.
   - Run `latch apply <path-to-latch-doc>` when applyability matters.
   - Report the revised file path and whether validation succeeded.

## Patch Fence Rules

Preserve this shape for every applyable patch:

````md
```diff id=patch-id [depends-on=other-id,another-id] [part=N]
diff --git a/path b/path
...
```
````

- The fenced code block info string must start with `diff`.
- Metadata must be space-separated `key=value` tokens after `diff`.
- Supported keys are `id`, `depends-on`, and `part`.
- Repeated `id`s are valid only for fragments of the same logical patch using
  contiguous `part=...` values.
- `depends-on=...` controls apply order, not Markdown position.

## Review Fence Rules

Use review fences only for reviewer instructions in an existing or reviewed
Latch document:

````md
```review [id=patch-id]
Describe the requested change or concern here.
```
````

- Review fences are not executable.
- Review fences may include `id=patch-id` to identify the patch they refer to.
- Review fences are not produced by the normal new-document draft workflow.
- Resolve review fences during revision, then remove them.
- Keep unresolved review fences only when the user asks to preserve them.

## Commands

- `latch draft`: generate a first-pass Latch document from stdin, a Git spec,
  or the current worktree diff.
- `latch apply`: apply patches from a Latch document.
- `latch commit`: create a Git commit from a Latch document, storing a compact
  recipe in the commit message body.
- `latch show`: reconstruct a full Latch document from a compact Latch commit;
  defaults to `HEAD`.
- `latch review`: extract reviewer comments from a Latch document.

## Hard Rules

- When creating a new Latch document, always generate a draft with
  `latch draft` before authoring the story.
- When creating a new Latch document, always edit the generated draft instead
  of starting from scratch.
- When revising a reviewed Latch document, inspect and resolve `review` fences
  before finalizing.
- When asked to commit a Latch document, use `latch commit`, not `git commit`.
- When asked to reconstruct a Latch document from a compact Latch commit, use
  `latch show`, not `latch draft`.
- Keep patch ids stable.
- Keep `diff` fences as patch fences.
- Keep non-patch examples out of `diff` fences.
- When revising a reviewed document, remove handled review fences unless the
  user asks to keep them.
- Reorder for comprehension, not for raw diff order.
- Explain why the change exists; do not restate every line of the diff.

## Examples

Create a new Latch document:

```sh
mkdir -p .latch
latch draft > .latch/change.latch.md
latch draft HEAD~1 > .latch/change.latch.md
git diff | latch draft > .latch/change.latch.md
latch apply .latch/change.latch.md
latch commit .latch/change.latch.md
latch show > .latch/change.latch.md
```

Revise a reviewed Latch document:

```sh
latch review .latch/change.latch.md
latch apply .latch/change.latch.md
```
