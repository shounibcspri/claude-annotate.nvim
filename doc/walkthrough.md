# claude-annotate — annotated walkthrough

A plain-language tour of `lua/claude-annotate/init.lua`, written as a way to learn nvim's
Lua API from something small and real. Sections follow the file top to bottom and are
named after what they cover, so nothing here goes stale when a line moves.

## What the thing does

From any tmux pane running Claude Code, `prefix + i` opens an nvim popup holding a
snapshot of that pane. You select a block of output, attach a comment to it, repeat
for as many blocks as you like, then submit — all the comments go back to Claude as
a single message and the popup closes.

| Key | Where | Does |
| --- | --- | --- |
| `prefix + i` | any Claude pane | open the popup with the last 2000 lines |
| `V` + motion | popup | select a block (`Vip` = whole paragraph) |
| `<leader>cm` | popup | prompt for a comment, insert `>> [n] ...` below the selection |
| `dd` on a `>>` line | popup | drop that comment |
| `<leader>pp` | popup | submit everything, close the popup |
| `q` | popup | leave, discarding the comments |

The tmux side is `tmux/claude-annotate.conf`.

## How to look things up

Put the cursor on any `vim.*` call in the file and press **`K`** — if `lua_ls` is
configured with the nvim runtime as its library, you get the real signature and docs
inline.

- `:help lua-guide` — the one doc connecting Lua to nvim. Read this if you read nothing else.
- `:help vim.fn`, `:help nvim_buf_get_lines()`, `:help visual-mode`
- `:lua =vim.fn.line('.')` — print any expression's value
- https://learnxinyminutes.com/docs/lua/ — the language alone, 15 minutes

## Two Lua bits, then it's all nvim

`#x` is "length of x" (list length or string length). `..` glues strings together.

## The skeleton

```lua
local M = {}     -- top of the file
...
return M         -- bottom
```

A file under `lua/` is a **module**. Whatever it returns is what `require` hands
back, so `M` is the public surface: `M.setup`, `M.open`, `M.comment`, `M.submit`.
Anything declared `local` (like the `tmux` helper) is private to the file.

Nothing loads this at startup. The tmux popup runs
`nvim -c "lua require([[claude-annotate]]).open([[%35]])"`, and that `-c` is the only
thing that ever loads it.

## The state

```lua
local config = { history_lines = 2000, prefix = '>> ', keys = { ... } }
local TMUX_BUFFER = 'claude-annotate'    -- name of tmux's clipboard slot
local excerpts = {}                    -- excerpts[bufnr][n] = the quoted lines
```

`config` holds everything a user might reasonably want to change, and `M.setup` merges
their table over it with `vim.tbl_deep_extend('force', ...)` — "deep" so passing one
key under `keys` doesn't wipe the others. `TMUX_BUFFER` stays a constant because
renaming an internal clipboard slot buys nothing.

`excerpts` is the only piece of memory. **Buffer numbers ("bufnr")** are how nvim
identifies open buffers — plain integers. Keying by bufnr means two review buffers
can never tread on each other.

One subtlety: the pattern that recognises a comment line is built from `config.prefix`,
so it is recompiled in `setup` rather than rebuilt per line. It also runs the prefix
through `gsub('%p', '%%%0')` first — a prefix like `| ` or `%% ` would otherwise be
read as pattern syntax rather than as literal text.

## `tmux()`

Runs the `tmux` program and returns its stdout. `vim.system{...}` spawns a process,
`:wait()` blocks until it finishes. Called as `tmux { 'capture-pane', ... }` — the
`'tmux'` is prepended for you.

Arguments are a **list, not a string**, so no shell is involved. Pane ids like `%35`
and text with spaces never need quoting or escaping.

## `parse_comment()` and `is_comment()`

```lua
local function parse_comment(line) return line:match(comment_pattern) end
local function is_comment(line) return parse_comment(line) ~= nil end
```

"Is this one of *my* comment lines rather than captured output?" — and if so, which
number and what text.

The first version of this was `line:sub(1, #PREFIX) == PREFIX`, a plain prefix test,
which is the obvious thing to write and quietly wrong: Claude prints lines starting
with `>> ` of its own accord, and each one was then filtered out of the excerpt it
belonged to. Requiring the whole `>> [n] text` shape fixes that, and having one
function own the parse means the two callers cannot drift apart.

## `M.open(pane)`

**Capture**. Ask tmux for the pane's text. `-J` rejoins the terminal's own hard
wrapping so one paragraph becomes one line; `-S -2000` starts 2000 lines back in
scrollback.

**Clean**.

