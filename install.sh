#!/usr/bin/env bash
# Install claude-annotate: the nvim module, the tmux binding and the zsh pane tools.
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

# --- tmux: source the binding from the first config tmux itself would load
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

# --- zsh: tmcheck; an existing source line anywhere in the zsh config counts
zshrc=${ZDOTDIR:-$HOME}/.zshrc
if grep -rqsF 'tmux/claude-panes.zsh' "$zshrc" "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"; then
  say ok "zsh   tmcheck already sourced"
else
  printf '\n# claude-annotate: tmcheck\nsource %s/tmux/claude-panes.zsh\n' "$short" >> "$zshrc"
  say added "zsh   $zshrc (open a new shell for tmcheck)"
fi

# --- requirements
for cmd in nvim tmux jq claude; do
  command -v "$cmd" &>/dev/null || say MISSING "$cmd"
done
if command -v nvim &>/dev/null; then
  probe() { nvim --headless -c "lua io.write($1 and '1' or '0')" -c 'qa!' 2>/dev/null; }
  [[ $(probe 'vim.fn.has("nvim-0.10") == 1') == 1 ]] || say MISSING "nvim 0.10+ (uses vim.system)"
  [[ $(probe 'pcall(require, "baleia")') == 1 ]] || say note "baleia.nvim not found: the popup works, without colours"
fi
