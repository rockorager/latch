# Demo

This document tells the story out of execution order. The test-facing patch is introduced first, but it depends on the implementation patch.

```diff id=tests depends-on=core
diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-hello there
+hello world
```

The implementation patch appears later, because the explanation fits better here.

```diff id=core
diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-hello
+hello there
```
