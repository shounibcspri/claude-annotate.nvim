# claude-review.lua — annotated walkthrough

A plain-language tour of `claude-review.lua`, written as a way to learn nvim's Lua
API using code you already own. Line numbers match the version of the file sitting
next to this one; if you edit it, they drift.

## What the thing does

From any tmux pane running Claude Code, `Ctrl-a i` opens an nvim popup holding a
snapshot of that pane. You select a block of output, attach a comment to it, repeat
for as many blocks as you like, then submit — all the comments go back to Claude as
a single message and the popup closes.

| Key | Where | Does |
| --- | --- | --- |
| `Ctrl-a i` | any Claude pane | open the popup with the last 2000 lines |
| `V` + motion | popup | select a block (`Vip` = whole paragraph) |
| `<leader>cm` | popup | prompt for a comment, insert `>> [n] ...` below the selection |
| `dd` on a `>>` line | popup | drop that comment |
| `<leader>pp` | popup | submit everything, close the popup |

Leader is `<Space>`. The tmux side is the `bind i` block in `~/.config/tmux/tmux.conf`.

## How to look things up

Put the cursor on any `vim.*` call in the file and press **`K`** — `lua_ls` is
configured with the whole nvim runtime as its library (`lua/custom/plugins/lsp.lua`),
so you get the real signature and docs inline.

- `:help lua-guide` — the one doc connecting Lua to nvim. Read this if you read nothing else.
- `:help vim.fn`, `:help nvim_buf_get_lines()`, `:help visual-mode`
- `:lua =vim.fn.line('.')` — print any expression's value
- https://learnxinyminutes.com/docs/lua/ — the language alone, 15 minutes

## Two Lua bits, then it's all nvim

`#x` is "length of x" (list length or string length). `..` glues strings together.

## The skeleton — lines 7, 130

```lua
local M = {}     -- line 7
...
return M         -- line 130
```

A file under `lua/` is a **module**. Whatever it returns is what `require` hands
back, so `M` is the public surface: `M.open`, `M.comment`, `M.submit`. Anything
declared `local` (like `tmux` on line 17) is private to the file.

Nothing loads this at startup. The tmux popup runs
`nvim -c "lua require([[custom.claude-review]]).open([[%35]])"`, and that `-c` is
the only thing that ever loads it.

## The state — lines 9–15

```lua
local PREFIX = '>> '                   -- marks a comment line
local HISTORY_LINES = 2000             -- how much scrollback to grab
local TMUX_BUFFER = 'claude-review'    -- name of tmux's clipboard slot
local excerpts = {}                    -- excerpts[bufnr][n] = the quoted lines
```

`excerpts` is the only piece of memory. **Buffer numbers ("bufnr")** are how nvim
identifies open buffers — plain integers. Keying by bufnr means two review buffers
can never tread on each other.

## `tmux()` — lines 17–21

Runs the `tmux` program and returns its stdout. `vim.system{...}` spawns a process,
`:wait()` blocks until it finishes. Called as `tmux { 'capture-pane', ... }` — the
`'tmux'` is prepended for you on line 18.

Arguments are a **list, not a string**, so no shell is involved. Pane ids like `%35`
and text with spaces never need quoting or escaping.

## `is_comment()` — line 23

```lua
line:sub(1, #PREFIX) == PREFIX
```

"Do the first 3 characters equal `>> `?" — i.e. is this one of *my* comment lines
rather than captured output.

## `M.open(pane)` — lines 26–61

**Capture** (29). Ask tmux for the pane's text. `-J` rejoins the terminal's own hard
wrapping so one paragraph becomes one line; `-S -2000` starts 2000 lines back in
scrollback.

**Clean** (31–35).

```lua
local lines = vim.split(captured, '\n', { plain = true })
```

tmux returns one big string; split it into a list. The `while` loop then drops
trailing blank lines, because tmux pads its output to the pane height. `%s` means
whitespace and `^...$` anchors to the whole line — those are Lua **patterns**, a
simpler cousin of regex.

**Build the buffer** (37–39).

| Call | Does |
| --- | --- |
| `nvim_create_buf(true, true)` | make a buffer; args are `(listed, scratch)`. Scratch = no file on disk, no swapfile, `:w` refuses |
| `nvim_buf_set_name(...)` | just a label. `claude-review://%35` is not a real path — the `://` is a convention meaning "not a file" |
| `nvim_buf_set_lines(buf, 0, -1, false, lines)` | replace lines 0 through end (`-1`) with our list |

**Remember the pane** (40–41).

```lua
vim.b[buf].claude_pane = pane
```

`vim.b` is **buffer-local variables**. This is how `M.submit` knows where to paste
later — the buffer carries it, and it dies with the buffer.

**Keymaps** (43–56). `{ buffer = buf }` is the important part: these exist *only* in
this buffer, which is why `<leader>cm` does nothing in your normal files.

Line 47, normal mode: `vim.fn.line('.')` is "current line number", passed as both
start and end, so it comments just that one line.

**Display** (58–60).

```lua
vim.api.nvim_win_set_buf(0, buf)                 -- show buf in the current window
vim.wo[0].linebreak = true                       -- window-local option
vim.api.nvim_win_set_cursor(0, { #lines, 0 })    -- jump to the last line
```

