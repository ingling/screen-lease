#!/bin/bash
# CLI tests for screen-lease. Uses a fresh temp state dir; never touches the real lease.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
S="$HERE/bin/screen-lease"
export SCREEN_LEASE_DIR="$(mktemp -d)"
CFG_DIR="$(mktemp -d)"
echo '{"ask_seconds": 0}' >"$CFG_DIR/noask.json"
echo '{"ask_seconds": 2, "reconfirm_after_seconds": 60}' >"$CFG_DIR/ask.json"
export SCREEN_LEASE_CONFIG="$CFG_DIR/noask.json"
unset SCREEN_LEASE_OWNER SCREEN_LEASE_LABEL
fails=0

expect() { # want-rc description cmd...
	local want="$1" desc="$2"
	shift 2
	"$@" >/dev/null 2>&1
	local rc=$?
	if [ "$rc" = "$want" ]; then echo "ok   $desc"; else echo "FAIL $desc (rc=$rc, want $want)"; fails=$((fails + 1)); fi
}
set_hb() { sed -i '' "s/^heartbeat=.*/heartbeat=$1/" "$SCREEN_LEASE_DIR/lease"; }

expect 0 "A acquires" "$S" acquire --owner A --label alpha "test A"
expect 0 "A re-acquires (idempotent)" "$S" acquire --owner A "test A again"
expect 2 "B blocked while A holds" "$S" acquire --owner B "test B"
expect 0 "A check ok" "$S" check --owner A
expect 2 "B cannot run under A's lease" "$S" run --owner B -- true
expect 4 "run passes the step's exit code" "$S" run --owner A -- sh -c 'exit 4'
touch "$SCREEN_LEASE_DIR/paused"
expect 3 "check reports pause" "$S" check --owner A
expect 3 "run refuses while paused" "$S" run --owner A -- true
expect 3 "acquire refuses while paused" "$S" acquire --owner A "x"
expect 3 "wait-resume times out" "$S" wait-resume 1
rm "$SCREEN_LEASE_DIR/paused"
expect 0 "wait-resume returns when not paused" "$S" wait-resume 1
expect 0 "need-you" "$S" need-you --owner A "pick a file"
expect 1 "run refuses in need-you state" "$S" run --owner A -- true
expect 2 "B blocked during need-you" "$S" acquire --owner B "x"
expect 0 "working resumes driving" "$S" working --owner A
set_hb 100
expect 0 "B takes over a stale lease" "$S" acquire --owner B "takeover"
grep -q '^owner=B$' "$SCREEN_LEASE_DIR/lease" && echo "ok   owner is now B" || { echo "FAIL owner not B"; fails=$((fails + 1)); }
"$S" run --owner B -- sleep 3 &
sleep 1
set_hb 100
expect 2 "busy step keeps an old heartbeat from going stale" "$S" acquire --owner A "x"
wait
expect 0 "B heartbeat" "$S" heartbeat --owner B
expect 2 "A cannot release B's live lease" "$S" release --owner A
expect 0 "B releases" "$S" release --owner B "all done"
grep -q '^state=free$' "$SCREEN_LEASE_DIR/lease" && echo "ok   state free" || { echo "FAIL not free"; fails=$((fails + 1)); }
expect 0 "anyone acquires after release" "$S" acquire --owner A "again"
expect 0 "clear" "$S" clear
expect 2 "heartbeat without lease fails" "$S" heartbeat --owner A

