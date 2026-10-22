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

The popup reads Claude's transcript, not the pane. Claude Code wraps its text at the
pane's width as it writes it, so a snapshot of the pane carries line breaks for whatever
width the pane had at the time, and a pane on the alternate screen has no scrollback at
all. The transcript holds the markdown as Claude wrote it: a paragraph is one line, and
nvim wraps it to the popup's width.

Claude Code registers each running process in `~/.claude/sessions/<pid>.json`, and the
popup looks there for the pane's own processes; a pane showing a background session
names the job on screen. That gives the session, and `~/.claude/projects/*/<session>.jsonl`
its transcript. The transcript is a tree, since an edited or re-sent prompt leaves its
old branch behind, so the popup follows the parent links back from the newest record
and shows your last `turns` prompts with Claude's replies, each under a heading counted
from the end.

Comments become `>> [n]` lines in the buffer, while the excerpt each one points at is
held in memory — once comment lines are interleaved, the original block boundaries
can't be recovered from the text. On submit the message goes through a tmux buffer and
a bracketed paste, so the newlines don't submit it line by line. It is sent only while
Claude is the pane's foreground program: a shell would run the excerpts as commands.

[`doc/walkthrough.md`](doc/walkthrough.md) is a longer annotated tour of the source,
written as a way to learn Neovim's Lua API from something small and real.

## Known limits

- Comments are single-line (`vim.ui.input`).
- Nothing shows which lines an excerpt covers once the comment is inserted.
- Submit waits a fixed 200ms between pasting and pressing Enter.
- Only Claude's text is shown: thinking, tool calls and their output are left out.
- It reads Claude Code's own files, whose format can change with any release.
- Untested on a pane running `claude attach <id>`.
- tmux only.

## License

MIT
