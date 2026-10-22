# claude-annotate.nvim

Annotate Claude Code's output the way you'd annotate a pull request.

Claude gives you a long answer. Three paragraphs are right, one is wrong, and one
assumed something you never said. Replying in prose means restating each part before
you can object to it. This attaches comments directly to the lines they're about, then
sends them all as one message.

Press a key in the tmux pane running Claude and a popup opens over it holding the
conversation, read from Claude's transcript. Select a block, attach a comment, repeat.
Submit, and the popup closes as Claude starts answering.

```
> the function should probably validate the input before hashing it
>> [1] no, it's an internal call site, the boundary already validates

> I've added a retry with exponential backoff
>> [2] this is the bit I disagree with -- the call isn't idempotent
```

Claude receives each comment paired with the exact text it's about.

## Requires

- Neovim 0.10+ (uses `vim.system`); 0.12+ to install it with `vim.pack`
- tmux
- Claude Code: the popup reads its session files (tested with 2.1.295 to 2.1.308)

## Install

Install the plugin with your plugin manager, then run its `install.sh` once: that adds
the `prefix + i` binding to your tmux config and loads it into a running server.
Re-running it is safe, and it says which requirements are missing.

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add { 'https://github.com/shounibcspri/claude-annotate.nvim' }
```

```sh
~/.local/share/nvim/site/pack/core/opt/claude-annotate.nvim/install.sh
```

Nothing runs at startup: the module loads when tmux opens the popup. Call
`require('claude-annotate').setup {}` only to change the defaults below.
`:lua vim.pack.update()` updates it.

### lazy.nvim

```lua
{
  'shounibcspri/claude-annotate.nvim',
  -- opened by tmux, never at startup
  lazy = true,
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
clone is the live copy: edits show at the next popup, and `git pull` is the update.

### tmux binding by hand

Instead of `install.sh`, add the binding from
[`tmux/claude-annotate.conf`](tmux/claude-annotate.conf) to your `tmux.conf`, or source it:

```tmux
source-file ~/path/to/claude-annotate.nvim/tmux/claude-annotate.conf
```

## Use

| Key | Where | Does |
| --- | --- | --- |
| `prefix + i` | any Claude pane | open the popup over it |
| `V` + motion | popup | select a block (a paragraph is one line; `Vip` takes a list) |
| `[[` / `]]` | popup | jump to the previous / next response (`## Response -2`, `## Last response`) |
| `<leader>cm` | popup | prompt for a comment, insert `>> [n] ...` below the selection |
| `dd` on a `>>` line | popup | drop that comment |
| `<leader>pp` | popup | submit everything and close |
| `q` | popup | leave, discarding the comments |

Editing a `>> [n]` line changes what gets sent — the quoted excerpt stays attached.

## Configure

```lua
require('claude-annotate').setup {
  turns = 10,                -- how many of your latest prompts to show, with replies
  prefix = '>> ',            -- marks a comment line
  keys = {
    comment = '<leader>cm',
    submit = '<leader>pp',
    quit = 'q',
  },
}
```

Set a key to `''` to skip that mapping. All mappings are buffer-local to the popup.

## How it works

`prefix + i` runs `tmux run-shell`, which expands `#{pane_id}` and opens nvim in a
`display-popup` (a popup expands no formats itself and has no `TMUX_PANE`). nvim's `-c`
calls `open(pane)`, the only thing that ever loads the module.

### Why the transcript, not the pane

Claude Code wraps its text at the pane's width as it writes it, with real line breaks.
`capture-pane -J` rejoins only the terminal's own wraps, so a snapshot keeps them: a popup
narrower than the pane wraps every full line again, and after a split one reply mixes two
widths. A pane showing a background session is on the alternate screen, with no scrollback
at all. The transcript, `~/.claude/projects/<dir>/<session-id>.jsonl`, holds the markdown as
Claude produced it, one paragraph per line, and nvim wraps it to any width.

### Finding the session

Claude Code registers each running process in `~/.claude/sessions/<pid>.json`. `open` walks
the pane's process (`#{pane_pid}`, usually a shell) and its descendants breadth-first, and
takes the first one with a registry file. That entry's `parkedJobId`, set when the pane
views a background job, or else its `sessionId`, names the transcript. Searching only under
the pane means a crashed Claude's leftover file, a reused pid or the same pane id on another
tmux server cannot match.

### Rebuilding the conversation

The transcript is one JSON record per line, and a tree: each record names its `parentUuid`,
and an edited or re-sent prompt leaves its old branch behind. The popup follows the parents
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

It shows the last `turns` turns, each under a heading counted from the end, which the
markdown filetype's `[[` and `]]` jump between. Long lines wrap at spaces and hang under
their list marker (`breakindent` with `list:-1`). Diagnostics are off: a linter would flag
every paragraph's length.

### Comments and submit

A comment is a `>> [n] text` line below its excerpt, while the excerpt itself is kept in
memory: once comment lines are interleaved, the block boundaries can't be recovered from the
text. Rendered text never takes the comment shape, since prompts start with `> ` and
Claude's text with two spaces. Submit reads each comment from its line, so editing it or
`dd` counts.

Before sending, submit checks that the pane's foreground program is still the Claude found
at open: a suspended or exited Claude leaves a shell in front, which would run the excerpts
as commands. It then pastes the message through a tmux buffer with `paste-buffer -p`, so the
newlines don't submit it line by line, waits 200ms, presses Enter and closes the popup. On
any failure the popup stays open with your comments.

## Known limits

- Comments are single-line (`vim.ui.input`).
- Nothing shows which lines an excerpt covers once the comment is inserted.
- Submit waits a fixed 200ms between pasting and pressing Enter.
- Only Claude's text is shown: thinking, tool calls and their output are left out, and so
  is any message Claude Code stores as thinking.
- It reads Claude Code's own files, whose format can change with any release.
- Untested on a pane running `claude attach <id>`.
- tmux only.

## License

MIT
