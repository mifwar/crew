# Detect the actual agent behind real OS wrappers, using cat as a fake Codex.
wrapper_detection_test() {
  local wrapper pane got bad=0 index=0
  for wrapper in /usr/bin/caffeinate 'nice -n 0' env /usr/bin/time; do
    index=$((index + 1))
    pane=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" "$wrapper '$CREW_HOME/helper/codex'")
    sleep 0.3
    got=$(bash -c "$(sed -n '/^short_cli()/,/^}/p;/^detect_cli()/,/^}/p' "$CREW"); detect_cli $pane")
    [ "$got" = codex ] || bad=1
    "$CREW" adopt "wrapper-$index" lead="$pane" > "$CREW_HOME/wrapper-$index-out" 2>&1 || bad=1
    [ "$(awk -F '\t' '$1=="lead"{print $3}' "$CREW_HOME/wrapper-$index/panes")" = codex ] || bad=1
    [ "$(tmux display-message -p -t "$pane" '#{@crew_cli}')" = codex ] || bad=1
    "$CREW" -s "wrapper-$index" down >/dev/null 2>&1
    tmux kill-pane -t "$pane"
  done
  printf 't\n' > "$CREW_HOME/.current"
  [ "$bad" = 0 ]
}
check "wrapper detection and adoption keep Codex through caffeinate/nice/env/time" wrapper_detection_test
