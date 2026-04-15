# Latch

`latch` is a Zig proof-of-concept CLI for "literate patches": Markdown documents that carry patch intent in prose and executable diffs in fenced code blocks.

The current POC treats any fenced code block whose info string starts with `diff` as executable. Extra fence metadata is parsed from `key=value` tokens after `diff`.

Markdown parsing is backed by the full AST parser copied from `../mu/src/markdown/parser.zig`, so the CLI does not have to guess at fences with ad hoc string scanning.

## Example

````md
# Rename with tests first in the narrative

This section explains the test change before the implementation because it reads better.

```diff id=tests depends-on=core
diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-hello there
+hello world
```

The implementation patch appears later in the document but still applies first.

```diff id=core
diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-hello
+hello there
```
````

## Rules

- Every executable `diff` fence must have an `id=...`.
- Optional dependencies use `depends-on=a,b,c`.
- The CLI computes apply order from dependencies rather than Markdown position.
- If multiple patches are otherwise independent, they are applied in lexical `id` order.
- Patch application currently shells out to `git apply --unsafe-paths`.

## Usage

```sh
zig build run -- plan examples/demo.lpatch.md
zig build run -- apply --dir examples/demo-target examples/demo.lpatch.md
```