```lua
local lines = vim.split(captured, '\n', { plain = true })
```

tmux returns one big string; split it into a list. The `while` loop then drops
trailing blank lines, because tmux pads its output to the pane height. `%s` means
whitespace and `^...$` anchors to the whole line — those are Lua **patterns**, a
simpler cousin of regex.

**Build the buffer**.

| Call | Does |
| --- | --- |
| `nvim_create_buf(true, true)` | make a buffer; args are `(listed, scratch)`. Scratch = no file on disk, no swapfile, `:w` refuses |
| `nvim_buf_set_name(...)` | just a label. `claude-annotate://%35` is not a real path — the `://` is a convention meaning "not a file" |
| `nvim_buf_set_lines(buf, 0, -1, false, lines)` | replace lines 0 through end (`-1`) with our list |

**Remember the pane**.

```lua
vim.b[buf].claude_pane = pane
```

`vim.b` is **buffer-local variables**. This is how `M.submit` knows where to paste
later — the buffer carries it, and it dies with the buffer.

**Keymaps**. `{ buffer = buf }` is the important part: these exist *only* in
this buffer, which is why `<leader>cm` does nothing in your normal files.

Line 47, normal mode: `vim.fn.line('.')` is "current line number", passed as both
start and end, so it comments just that one line.

**Display**.

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

## `M.comment_visual()` and `M.comment()`

Line 63 reads the visual selection's boundary marks — `'<` where it started, `'>`
where it ended — and passes two line numbers along.

Why the visual-mode mapping is a weird string rather than a function:

```lua
':<C-u>lua require("claude-annotate").comment_visual()<CR>'
```

| Part | Effect |
| --- | --- |
| `:` | **leaves visual mode**, which is what sets `'<` and `'>`, and opens the command line prefilled with `'<,'>` |
| `<C-u>` | erases that prefilled range — we want a plain `:lua`, not a ranged command |
| `lua ...` | now runs with the marks populated |
| `<CR>` | executes |

If it were a Lua function instead, the callback would run while *still in visual
mode*, and the marks would still hold the **previous** selection.

**Slice the selection**.

```lua
vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
```

> **The gotcha.** `vim.fn.line()` counts from **1**. The `nvim_buf_*` API counts from
> **0** and excludes the end. Hence `first - 1`. Off-by-one here is the most common
> nvim scripting bug.

**Filter** drops any comment lines the selection swept up. **Reject empties**: if no
line has a non-whitespace character there's nothing to anchor to.

**Ask for the comment**.

```lua
vim.ui.input({ prompt = 'comment: ' }, function(input) ... end)
```

> **This is asynchronous.** It does *not* return your text. It shows a prompt and
> calls your function *later*, once you press Enter. That's why the work lives inside
> the function — anything written after the call would run before you finished typing.

Inside: number the comment, store the excerpt, insert the display line.

```lua
nvim_buf_set_lines(buf, last, last, false, { '>> [1] your text' })
```

Start `last`, end `last` — a zero-width range, which means **insert** rather than
replace.

## `M.submit()`

**Walk the buffer**. For each line, `parse_comment` pulls the number and text back out
with a pattern: `%[(%d+)%]` matches `[1]` and captures the digits, `(.*)` captures the
rest. A line that doesn't match the whole shape isn't ours — Claude's own output
sometimes starts with `>> `, and treating that as a note used to drop it out of the
excerpt it belonged to.

The deliberate split, and the reason the design works:

- the **excerpt** comes from `excerpts` — it cannot be rebuilt, because once comment
  lines are interleaved the original block boundaries are gone
- the **comment text** comes from the buffer line — so editing the wording counts,
  and `dd` on the line drops the whole note

**Send it**.

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

The four tmux calls sit inside a `pcall`. The pane id was captured when the popup
opened, and the pane can be killed or handed to another program in the meantime; the
`tmux` helper raises on a non-zero exit, which without the `pcall` would surface as a
stack trace and take your comments with it. On failure the popup stays open so the
notes can still be copied out.

It is worth naming what the 200ms does *not* do: it is a guess, not a handshake.
Nothing checks that the paste landed or that Claude is idle. A slow paste means Enter
arrives mid-message; a Claude already generating gets interrupted instead. Working
around that properly would mean polling the pane, which is the next real improvement
to this file.

## The autocmd

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
- `pcall(require, 'baleia')` is how you make a dependency genuinely optional. The
  question to ask is not "is it installed" but "what is lost if it isn't" — here only
  colour, so the missing case strips the escape codes with `strip_sgr` and carries on
  rather than refusing to open.
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
