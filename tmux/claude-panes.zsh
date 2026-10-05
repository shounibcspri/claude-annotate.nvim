# Claude Code panes in tmux. Source this from your zshrc.
#
# A pane running `claude attach <id>` draws on the terminal's alternate screen: background
# sessions are always fullscreen, so tmux keeps no scrollback for that pane and copy mode
# (prefix + [) and the prefix + i snapshot see only the current screen. Resuming the session in the foreground instead
# gives the classic renderer and normal scrollback.

# List Claude panes; for BROKEN ones show the attached background session and offer to stop it.
function tmcheck(){
  local loc alt hist cmd ppid wname id st ans json
  local -U ids=()
  local f='#{session_name}:#{window_index}|#{alternate_on}|#{history_size}|#{pane_current_command}|#{pane_pid}|#{window_name}'
  while IFS='|' read -r loc alt hist cmd ppid wname; do
    [[ $cmd == claude ]] || continue
    st=ok id=
    if (( alt )); then
      st=BROKEN
      id=$(pgrep -P $ppid -a -f 'claude attach' | awk '{print $NF}')
      [[ -n $id ]] && ids+=$id
    fi
    printf "%-7s hist=%-7s %-8s %s%s\n" $st $hist $loc "$wname" "${id:+  [bg $id]}"
  done < <(tmux list-panes -a -F "$f")

  (( ${#ids} )) || return 0
  json=$(claude agents --json)
  echo
  for id in $ids; do
    printf "  %s  %s\n" $id "$(jq -r --arg id $id '.[] | select(.sessionId | startswith($id)) | "\(.status)  \(.name)"' <<< $json)"
  done
  read -r "ans?Stop these background sessions? [Y/n] "
  [[ -z $ans || $ans == [yY]* ]] || return 0
  for id in $ids; do claude stop $id; done
  echo "Then in each pane: claude --resume <id>"
}