That `0` means **"the current one"** — a convention throughout the API. Note the
scopes: `vim.b` was buffer-local *variables*, `vim.wo` is window-local *options*.

Three scopes worth keeping straight:

```
buffer  = the text in memory          vim.b, vim.bo
window  = a viewport onto a buffer    vim.w, vim.wo
global  = everything else             vim.g, vim.o
```

## `M.comment_visual()` and `M.comment()` — lines 63–83

Line 63 reads the visual selection's boundary marks — `'<` where it started, `'>`
where it ended — and passes two line numbers along.

Why the visual-mode mapping (line 53) is a weird string rather than a function:

```lua
':<C-u>lua require("custom.claude-review").comment_visual()<CR>'
```

| Part | Effect |
| --- | --- |
| `:` | **leaves visual mode**, which is what sets `'<` and `'>`, and opens the command line prefilled with `'<,'>` |
| `<C-u>` | erases that prefilled range — we want a plain `:lua`, not a ranged command |
| `lua ...` | now runs with the marks populated |
| `<CR>` | executes |

If it were a Lua function instead, the callback would run while *still in visual
mode*, and the marks would still hold the **previous** selection.

**Slice the selection** (69).

```lua
vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
```

> **The gotcha.** `vim.fn.line()` counts from **1**. The `nvim_buf_*` API counts from
> **0** and excludes the end. Hence `first - 1`. Off-by-one here is the most common
> nvim scripting bug.

**Filter** (71) drops any `>> ` lines the selection swept up. **Reject empties** (73):
if no line has a non-whitespace character there's nothing to anchor to.

**Ask for the comment** (77–82).

```lua
vim.ui.input({ prompt = 'comment: ' }, function(input) ... end)
```

> **This is asynchronous.** It does *not* return your text. It shows a prompt and
> calls your function *later*, once you press Enter. That's why the work lives inside
> the function — anything written after line 82 would run before you finished typing.

Inside: number the comment, store the excerpt, insert the display line.

```lua
nvim_buf_set_lines(buf, last, last, false, { '>> [1] your text' })
```

Start `last`, end `last` — a zero-width range, which means **insert** rather than
replace.

## `M.submit()` — lines 85–124

**Walk the buffer** (94–108). For each comment line, line 96 pulls the number and
text back out with a pattern: `%[(%d+)%]` matches `[1]` and captures the digits,
`(.*)` captures the rest.

The deliberate split, and the reason the design works:

- the **excerpt** comes from `excerpts` — it cannot be rebuilt, because once comment
  lines are interleaved the original block boundaries are gone
- the **comment text** comes from the buffer line — so editing the wording counts,
  and `dd` on the line drops the whole note

**Send it** (112–120).

| Call | Does |
| --- | --- |
| `vim.fn.tempname()` | a temp file path |
| `vim.fn.writefile(out, tmpfile)` | dump the message |
| `load-buffer` | load the file into a tmux clipboard slot |
| `paste-buffer -d -p` | paste into the pane. `-p` = bracketed paste, so the newlines don't submit line by line; `-d` deletes the slot after |
| `vim.wait(200)` | block 200ms so Claude Code processes the paste |
| `send-keys Enter` | submit |
| `vim.cmd 'qa!'` | quit nvim, which closes the popup |

`vim.wait` is deliberate rather than a timer: nvim exits on the next line, and a
deferred timer would die with it — text pasted, never submitted. That failure is
silent, which is what makes it worth a comment in the code.

## The autocmd — lines 126–128

```lua
vim.api.nvim_create_autocmd('BufDelete', {
  callback = function(ev) excerpts[ev.buf] = nil end,
})
```

An **autocommand** runs code on an event. When any buffer is deleted, forget its
excerpts, so the table doesn't grow forever.

## Non-obvious things learned building this

- `display-popup` does **not** expand `#{...}` formats in its command, and a popup's
  environment has **no `TMUX_PANE`**. That is why the tmux binding wraps the popup in
  `run-shell -b` (which *does* expand formats) and passes the pane id in explicitly.
- `paste-buffer -p` emits bracketed-paste markers **only if the receiving app asked
  for the mode**. Claude Code does; a plain `cat` does not.
- `capture-pane -J` also preserves trailing spaces, but in practice adds at most one
  per line — not full-width padding.
- Outside the popup these keys are not no-ops, because leader isn't a prefix there —
  the sequence degrades to `Space` (cursor right) followed by the bare keys.
  `cm` is harmless: `c` waits for a motion, `m` isn't one, so it aborts. `pp` is
  **not** — it pastes the unnamed register twice. `u` undoes it. Accepted rather
  than fixed, to avoid global mappings.

## The three ideas worth carrying forward

1. **Buffer numbers identify buffers.** Most API calls take one, and `vim.b[buf]`
   hangs your own data off it.
2. **`0` means "current"** — current buffer, current window.
3. **`vim.fn.*` is 1-indexed, `vim.api.*` is 0-indexed.** They come from different
   eras: `vim.fn` calls old vimscript functions, `vim.api` is nvim's native
   interface. Prefer `vim.api` when both exist.
