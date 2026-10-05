# claude-annotate.nvim

Annotate Claude Code's output the way you'd annotate a pull request.

Claude gives you a long answer. Three paragraphs are right, one is wrong, and one
assumed something you never said. Replying in prose means restating each part before
you can object to it. This attaches comments directly to the lines they're about, then
sends them all as one message.

Press a key in the tmux pane running Claude and a popup opens over it holding a
snapshot of the output. Select a block, attach a comment, repeat. Submit, and the
popup closes as Claude starts answering.

```
> the function should probably validate the input before hashing it
>> [1] no, it's an internal call site, the boundary already validates

> I've added a retry with exponential backoff
>> [2] this is the bit I disagree with -- the call isn't idempotent
```

Claude receives each comment paired with the exact text it's about.

## Requires

- Neovim 0.10+ (uses `vim.system`)
- tmux
- [baleia.nvim](https://github.com/m00qek/baleia.nvim) — optional, keeps Claude's
  colours. Without it the snapshot is plain text.

## Install

```sh
git clone https://github.com/shounibcspri/claude-annotate.nvim && ./claude-annotate.nvim/install.sh
```

`install.sh` links the Lua module into `~/.config/nvim/lua/`, adds the `prefix + i`
binding to your tmux config and loads it into a running server, and sources the pane
tools from `~/.zshrc`. A step already in place is left alone, so re-running is safe, and
the clone stays the live copy: `git pull` is the update. It also says which requirements
are missing.

### By hand

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'shounibcspri/claude-annotate.nvim',
  dependencies = { 'm00qek/baleia.nvim' },
  -- opened by tmux, never at startup
  lazy = true,
  opts = {},
}
```

`opts = {}` is enough; the defaults are below.

Then add the tmux binding from [`tmux/claude-annotate.conf`](tmux/claude-annotate.conf) to
your `tmux.conf`, or source the file:

```tmux
source-file ~/path/to/claude-annotate.nvim/tmux/claude-annotate.conf
```

That binds `prefix + i`. Reload with `tmux source-file ~/.tmux.conf`.

## Use

| Key | Where | Does |
| --- | --- | --- |
| `prefix + i` | any Claude pane | open the popup over it |
| `V` + motion | popup | select a block (`Vip` takes a whole paragraph) |
| `<leader>cm` | popup | prompt for a comment, insert `>> [n] ...` below the selection |
| `dd` on a `>>` line | popup | drop that comment |
| `<leader>pp` | popup | submit everything and close |
| `q` | popup | leave, discarding the comments |

Editing a `>> [n]` line changes what gets sent — the quoted excerpt stays attached.

## Configure

```lua
require('claude-annotate').setup {
  history_lines = 2000,      -- how much pane scrollback to snapshot
  prefix = '>> ',            -- marks a comment line
  keys = {
    comment = '<leader>cm',
    submit = '<leader>pp',
    quit = 'q',
  },
}
```

Set a key to `''` to skip that mapping. All mappings are buffer-local to the popup.

## Pane tools (zsh)

[`tmux/claude-panes.zsh`](tmux/claude-panes.zsh) adds `tmcheck` (`install.sh` sources it,
or by hand: `source ~/path/to/claude-annotate.nvim/tmux/claude-panes.zsh`). It lists the
Claude panes; a BROKEN one shows the background session it is attached to, and `tmcheck`
offers to stop those sessions. Then `claude --resume <id>` in the pane brings it back in
the foreground, with scrollback.

A pane is BROKEN when it runs `claude attach <id>`: background sessions are always
fullscreen, so the pane sits on the alternate screen with no scrollback. Both copy mode
(`prefix + [`) and the popup's snapshot then see only the current screen. Needs `jq`.

## How it works

`capture-pane -e -J` snapshots the pane, keeping colour and rejoining the terminal's
hard wrapping so one paragraph is one line. Comments become `>> [n]` lines in the
buffer, while the excerpt each one points at is held in memory — once comment lines are
interleaved, the original block boundaries can't be recovered from the text. On submit
the message goes through a tmux buffer and a bracketed paste, so the newlines don't
submit it line by line.

[`doc/walkthrough.md`](doc/walkthrough.md) is a longer annotated tour of the source,
written as a way to learn Neovim's Lua API from something small and real.

## Known limits

- Comments are single-line (`vim.ui.input`).
- Nothing shows which lines an excerpt covers once the comment is inserted.
- Submit waits a fixed 200ms between pasting and pressing Enter.
- tmux only.

## License

MIT
