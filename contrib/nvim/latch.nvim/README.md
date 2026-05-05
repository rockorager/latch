# latch.nvim

Neovim helpers for reviewing Latch documents.

The plugin is intentionally small and local to Latch files. It applies to
`*.latch.md`, keeps Markdown behavior through the compound
`markdown.latch` filetype, and adds review-focused commands for the
non-executable `review` fences described by the Latch specification.

## Installation

Use this directory as the plugin root. For example, with `lazy.nvim` from
a checkout of this repository:

```lua
{
  dir = "/path/to/latch/contrib/nvim/latch.nvim",
  event = { "BufReadPost *.latch.md", "BufNewFile *.latch.md" },
  opts = {
    reviewer = "tim@timculverhouse.com",
  },
}
```

Or add it directly to your runtime path:

```vim
set runtimepath+=/path/to/latch/contrib/nvim/latch.nvim
```

## Setup

The plugin works with defaults once it is on the runtime path. Optional
configuration:

```lua
require("latch").setup({
  -- Command used by :LatchExtractReviews and :LatchApply.
  latch_cmd = "latch",

  -- Optional metadata added to new review fences.
  reviewer = "tim@timculverhouse.com",

  -- Buffer-local keymaps for *.latch.md files.
  keymaps = true,

  -- Show diagnostics for malformed fence metadata and unknown review ids.
  diagnostics = true,
})
```

## Commands

All commands are buffer-local and are attached only for `*.latch.md`.

- `:LatchReview [patch-id]`
  Insert a `review` fence. If no patch id is supplied, the plugin uses
  the containing or nearest preceding `diff id=...` fence. Use
  `:LatchReview!` to force a global review without an inferred id.
- `:'<,'>LatchReview [patch-id]`
  Insert a review fence for a visual selection. The selected diff lines
  are included first as context inside a nested `diff` code fence, then
  the cursor is placed below that snippet for the review text. The review
  fence gets `part=` and `lines=` metadata when those values can be
  inferred from the surrounding `diff` fence. `lines=1` refers to the
  first line inside that fence's diff body, not the opening fence line.
- `:LatchExtractReviews`
  Run `latch review` on the current buffer contents and open the result
  in a scratch buffer.
- `:LatchExtractReviews!`
  Same as above, but asks for `latch review --json` and opens JSON.
- `:LatchApply [dir]`
  Run `latch apply --dir <dir> -` using the current buffer contents.
  Defaults to Neovim's current working directory.
- `:LatchListIds`
  Open a scratch buffer listing patch ids found in the document.
- `:LatchRefresh`
  Refresh diagnostics.

## Keymaps

When `keymaps = true`, these buffer-local mappings are installed:

- Normal/visual `<leader>lr`: `:LatchReview`
- Normal `<leader>lx`: `:LatchExtractReviews`
- Normal `<leader>lX`: `:LatchExtractReviews!`

## Completion

For `*.latch.md` buffers, the plugin sets `completefunc` so insert-mode
completion can complete existing patch ids after `id=`:

````md
```review id=<C-x><C-u>
```
````

The plugin also ships a `blink.cmp` source at `latch.blink`. To use it,
add the provider to `blink.cmp` and enable it for `markdown.latch`:

```lua
{
  "saghen/blink.cmp",
  opts = function(_, opts)
    opts.sources = opts.sources or {}
    opts.sources.providers = opts.sources.providers or {}
    opts.sources.providers.latch = {
      name = "Latch",
      module = "latch.blink",
      score_offset = 20,
    }
    opts.sources.per_filetype = opts.sources.per_filetype or {}
    opts.sources.per_filetype.latch = {
      inherit_defaults = true,
      "latch",
    }
  end,
}
```

Command-line completion is also available for `:LatchReview <Tab>`.

## Example

With the cursor inside or below this patch:

````md
```diff id=parser
...
```
````

Running `:LatchReview` inserts:

````md
```review id=parser

```
````

If `reviewer` is configured, it inserts:

````md
```review reviewer=tim@timculverhouse.com id=parser

```
````
