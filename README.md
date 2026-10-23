# claude-annotate.nvim

Annotate Claude Code's output the way you'd review a pull request.

When you want to discuss specific points of Claude's last answer, a reply in prose has to
restate each point before it can say anything about it. claude-annotate lets you comment
on the exact lines instead, in nvim, and sends all the comments back as one message.

Two keys open it:

- **`ctrl+g` in Claude Code.** Claude Code's `ctrl+g` normally opens your prompt in an
  external editor. With nvim as that editor, the plugin takes it over: instead of an empty
  prompt, nvim shows the conversation, ready to annotate. Saving (`:wq`) puts your comments
  in Claude's prompt, and you press Enter there to send them. It works in any terminal.
- **`prefix + i` in tmux, optional.** If you run Claude Code in tmux, this opens the same
  conversation in a tmux popup over the pane, without going through Claude's editor.
  Saving puts the comments in Claude's prompt the same way, and `<leader>pp` also sends
  them.

## How it looks

Claude answers a prompt. In nvim, each response sits under a heading, after the prompt
that asked for it, with one paragraph or list item per line:

```markdown
## Last response

> make the payment call more robust

  I made two changes:
  - the input is now validated before it is hashed
  - the call to the payment service is retried, with exponential backoff
```

You select the lines you want to discuss and attach a comment to each. A comment appears
right below what it is about:

```markdown
  - the input is now validated before it is hashed
>> [1] no need, it's an internal call and the boundary already validates
  - the call to the payment service is retried, with exponential backoff
>> [2] the call isn't idempotent, so a retry could charge twice
```

When you save or push, Claude gets each comment with the exact text it is about:

```
Comments on this conversation:

[1] on:
>   - the input is now validated before it is hashed
comment: no need, it's an internal call and the boundary already validates

[2] on:
>   - the call to the payment service is retried, with exponential backoff
comment: the call isn't idempotent, so a retry could charge twice
```

## Requires

- Neovim 0.10+ (uses `vim.system`); 0.12+ to install it with `vim.pack`. Classic Vim can't
  run it: it is built on Neovim's Lua API.
- Claude Code: the plugin reads its session files (tested with 2.1.295 to 2.1.309)
- For `install.sh`: `jq`, to edit Claude Code's settings
- For the tmux popup: tmux

## Install

Three steps by hand, or `install.sh` for the last two.

### 1. Install the plugin

With `vim.pack` (Neovim 0.12+), which `:lua vim.pack.update()` then updates:

```lua
vim.pack.add { 'https://github.com/shounibcspri/claude-annotate.nvim' }
```

With lazy.nvim:

```lua
{
  'shounibcspri/claude-annotate.nvim',
  -- ctrl+g needs it loaded at startup
  lazy = false,
  opts = {},
}
```

At startup the plugin only checks whether nvim was opened on Claude's prompt file; call
`setup` only to change the defaults below.

### 2. Make nvim Claude Code's editor

`ctrl+g` opens `$VISUAL`, else `$EDITOR`. To have it open nvim without changing the editor
you use elsewhere, set it in Claude Code's own settings, `~/.claude/settings.json`:

```json
{ "env": { "VISUAL": "nvim" } }
```

### 3. Optional: the tmux popup

Add the binding from [`tmux/claude-annotate.conf`](tmux/claude-annotate.conf) to your
`tmux.conf`, or source it:

```tmux
source-file ~/path/to/claude-annotate.nvim/tmux/claude-annotate.conf
```

### Or let install.sh do steps 2 and 3

After step 1, run the plugin's `install.sh` once. It sets `VISUAL` in Claude Code's
settings unless one is already there, and where tmux is installed, it adds the binding
and loads it into a running server. It is safe to re-run, and says which requirements
are missing.

```sh
~/.local/share/nvim/site/pack/core/opt/claude-annotate.nvim/install.sh   # vim.pack
~/.local/share/nvim/lazy/claude-annotate.nvim/install.sh                 # lazy.nvim
```

### From a clone, to work on it

```sh
git clone https://github.com/shounibcspri/claude-annotate.nvim && ./claude-annotate.nvim/install.sh
```

Run from a clone, `install.sh` also links the Lua module into `~/.config/nvim/lua/`, so the
clone is the live copy: edits show the next time you annotate, and `git pull` is the
update. Only `lua/` is linked, not `plugin/`, so call `require('claude-annotate').setup {}`
in your config for `ctrl+g`.

## Use

| Key | Where | Does |
| --- | --- | --- |
| `ctrl+g` | Claude Code's input | open the annotate buffer instead of the prompt editor |
| `prefix + i` | a Claude pane in tmux, popup installed | open the annotate buffer in a popup over it |
| `V` + motion | annotate buffer | select a block (a paragraph is one line; `Vip` takes a list) |
| `[[` / `]]` | annotate buffer | jump to the previous / next response |
| `<leader>cm` | annotate buffer | prompt for a comment, insert `>> [n] ...` below the selection |
| `dd` on a `>>` line | annotate buffer | drop that comment |
| `:w` / `:wq` | annotate buffer | save: put the comments in Claude's prompt, then close |
| `<leader>pp` | annotate buffer | push: from the popup, save and send; from `ctrl+g`, the same as save |
| `:q` | annotate buffer | leave without comments; `:q!` leaves and drops them (your draft is kept) |

