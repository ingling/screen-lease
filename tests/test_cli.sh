#!/bin/bash
# CLI tests for screen-lease. Uses a fresh temp state dir; never touches the real lease.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
S="$HERE/bin/screen-lease"
export SCREEN_LEASE_DIR="$(mktemp -d)"
export SCREEN_LEASE_CONFIG=/nonexistent
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
mv "$SCREEN_LEASE_DIR" "${TMPDIR:-/tmp}/screen-lease-test-done.$$" 2>/dev/null
echo "$fails failure(s)"
exit $((fails > 0))
