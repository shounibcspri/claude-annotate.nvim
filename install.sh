#!/usr/bin/env bash
# Install claude-annotate: make nvim Claude Code's ctrl+g editor, add the tmux popup
# (prefix + i) where tmux is installed, and from a clone, link the nvim module.
# Every step is skipped when already in place, so re-running is safe.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
short=${repo/#$HOME/\~}
say() { printf '  %-7s %s\n' "$1" "$2"; }

echo "claude-annotate from $short"

# --- nvim: put the module on the runtimepath via the config dir's lua/
nvim_lua=${XDG_CONFIG_HOME:-$HOME/.config}/nvim/lua
link=$nvim_lua/claude-annotate
# a copy installed by vim.pack or lazy.nvim lives in nvim's data dir and is already on the runtimepath
if [[ $repo == "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/"* ]]; then
  say ok "nvim  loaded by your plugin manager"
elif [[ $(readlink "$link" 2>/dev/null) == "$repo/lua/claude-annotate" ]]; then
  say ok "nvim  $link"
elif [[ -e $link || -L $link ]]; then
  say SKIP "nvim  $link already exists and is not this repo; move it away and re-run"
else
  mkdir -p "$nvim_lua"
  ln -s "$repo/lua/claude-annotate" "$link"
  say added "nvim  $link -> $short/lua/claude-annotate"
fi

# --- claude: ctrl+g opens $VISUAL. Set in Claude Code's own settings, it leaves the editor
# you use elsewhere alone; a VISUAL already set there is kept. Written through a link, so a
# settings.json kept in dotfiles stays linked.
# readlink -f fails on a missing directory, which a machine without Claude Code yet has
mkdir -p "$HOME/.claude"
settings=$(readlink -f "$HOME/.claude/settings.json")
if ! command -v jq &>/dev/null; then
  say MISSING "jq, to set \"VISUAL\": \"nvim\" under \"env\" in ~/.claude/settings.json"
elif visual=$(jq -er '.env.VISUAL' "$settings" 2>/dev/null); then
  say ok "claude ctrl+g opens $visual"
else
  mkdir -p "${settings%/*}"
  [[ -s $settings ]] || echo '{}' > "$settings"
  jq '.env.VISUAL = "nvim"' "$settings" > "$settings.tmp"
  mv "$settings.tmp" "$settings"
  say added "claude ctrl+g opens nvim (env.VISUAL in ~/.claude/settings.json)"
fi

# --- tmux, for the popup: source the binding from the first config tmux itself would load
if ! command -v tmux &>/dev/null; then
  say skip "tmux  not installed: no popup, ctrl+g alone"
else
  tmux_conf=$HOME/.tmux.conf
  for f in "$HOME/.tmux.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"; do
    if [[ -f $f ]]; then tmux_conf=$f; break; fi
  done
  if grep -qsF 'tmux/claude-annotate.conf' "$tmux_conf"; then
    say ok "tmux  $tmux_conf"
  else
    printf '\n# claude-annotate: prefix + i\nsource-file %s/tmux/claude-annotate.conf\n' "$short" >> "$tmux_conf"
    say added "tmux  $tmux_conf"
  fi
  # a running server only reads its config at start
  if tmux list-sessions &>/dev/null; then
    tmux source-file "$repo/tmux/claude-annotate.conf"
    say loaded "tmux  prefix + i is live"
  fi
fi

# --- requirements
for cmd in nvim claude; do
  command -v "$cmd" &>/dev/null || say MISSING "$cmd"
done
if command -v nvim &>/dev/null; then
  probe() { nvim --headless -c "lua io.write($1 and '1' or '0')" -c 'qa!' 2>/dev/null; }
  [[ $(probe 'vim.fn.has("nvim-0.10") == 1') == 1 ]] || say MISSING "nvim 0.10+ (uses vim.system)"
fi
