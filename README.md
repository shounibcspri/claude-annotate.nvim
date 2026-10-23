# claude-annotate.nvim

Annotate Claude Code's output the way you'd annotate a pull request.

Claude gives you a long answer. Three paragraphs are right, one is wrong, and one
assumed something you never said. Replying in prose means restating each part before
you can object to it. This attaches comments directly to the lines they're about, then
sends them all as one message.

The review holds the conversation, read from Claude's transcript. Select a block, attach
a comment, repeat, then submit. Two keys open it:

- **`ctrl+g`, by default:** Claude Code's own key for editing the prompt in your editor
  opens the review instead, in any terminal. Submit puts the comments in Claude's input
  box, and you press Enter.
- **`prefix + i`, optional:** in the tmux pane running Claude, a popup over it. Submit sends
  the comments, and the popup closes as Claude starts answering.

```
> the function should probably validate the input before hashing it
>> [1] no, it's an internal call site, the boundary already validates

> I've added a retry with exponential backoff
>> [2] this is the bit I disagree with -- the call isn't idempotent
```

Claude receives each comment paired with the exact text it's about.

## Requires

- Neovim 0.10+ (uses `vim.system`); 0.12+ to install it with `vim.pack`. Classic Vim can't
  run it: it is built on Neovim's Lua API.
- Claude Code: the review reads its session files (tested with 2.1.295 to 2.1.309)
- nvim as Claude Code's editor, since that is what `ctrl+g` opens: `install.sh` sets it in
  Claude's settings, or set `$VISUAL` or `$EDITOR` yourself
- `jq`, for `install.sh` to edit those settings
- For the tmux popup: tmux

## Install

Install the plugin with your plugin manager, then run its `install.sh` once. It sets
`"VISUAL": "nvim"` under `"env"` in `~/.claude/settings.json`, so `ctrl+g` opens nvim while
the editor you use elsewhere stays, and it keeps a `VISUAL` already set there. Where tmux
is installed, it also adds the popup's `prefix + i` binding to your tmux config and loads
it into a running server. Re-running it is safe, and it says which requirements are
missing.

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add { 'https://github.com/shounibcspri/claude-annotate.nvim' }
```

```sh
~/.local/share/nvim/site/pack/core/opt/claude-annotate.nvim/install.sh
```

At startup the plugin only checks whether nvim was opened on Claude's prompt file; `setup`
is needed only to change the defaults below. `:lua vim.pack.update()` updates it.

### lazy.nvim

```lua
{
  'shounibcspri/claude-annotate.nvim',
  -- ctrl+g needs it loaded at startup
  lazy = false,
  opts = {},
}
```

```sh
~/.local/share/nvim/lazy/claude-annotate.nvim/install.sh
```

### From a clone, to work on it

```sh
git clone https://github.com/shounibcspri/claude-annotate.nvim && ./claude-annotate.nvim/install.sh
```

Run from a clone, `install.sh` also links the Lua module into `~/.config/nvim/lua/`, so the
clone is the live copy: edits show at the next review, and `git pull` is the update. Only
`lua/` is linked, not `plugin/`, so call `require('claude-annotate').setup {}` in your
config for `ctrl+g`.

### By hand

Instead of `install.sh`, add `"VISUAL": "nvim"` under `"env"` in `~/.claude/settings.json`,
and for the tmux popup, add the binding from
[`tmux/claude-annotate.conf`](tmux/claude-annotate.conf) to your `tmux.conf`, or source it:

```tmux
source-file ~/path/to/claude-annotate.nvim/tmux/claude-annotate.conf
```

## Use

| Key | Where | Does |
| --- | --- | --- |
| `ctrl+g` | Claude Code's input | open the review instead of the prompt editor |
| `prefix + i` | a Claude pane in tmux, popup installed | open the review in a popup over it |
| `V` + motion | review | select a block (a paragraph is one line; `Vip` takes a list) |
| `[[` / `]]` | review | jump to the previous / next response |
| `<leader>cm` | review | prompt for a comment, insert `>> [n] ...` below the selection |
| `dd` on a `>>` line | review | drop that comment |
| `<leader>pp` | review | submit and close: from `ctrl+g` fills Claude's input, from the popup sends |
| `q` | review | leave, discarding the comments (from `ctrl+g`, your draft is kept) |

Editing a `>> [n]` line changes what gets sent — the quoted excerpt stays attached.

## Configure

```lua
require('claude-annotate').setup {
  last_n_response = 10,      -- how many of Claude's latest responses to show
  prefix = '>> ',            -- marks a comment line
  keys = {
    comment = '<leader>cm',
    submit = '<leader>pp',
    quit = 'q',
  },
}
```

Set a key to `''` to skip that mapping. All mappings are buffer-local to the review. The
tmux popup needs no option: installing its binding is what turns it on.

## How it works

Under `lua/claude-annotate/`, `init.lua` holds the config and routes. `editor.lua` handles
`ctrl+g` and `tmux.lua` the tmux popup; both open the same review buffer, `annotate.lua`,
and hand it a function that delivers the message.

**`ctrl+g`.** Claude Code writes your draft to a temp file named `claude-prompt-<uuid>.md`
and runs `$VISUAL`, else `$EDITOR`, on it as its own child process. Once the editor exits,
it loads the file into its input. At startup, `plugin/claude-annotate.lua` (or `setup`)
spots that file, finds the Claude above nvim's process (the code runs in `nvim --embed`,
under the nvim drawing the screen), and opens the review on its session. Opened on such a
file by anything else, nvim just edits it.

**The tmux popup.** `prefix + i` runs `tmux run-shell`, which expands `#{pane_id}` and opens
nvim in a `display-popup` (a popup expands no formats itself and has no `TMUX_PANE`). nvim's
`-c` calls `open(pane)`. In a pane with no Claude session, or nothing to review yet, the
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
`ctrl+g`, the review walks up from nvim's process to the first one with a registry file.
The popup walks down instead, from the pane's process (`#{pane_pid}`, usually a shell)
through its descendants, breadth-first: searching only under the pane means a crashed
Claude's leftover file, a reused pid or the same pane id on another tmux server cannot
match. The entry's `parkedJobId`, set when the pane views a background job, or else its
`sessionId`, names the transcript.

### Rebuilding the conversation

The transcript is one JSON record per line, and a tree: each record names its `parentUuid`,
and an edited or re-sent prompt leaves its old branch behind. The review follows the parents
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

### Comments and submit

A comment is a `>> [n] text` line below its excerpt, while the excerpt itself is kept in
memory: once comment lines are interleaved, the block boundaries can't be recovered from the
text. Rendered text never takes the comment shape, since prompts start with `> ` and
Claude's text with two spaces. Submit reads each comment from its line, so editing it or
`dd` counts.

From `ctrl+g`, submit writes your draft, if any, then the comments into Claude's prompt
file and quits. From the popup, it first checks that the pane's foreground program is
still the Claude found at open: a suspended or exited Claude leaves a shell in front,
which would run the excerpts as commands. It then pastes the message through a tmux
buffer with `paste-buffer -p`, so the newlines don't submit it line by line, waits 200ms,
presses Enter and closes the popup. On any failure the popup stays open with your
comments.

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
