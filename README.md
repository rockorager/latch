# Latch

`latch` is a CLI for literate patches: Markdown documents that carry
patch intent in prose and executable diffs in fenced code blocks.

`latch draft` turns a diff into a first-pass Latch document. The draft
keeps the full diff inline, assigns deterministic patch ids, and emits
instructions for an LLM or human editor to turn the mechanical output
into a coherent patch narrative.

That document is meant to be both readable and runnable. After the
human pass, `latch apply` reads the executable `diff` fences and
materializes the patch onto a target tree.

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

Apply a Latch document:

```sh
latch apply change.latch.md
```

## Workflow

1. Make code changes normally.
2. Run `latch draft` from the current diff, a commit, a range, or stdin.
3. Rewrite the generated draft into a real patch narrative.
4. Keep executable `diff` fences intact while reordering sections and
   improving the prose.
5. Run `latch apply` to materialize the document onto a target tree.

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

## Document Format

Latch treats any fenced code block whose info string starts with `diff`
as executable. Extra fence metadata is parsed from `key=value` tokens
after `diff`.

Example:

````md
```diff id=3f2a91c8 depends-on=1c0e51aa
diff --git a/src/main.zig b/src/main.zig
...
```
````

### Supported Keys

- `id=...`
  Required for every executable patch. `id` names the logical patch that
  `latch` orders and applies.
- `depends-on=a,b,c`
  Optional comma-separated patch dependencies. Apply order is computed
  from dependencies, not Markdown position.
- `part=N`
  Optional positive integer used to split one logical patch across
  multiple `diff` fences. Fences with the same `id` and contiguous
  `part=1..N` are concatenated before apply. If `depends-on` is needed
  on a split patch, it must appear on `part=1`.

Unsupported metadata keys are rejected.

### Apply Semantics

- Every executable patch must have an `id`.
- Repeated `id`s are only valid when every fragment uses `part=...`.
- Split patches must use contiguous parts starting at `1`.
- Apply order comes from `depends-on`, not document order.
- Independent patches are applied in lexical `id` order.
- Patch application currently shells out to
  `git apply --unsafe-paths`.
