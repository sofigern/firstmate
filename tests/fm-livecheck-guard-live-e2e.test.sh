#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the live-status Stop hook
# (bin/fm-livecheck-guard.sh --claude, docs/livecheck-guard.md).
# Proves, against the real installed Claude Code and the real tracked hook
# registration, the two facts the portable suite can only assume: the Stop
# payload carries last_assistant_message and a readable transcript_path, and a
# reply naming an unchecked pull request is blocked once, the model runs the
# one command the banner names, and the same reply then ends the turn.
# The project and FM_HOME are isolated with no work in flight, so the
# supervision guard and auto-arm stay silent; Claude keeps using its existing
# managed authentication. The verifier is a lab fake, so no forge is called.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_LIVECHECK_LIVE_E2E claude

LAB="$ROOT/.livecheck-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
OUTPUT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)
PR_URL='https://github.com/kunchenguid/firstmate/pull/7119'

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"

# The lab's verifier answers without a forge and records every call.
cat > "$PROJECT/bin/fm-verify-items.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HOME_DIR/state/verify-calls.log"
printf 'pr\t%s\tmerged\tmerged_at=2026-10-10T09:00:00Z checks=pass\n' "$PR_URL"
SH
chmod +x "$PROJECT/bin/fm-verify-items.sh"

PROMPT="Reply with exactly this sentence and nothing else: Captain, $PR_URL is still open. Use no tool for that first reply. If a Stop hook feedback message then asks you to check items, run exactly the one command it prints, with Bash, and after it returns reply again with exactly the same sentence and stop."

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
    --effort low --output-format stream-json --verbose
) > "$OUTPUT" 2>&1 || fail "Claude live-check session failed under $CLAUDE_VERSION: $(tail -20 "$OUTPUT")"

BLOCKS=$(grep -c 'FM_LIVECHECK: THE REPLY NAMES WORK YOU DID NOT CHECK LIVE THIS TURN' "$OUTPUT" || true)
[ "$BLOCKS" -ge 1 ] || fail "$CLAUDE_VERSION: the Stop hook never blocked the unchecked reply: $(tail -30 "$OUTPUT")"
CALLS=$(wc -l < "$HOME_DIR/state/verify-calls.log" 2>/dev/null | tr -d ' ')
[ "${CALLS:-0}" -ge 1 ] || fail "$CLAUDE_VERSION: the model never ran the verifier command the banner named: $(tail -30 "$OUTPUT")"
grep -q "$PR_URL" "$HOME_DIR/state/verify-calls.log" || fail "$CLAUDE_VERSION: the verifier was not asked about the named PR: $(cat "$HOME_DIR/state/verify-calls.log")"
FINAL=$(jq -r 'select(.type == "result") | .result' "$OUTPUT" 2>/dev/null | tail -1)
case "$FINAL" in
  *"$PR_URL"*) ;;
  *) fail "$CLAUDE_VERSION: the final reply did not keep the PR URL, so the allowed stop was not exercised: $FINAL" ;;
esac
[ ! -e "$HOME_DIR/state/.livecheck-blocks" ] || fail "$CLAUDE_VERSION: the allowed stop left the block count behind: $(cat "$HOME_DIR/state/.livecheck-blocks")"
! grep -q 'the reply still names work not checked live' "$OUTPUT" \
  || fail "$CLAUDE_VERSION: the budget was exhausted instead of the verified reply being allowed"

printf 'harness: %s\n' "$CLAUDE_VERSION"
printf 'ok - claude live: the Stop payload carried the reply and transcript, the unchecked PR was blocked %s time(s)\n' "$BLOCKS"
printf 'ok - claude live: the model ran the banner'"'"'s verifier command %s time(s) and the checked reply ended the turn\n' "$CALLS"