Editing a `>> [n]` line changes what gets sent — the quoted excerpt stays attached.

## Configure

```lua
require('claude-annotate').setup {
  last_n_response = 10,      -- how many of Claude's latest responses to show
  prefix = '>> ',            -- marks a comment line
  keys = {
    comment = '<leader>cm',
    submit = '<leader>pp',
  },
}
```

Set a key to `''` to skip that mapping. All mappings are buffer-local to the annotate
buffer. The tmux popup needs no option: installing its binding is what turns it on.

## How it works

Under `lua/claude-annotate/`, `init.lua` holds the config and routes. `editor.lua` handles
`ctrl+g` and `tmux.lua` the tmux popup; both open the same annotate buffer, `annotate.lua`,
and hand it a function that delivers the message.

**`ctrl+g`.** Claude Code writes your draft to a temp file named `claude-prompt-<uuid>.md`
and runs `$VISUAL`, else `$EDITOR`, on it as its own child process. Once the editor exits,
it loads the file into its input. At startup, `plugin/claude-annotate.lua` (or `setup`)
spots that file, finds the Claude above nvim's process (the code runs in `nvim --embed`,
under the nvim drawing the screen), and opens the annotate buffer on its session. Opened
on such a file by anything else, nvim just edits it.

**The tmux popup.** `prefix + i` runs `tmux run-shell`, which expands `#{pane_id}` and opens
nvim in a `display-popup` (a popup expands no formats itself and has no `TMUX_PANE`). nvim's
`-c` calls `open(pane)`. In a pane with no Claude session, or nothing to annotate yet, the
popup closes again and tmux's status line says why.

### Why the transcript, not the pane

Claude Code wraps its text at the pane's width as it writes it, with real line breaks.
`capture-pane -J` rejoins only the terminal's own wraps, so a snapshot keeps them: a popup
narrower than the pane wraps every full line again, and after a split one reply mixes two
widths. A pane showing a background session is on the alternate screen, with no scrollback
at all. The transcript, `~/.claude/projects/<dir>/<session-id>.jsonl`, holds the markdown as
Claude produced it, one paragraph per line, and nvim wraps it to any width.

### Finding the session

Claude Code registers each running process in `~/.claude/sessions/<pid>.json`. From
`ctrl+g`, the plugin walks up from nvim's process to the first one with a registry file.
The popup walks down instead, from the pane's process (`#{pane_pid}`, usually a shell)
through its descendants, breadth-first: searching only under the pane means a crashed
Claude's leftover file, a reused pid or the same pane id on another tmux server cannot
match. The entry's `parkedJobId`, set when the pane views a background job, or else its
`sessionId`, names the transcript.

### Rebuilding the conversation

The transcript is one JSON record per line, and a tree: each record names its `parentUuid`,
and an edited or re-sent prompt leaves its old branch behind. The plugin follows the parents
back from the newest record outside a subagent; a compaction starts a new chain whose root
links the old one through `logicalParentUuid`.

Many records are filed as `user`, but only your prompts start a turn: a `user` record with
`origin.kind` `human`, or a `queued_command` attachment, which is all a prompt typed while
Claude is busy gets. Tool results, slash commands, task notifications, messages from other
sessions and interrupt markers are skipped. Claude's reply is its `text` blocks. Prompts
sent before Claude says anything share the reply that follows.

### The buffer

```markdown
## Response -2

> your prompt

  Claude's text, one paragraph per line
```

It shows the last `last_n_response` responses, each with your prompt and under a heading
counted from the end, which the markdown filetype's `[[` and `]]` jump between. Long lines
wrap at spaces and hang under their list marker (`breakindent` with `list:-1`).
Diagnostics are off: a linter would flag every paragraph's length.

### Comments, save and push

A comment is a `>> [n] text` line below its excerpt, while the excerpt itself is kept in
memory: once comment lines are interleaved, the block boundaries can't be recovered from the
text. Rendered text never takes the comment shape, since prompts start with `> ` and
Claude's text with two spaces. The message is built from the comment lines when you save,
so editing one or deleting it with `dd` counts.

The plugin writes the buffer itself (`buftype=acwrite`), so `:w` saves. Once you have
commented, the buffer is unsaved, and `:q` asks for `:q!` before dropping the comments.

From `ctrl+g`, save writes your draft, if any, then the comments into Claude's prompt file
and quits; push does the same, since nothing in Claude's editor can send. From the popup,
save first checks that the pane's foreground program is still the Claude found at open:
a suspended or exited Claude leaves a shell in front, which would run the excerpts as
commands. It then pastes the message through a tmux buffer with `paste-buffer -p`, so the
newlines don't send it line by line, and closes the popup; push also waits 200ms and
presses Enter. On any failure the popup stays open with your comments.

## Known limits

- Comments are single-line (`vim.ui.input`).
- Nothing shows which lines an excerpt covers once the comment is inserted.
- `ctrl+g` doesn't send by itself: Claude Code only loads the file into its input.
- The popup waits a fixed 200ms between pasting and pressing Enter, and needs tmux.
- Only Claude's text is shown: thinking, tool calls and their output are left out, and so
  is any message Claude Code stores as thinking.
- It reads Claude Code's own files, whose format can change with any release.
- Untested on a pane running `claude attach <id>`.

## License

MIT
