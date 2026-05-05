# Latch

`latch` is a CLI for literate patches: Markdown documents that carry
patch intent in prose and executable diffs in fenced code blocks. A
Latch document is a literate patch.

`latch draft` turns a diff into a first-pass Latch document. The draft
keeps the full diff inline, assigns deterministic patch ids, and emits
instructions for an LLM or human editor to turn the mechanical output
into a coherent patch narrative.

That document is meant to be both readable and runnable. After the
human pass, `latch apply` reads the executable `diff` fences and
materializes the patch onto a target tree.

`latch skill` prints the checked-in Agent skill for turning code changes
into a Latch narrative.

## Example

````md
# Add `--json` output to `todo list`

## Tree

```text
.
├── src
│   └── cli.zig         +6 -1
└── test
    └── cli_test.zig    +6 -0
```
2 files changed, 12 insertions(+), 1 deletion(-)

## Behavior

`todo list --json` should produce a stable machine-readable format for
scripts and tooling. The first patch makes that contract explicit.

```diff id=8f31ac44 depends-on=2d4e91b0
diff --git a/test/cli_test.zig b/test/cli_test.zig
--- a/test/cli_test.zig
+++ b/test/cli_test.zig
@@ -21,6 +21,12 @@ test "todo list prints one item per line" {
     try expectEqualStrings("buy milk\\ncall mom\\n", output);
 }
+
+test "todo list --json emits a JSON array" {
+    const output = try runCli(.{ "todo", "list", "--json" });
+    try expectEqualStrings("[\"buy milk\",\"call mom\"]\\n", output);
+}
```

## Implementation

The implementation then parses the flag and switches the renderer.

```diff id=2d4e91b0
diff --git a/src/cli.zig b/src/cli.zig
--- a/src/cli.zig
+++ b/src/cli.zig
@@ -48,10 +48,16 @@ pub fn runListCommand(args: []const []const u8) !void {
+    const json = std.mem.indexOfScalar([]const u8, args, "--json") != null;
+
     const todos = try loadTodos();
-    try renderList(todos);
+    if (json) {
+        try renderListJson(todos);
+    } else {
+        try renderList(todos);
+    }
 }
```
````

## Usage

Draft a Latch document from the current worktree diff:

```sh
latch draft -o change.latch.md
```

Draft from a specific commit or range:

```sh
latch draft HEAD~1 -o change.latch.md
latch draft main..HEAD -o change.latch.md
```

Draft from stdin:

```sh
git diff | latch draft -o change.latch.md
```

Apply a Latch document from a path or stdin:

```sh
latch apply change.latch.md
cat change.latch.md | latch apply
latch apply --dir /tmp/repo -
```

Create a compact Latch Git commit, then reconstruct the full document
from that commit:

```sh
latch commit change.latch.md
latch show HEAD > change.latch.md
```

`latch commit` uses the document's first H1 as the Git commit subject
and currently requires a clean tracked worktree. The commit body stores
the prose with compact `latch-ref` fences rather than full diff bodies;
`latch show` expands those refs from the commit's canonical parent diff.

Extract reviewer comments from a Latch document path or stdin:

```sh
latch review change.latch.md
cat change.latch.md | latch review
latch review --json change.latch.md
```

Print the repo skill:

```sh
latch skill
```

## Editor integrations

A small Neovim plugin lives in `contrib/nvim/latch.nvim`. It applies to
`*.latch.md` files, completes patch ids, inserts `review` fences, and can
run `latch review` from the current buffer.

## Workflow

1. Make code changes normally.
2. Run `latch draft` from the current diff, a commit, a range, or stdin.
3. Rewrite the generated draft into a real patch narrative.
4. Keep executable `diff` fences intact while reordering sections and
   improving the prose.
5. Optionally run `latch commit change.latch.md` to create a Git commit
   whose message stores a compact Latch recipe.
6. Use `latch show <commit>` to reconstruct the full Latch document from
   such a commit.
7. Reviewers may add non-executable `review` fences with optional
   `id=patch-id` metadata.
8. Run `latch review` to extract those comments for the next authoring
   pass, or `latch apply` to materialize the document onto a target tree.

Generated drafts are intentionally mechanical. They preserve
fine-grained Git hunks, assign deterministic patch ids, and include
instructions for the human pass.

## Installation

`latch` shells out to `git` for diff collection and patch application,
so `git` needs to be available on `PATH`.

Build the binary:

```sh
zig build -Doptimize=ReleaseSafe
```

Install it somewhere on `PATH`:

```sh
zig build -Doptimize=ReleaseSafe install --prefix ~/.local
```

## Specification

Latch is both a CLI and a document format. The normative format and
application rules live in `SPECIFICATION.md`.

Short version:

- patch fences are fenced code blocks whose info string starts with
  `diff`
- supported patch metadata keys are `id`, `depends-on`, and `part`
- review fences are fenced code blocks whose info string starts with
  `review`; optional `id=patch-id` scopes a comment to a patch
- compact Git commits store `latch-ref` fences with `ranges=...`; `latch
  show` expands them back into executable `diff` fences
- `depends-on` controls apply order, not Markdown position
- split patches reuse the same `id` with contiguous `part=1..N`

See `SPECIFICATION.md` for the full grammar, validation rules, assembly
rules, and application semantics.
