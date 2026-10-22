# Sourced by smoke.sh after the pane readers; isolated parser/retry fixtures.
codex_text_is() { # expected, frame rows...
  local want="$1" got; shift
  got=$(printf '%s\n' "$@" | codex_prompt_text)
  [ "$got" = "$want" ]
}
check "Codex composer joins hard-wrapped continuation rows" codex_text_is $'[crew] You are agent\nimpl in crew test.' \
  '› [crew] You are agent' '  impl in crew test.' '────────' '  Waiting for startup'
check "Codex composer retains appended text" codex_text_is $'[crew] intro\nand unrelated text' \
  '› [crew] intro' '  and unrelated text' '────────' '  footer'
check "Codex composer uses the latest prompt and ignores its footer" codex_text_is 'new draft' \
  '› old draft' '  old continuation' '› new draft' '────────' '  footer'
check "Codex placeholder stays idle" codex_text_is '' '› Ask Codex to do anything…'

sed -n '/^intro_submit()/,/^}/p' "$CREW" > "$CREW_HOME/intro-wrapped.sh"
wrapped_retry() ( # extra draft text, expected Enter count — no real pane I/O
  . "$CREW_HOME/intro-wrapped.sh"
  local trace extra="$1" expected="$2"
  trace=$(mktemp "$CREW_HOME/wrapped-enters.XXXXXX")
  sleep() { :; }
  owns_pane() { return 0; }
  pane_hold() { [ -s "$trace" ] || printf 'draft\tunsubmitted draft'; }
  draft_text() {
    printf '%s\n' '› [crew] intro line' "  with continuation$extra" '────────' | codex_prompt_text
  }
  tmux() { [ "$*" = 'send-keys -t %test Enter' ] || return 1; printf 'Enter\n' >> "$trace"; }
  intro_submit impl %test '[crew] intro line with continuation' 2> "$CREW_HOME/wrapped-retry-err"
  if [ "$expected" = 0 ]; then
    [ ! -s "$trace" ] && grep -q "not crew's startup line" "$CREW_HOME/wrapped-retry-err"
  else
    [ "$(wc -l < "$trace" | tr -d ' ')" = "$expected" ] && [ ! -s "$CREW_HOME/wrapped-retry-err" ]
  fi
)
check "startup retries the exact hard-wrapped Codex intro once" wrapped_retry '' 1
check "startup refuses an intro with appended text" wrapped_retry ' plus a user draft' 0
check "startup refuses appended text after an empty composer row" wrapped_retry $'\n  \n  extra text' 0