# --- Claude Code permission-prompt hooks ---
L="$SCREEN_LEASE_DIR/lease"
st() { grep -m1 '^state=' "$L" | cut -d= -f2-; }
is() { # want-state description
	if [ "$(st)" = "$1" ]; then echo "ok   $2"; else echo "FAIL $2 (state=$(st), want $1)"; fails=$((fails + 1)); fi
}
expect 0 "hook on a free lease: no-op" "$S" hook --owner A prompt
is free "free lease stays free"
"$S" acquire --owner A "hooks" >/dev/null
expect 0 "other session's prompt: exit 0" "$S" hook --owner B prompt </dev/null
is driving "other session's prompt leaves the light red"
expect 0 "holder's prompt" "$S" hook --owner A prompt </dev/null
is need-you "holder's prompt turns the light yellow"
grep -q '^message=Approve a permission prompt in Claude$' "$L" && echo "ok   default prompt message" || { echo "FAIL prompt message"; fails=$((fails + 1)); }
expect 2 "B still blocked while A waits on a prompt" "$S" acquire --owner B "x"
expect 0 "other session's answer: exit 0" "$S" hook --owner B answered </dev/null
is need-you "other session's answer changes nothing"
expect 0 "holder's answer" "$S" hook --owner A answered </dev/null
is driving "holder's answer turns the light red again"
expect 0 "answer with no prompt pending: no-op" "$S" hook --owner A answered </dev/null
is driving "still driving"
"$S" need-you --owner A "pick a file" >/dev/null
expect 0 "prompt during the agent's own need-you" "$S" hook --owner A prompt </dev/null
expect 0 "answer during the agent's own need-you" "$S" hook --owner A answered </dev/null
is need-you "agent's own need-you is left alone"
grep -q '^message=pick a file$' "$L" && echo "ok   agent's message kept" || { echo "FAIL agent's message replaced"; fails=$((fails + 1)); }
"$S" working --owner A >/dev/null
"$S" hook --owner A prompt </dev/null
expect 0 "run after the prompt was approved" "$S" run --owner A -- true
is driving "run clears a hook's need-you (approved prompt was a UI step)"
[ -f "$SCREEN_LEASE_DIR/prompt" ] && { echo "FAIL prompt marker left behind"; fails=$((fails + 1)); } || echo "ok   prompt marker cleared"
"$S" hook --owner A prompt </dev/null
expect 0 "heartbeat after the prompt" "$S" heartbeat --owner A
is driving "heartbeat clears a hook's need-you"
expect 0 "owner from the hook's stdin session_id" sh -c "printf '%s' '{\"session_id\": \"A\", \"hook_event_name\": \"PermissionRequest\"}' | env -u CLAUDE_CODE_HOST_SESSION_ID -u CLAUDE_CODE_SESSION_ID SCREEN_LEASE_OWNER=other '$S' hook prompt"
is need-you "stdin session_id matches the holder"
expect 0 "answered via stdin session_id" sh -c "printf '%s' '{\"session_id\":\"A\"}' | SCREEN_LEASE_OWNER=other '$S' hook answered"
is driving "back to driving"
j() { printf '{"session_id":"A","hook_event_name":"%s","tool_name":"%s","tool_input":{"command":"echo \\"session_id\\": \\"B\\""}}' "$1" "$2"; }
j PermissionRequest Bash | "$S" hook --owner other prompt
is need-you "prompt for Bash (owner from JSON with a decoy in tool_input)"
j PostToolUse Read | "$S" hook --owner other answered
is need-you "a different tool finishing does not answer the Bash prompt"
j Stop "" | "$S" hook --owner other answered
is driving "Stop (no tool_name) answers it"
j PermissionRequest Bash | "$S" hook --owner other prompt
j PostToolUse Bash | "$S" hook --owner other answered
is driving "the same tool finishing answers it"
j PermissionRequest Bash | "$S" hook --owner other prompt
is need-you "prompt again"
j PostToolUse Bash | SCREEN_LEASE_DIR=/nonexistent/x "$S" hook answered 2>/dev/null; echo "ok   unwritable state dir does not hang (rc=$?)"
"$S" working --owner A >/dev/null
expect 0 "env owner wins without stdin" sh -c "SCREEN_LEASE_OWNER=A '$S' hook prompt </dev/null"
is need-you "env owner matches the holder"
expect 0 "release during a prompt" "$S" release --owner A "done"
expect 0 "answer after release: no-op" "$S" hook --owner A answered </dev/null
is free "release wins over a late answer"
expect 0 "clear" "$S" clear

# --- ready-to-use-the-screen dialog (a fake responder stands in for the menu bar app) ---
export SCREEN_LEASE_CONFIG="$CFG_DIR/ask.json" SCREEN_LEASE_ASSUME_UI=1
D="$SCREEN_LEASE_DIR"
respond() { # answer: waits for an ask file, then answers it
	for _ in $(seq 1 40); do
		if [ -f "$D/ask" ]; then
			printf 'id=%s\nanswer=%s\n' "$(grep '^id=' "$D/ask" | cut -d= -f2-)" "$1" >"$D/ask-response"
			return
		fi
		sleep 0.1
	done
}
respond wait &
expect 4 "Wait on the dialog -> exit 4" "$S" acquire --owner C --label gamma "needs PS"
wait
grep -q '^state=waiting$' "$D/lease" && echo "ok   state waiting" || { echo "FAIL not waiting"; fails=$((fails + 1)); }
expect 3 "wait-resume blocks while waiting" "$S" wait-resume --owner C 1
sed -i '' 's/^state=waiting$/state=approved/' "$D/lease" # what the menu's "Let it go ahead" does
expect 0 "wait-resume returns once approved" "$S" wait-resume --owner C 1
expect 2 "approved lease is reserved for its owner" "$S" acquire --owner Z "x"
rm -f "$D/ask"
expect 0 "acquire after approval: no dialog" "$S" acquire --owner C "needs PS"
[ -f "$D/ask" ] && { echo "FAIL dialog shown after approval"; fails=$((fails + 1)); } || echo "ok   no dialog after approval"
expect 0 "release" "$S" release --owner C "done"
expect 0 "same owner back within reconfirm window: no dialog" "$S" acquire --owner C "again"
[ -f "$D/ask" ] && { echo "FAIL dialog shown inside window"; fails=$((fails + 1)); } || echo "ok   no dialog inside window"
expect 0 "release" "$S" release --owner C "done"
respond go &
expect 0 "different owner: Go ahead -> acquired" "$S" acquire --owner E "other task"
wait
expect 0 "release" "$S" release --owner E "done"
set_hb 100
start=$(date +%s)
expect 0 "no answer: auto-go after timeout" "$S" acquire --owner E "after a long gap"
el=$(($(date +%s) - start))
[ "$el" -ge 2 ] && echo "ok   waited for the timeout (${el}s)" || { echo "FAIL did not wait (${el}s)"; fails=$((fails + 1)); }
expect 0 "release" "$S" release --owner E "done"
set_hb 100
expect 0 "--now skips the dialog" "$S" acquire --owner E --now "said go in chat"
[ -f "$D/ask" ] && { echo "FAIL dialog shown with --now"; fails=$((fails + 1)); } || echo "ok   no dialog with --now"

mv "$SCREEN_LEASE_DIR" "${TMPDIR:-/tmp}/screen-lease-test-done.$$" 2>/dev/null
mv "$CFG_DIR" "${TMPDIR:-/tmp}/screen-lease-test-cfg.$$" 2>/dev/null
echo "$fails failure(s)"
exit $((fails > 0))
