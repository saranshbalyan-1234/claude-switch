#!/bin/bash
# Tests everything against throwaway data; your real login and the installed app's settings are not touched.
#   1. claude-switch with the macOS Keychain store and with the file store Linux uses
#   2. claude-switch notify and hook (the Claude Code hooks), hooks install/remove, and finding/quitting running sessions
#   3. the app's logic (dots, alerts, pace, resets, suggestions...), via ClaudeSwitch --selftest
root=$(cd "$(dirname "$0")/.." && pwd)
S=${S:-$root/src/claude-switch}
tmpbin=$(mktemp -d) d=$(mktemp -d)
export CLAUDE_SWITCH_CRED_SVC=cs-test-cred CLAUDE_SWITCH_STASH_SVC=cs-test-stash CLAUDE_SWITCH_CONFIG=$d/c.json CLAUDE_SWITCH_LIST=$d/list \
       CLAUDE_SWITCH_CRED_FILE=$d/creds.json CLAUDE_SWITCH_STASH_DIR=$d/logins CLAUDE_SWITCH_ATTENTION=$d/attention CLAUDE_SWITCH_QUIET=1 \
       CLAUDE_SWITCH_ATTENTION_OFF=$d/not-off CLAUDE_SWITCH_SETTINGS=$d/settings.json CLAUDE_SWITCH_SESSIONS=$d/sessions \
       CLAUDE_SWITCH_HOOK_CMD="$S hook" CLAUDE_SWITCH_PROC_FILTER=$d CLAUDE_SWITCH_REQUESTS=$d/requests \
       CLAUDE_SWITCH_APPROVALS_ON=$d/approvals CLAUDE_SWITCH_LOG=$d/log CLAUDE_SWITCH_WAIT_FILE=$d/wait  # only the stand-in Claude processes below: never quit real ones
pad=$(printf 'x%.0s' {1..1500})
future=$(( $(date +%s) + 86400 ))000
cleanup() {
  for a in "$USER" a@x b@x c@x d@x; do
    security delete-generic-password -s cs-test-cred -a "$a" >/dev/null 2>&1
    security delete-generic-password -s cs-test-stash -a "$a" >/dev/null 2>&1
  done
  rm -rf "$d" "$tmpbin"
}
trap cleanup EXIT
fail() { echo "FAIL ($CLAUDE_SWITCH_STORE store): $*"; exit 1; }
kc() { if [ "$CLAUDE_SWITCH_STORE" = keychain ]; then security find-generic-password -s cs-test-cred -a "$USER" -w; else cat "$d/creds.json"; fi; }
write_cred() {
  if [ "$CLAUDE_SWITCH_STORE" = keychain ]; then
    printf 'add-generic-password -U -s cs-test-cred -a "%s" -X "%s"\n' "$USER" "$(printf %s "$1" | xxd -p | tr -d '\n')" | security -i >/dev/null
  else
    printf %s "$1" > "$d/creds.json"
  fi
}
login() { # simulate /login: email org token [refreshTokenExpiresAt]
  jq -n --arg e "$1" --arg o "$2" '{oauthAccount:{emailAddress:$e,organizationUuid:$o,displayName:"Zoë"},keep:1}' > "$CLAUDE_SWITCH_CONFIG"
  write_cred "$(jq -nc --arg o "$2" --arg t "$3$pad" --argjson x "${4:-$future}" '{claudeAiOauth:{accessToken:$t,refreshToken:"r",refreshTokenExpiresAt:$x},organizationUuid:$o,mcpOAuth:{gh:"m"}}')"
}
tok() { kc | jq -r '.claudeAiOauth.accessToken[0:3]'; }
on() { [ "$(jq -r .oauthAccount.emailAddress "$CLAUDE_SWITCH_CONFIG")" = "$1" ] && [ "$(tok)" = "$2" ] || fail "expected $1 with $2, got $(jq -r .oauthAccount.emailAddress "$CLAUDE_SWITCH_CONFIG") $(tok)"; }

scenario() {
  rm -f "$d/list"
  # save never switches
  login a@x orgA A1-; $S save | grep -q "Saved a@x" || fail "save a"; on a@x A1-
  $S | grep -q "Only a@x is saved" || fail "single account message"; on a@x A1-
  login b@x orgB B1-; $S save >/dev/null; on b@x B1-
  login c@x orgC C1-; $S save | grep -q "Saved accounts: a@x b@x c@x" || fail "list after 3 saves"; on c@x C1-

  # cycles c -> a -> b -> c, last wraps to first
  $S | grep -q "Switched: c@x -> a@x" || fail "c -> a"; on a@x A1-
  [ "$(kc | jq -r .mcpOAuth.gh)" = m ] || fail "mcp token should survive"
  [ "$(jq -r .keep "$CLAUDE_SWITCH_CONFIG")" = 1 ] || fail "rest of config should survive"
  $S >/dev/null; on b@x B1-
  $S >/dev/null; on c@x C1-

  # refresh while on c is kept
  write_cred "$(kc | jq -c --arg t "C2-$pad" '.claudeAiOauth.accessToken=$t')"
  $S b@x | grep -q "Switched: c@x -> b@x" || fail "explicit c -> b"; on b@x B1-
  $S c@x >/dev/null; on c@x C2-
  $S c@x | grep -q "Already on c@x" || fail "explicit same"

  # unknown email: error, nothing changes
  $S z@x 2>&1 | grep -q "no saved login for z@x" || fail "unknown email"; on c@x C2-

  # expired login gets saved, then warned about on the way back
  login a@x orgA A3- 1000; $S save >/dev/null
  $S c@x >/dev/null; $S a@x | grep -q "saved login for a@x has expired" || fail "expired warning"; on a@x A3-
  $S b@x | grep -q "expired" && fail "no warning for valid login"

  # logged out / mismatched: refuse, touch nothing
  jq '.oauthAccount.organizationUuid="orgX"' "$CLAUDE_SWITCH_CONFIG" > "$d/t" && mv "$d/t" "$CLAUDE_SWITCH_CONFIG"
  $S 2>/dev/null && fail "mismatch should fail"; [ "$(tok)" = B1- ] || fail "mismatch must not change creds"
  write_cred '{"mcpOAuth":{"gh":"m"}}'; $S save 2>&1 | grep -q "not logged in" || fail "logged-out save should fail"

  # Restore a saved login even when only MCP credentials remain.
  $S b@x >/dev/null; on b@x B1-
  [ "$(kc | jq -r .mcpOAuth.gh)" = m ] || fail "restore must preserve MCP tokens"
  write_cred '{"mcpOAuth":{"gh":"m"}}'
  $S c@x >/dev/null; on c@x C2-
  write_cred '{"mcpOAuth":{"gh":"m"}}'

  # add: works while logged out, signs in through claude (a stub here), saves the new account; the same account again is reported
  CLAUDE_SWITCH_CLAUDE=$tmpbin/claude $S add | grep -q "Saved d@x. Saved accounts: a@x b@x c@x d@x" || fail "add d"; on d@x D1-
  CLAUDE_SWITCH_CLAUDE=$tmpbin/claude $S add d@x | grep -q "Still on d@x" || fail "add same account"
  $S a@x >/dev/null; on a@x A3-

  # remove: forgets a saved account and its login; refuses the current one and unknown ones; switching skips it after
  $S remove a@x 2>&1 | grep -q "logged in as a@x" || fail "remove current account should fail"
  $S remove z@x 2>&1 | grep -q "z@x is not saved" || fail "remove unknown"
  $S remove c@x | grep -q "Removed c@x. Saved accounts: a@x b@x d@x" || fail "remove c"; on a@x A3-
  $S c@x 2>&1 | grep -q "no saved login for c@x" || fail "removed account must not switch"
  $S >/dev/null; on b@x B1-; $S >/dev/null; on d@x D1-; $S >/dev/null; on a@x A3-
}
# Stands in for `claude auth login [--email e]`: logs in as e, or d@x.
printf '#!/bin/bash\n[ "$1 $2" = "auth login" ] || exit 1\nlogin "${4:-d@x}" orgD D1-\n' > "$tmpbin/claude"; chmod +x "$tmpbin/claude"
export -f login write_cred; export d pad future

for store in keychain file; do
  export CLAUDE_SWITCH_STORE=$store
  scenario
  if [ $store = file ]; then  # saved logins must be private
    [ "$(stat -f %Lp "$d/logins")" = 700 ] || fail "logins folder should be 700"
    for f in "$d"/logins/*.json; do [ "$(stat -f %Lp "$f")" = 600 ] || fail "$f should be 600"; done
  fi
  echo "claude-switch ($store store): ALL PASS"
done

# notify: what Claude is waiting on goes to the attention file, newest last, at most 5 entries
CLAUDE_SWITCH_STORE=keychain
echo '{"message":"Claude needs your permission to use Bash","cwd":"/x/proj","notification_type":"permission_prompt"}' \
  | __CFBundleIdentifier=com.microsoft.VSCode CLAUDE_CODE_ENTRYPOINT=claude-vscode $S notify
[ "$(tail -1 "$d/attention" | cut -f2-6)" = "$(printf 'proj\tClaude needs your permission to use Bash\t/x/proj\tcom.microsoft.VSCode\teditor')" ] \
  || fail "notify: permission message with where it runs: $(tail -1 "$d/attention" | cut -f2-6)"
echo '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which DB?"}]},"cwd":"/x/p2"}' \
  | __CFBundleIdentifier=com.apple.Terminal CLAUDE_CODE_ENTRYPOINT=cli $S notify
[ "$(tail -1 "$d/attention" | cut -f2-6)" = "$(printf 'p2\tWhich DB?\t/x/p2\tcom.apple.Terminal\tterminal')" ] || fail "notify: question from a terminal"
echo 'not json' | $S notify || fail "notify: bad input must not fail"
tail -1 "$d/attention" | grep -q "Claude needs your attention" || fail "notify: fallback message"
for i in 1 2 3 4 5 6; do echo '{}' | $S notify; done
[ "$(wc -l < "$d/attention")" -eq 5 ] || fail "notify: keeps 5 entries"
$S notify clear; [ -s "$d/attention" ] && fail "notify clear"
touch "$d/off"; echo '{"message":"x"}' | CLAUDE_SWITCH_ATTENTION_OFF=$d/off $S notify
[ -s "$d/attention" ] && fail "notify: turned off must do nothing"
echo "claude-switch notify: ALL PASS"

# hooks: install adds one entry per event beside other hooks, replacing older claude-switch ones; remove takes only ours
echo '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],"Notification":[{"matcher":"idle_prompt","hooks":[{"type":"command","command":"/u/.local/bin/claude-switch notify","async":true}]}]}}' > "$d/settings.json"
$S hooks status | grep -q "not set up" || fail "hooks: status before install"
$S hooks install >/dev/null || fail "hooks install"
$S hooks status | grep -q "are set up" || fail "hooks: status after install"
[ "$(jq '[.hooks[][] | select(.hooks[0].command | test("claude-switch"))] | length' "$d/settings.json")" = 11 ] || fail "hooks: one per event and two waiting ones, old one replaced"
[ "$(jq -r '.hooks.Stop[0].hooks[0].command, .model' "$d/settings.json" | paste -sd ' ' -)" = "say done x" ] || fail "hooks: others kept"
$S hooks install >/dev/null; [ "$(jq '[.hooks[][]] | length' "$d/settings.json")" = 12 ] || fail "hooks: installing twice adds nothing"
$S hooks preview remove | grep -q '^-.*claude-switch request' || fail "hooks preview"
jq 'del(.hooks.Stop[1])' "$d/settings.json" > "$d/t" && mv "$d/t" "$d/settings.json"
$S hooks status | grep -q "missing: Stop" || fail "hooks: partly set up"
$S hooks remove >/dev/null
[ "$(jq -c .hooks "$d/settings.json")" = '{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}' ] || fail "hooks remove"

# hook: one file per session saying what it's doing, gone when the session ends; waiting moments reach notify as before
h() { echo "$1" | CLAUDE_CODE_ENTRYPOINT=claude-vscode __CFBundleIdentifier=com.microsoft.VSCode $S hook; }
field() { cut -d $'\x1f' -f "$1" "$d/sessions/s1"; }
: > "$d/attention"
jq -n '{oauthAccount:{emailAddress:"a@x"}}' > "$CLAUDE_SWITCH_CONFIG"
h '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/x/proj","source":"startup"}'
[ "$(field 3) $(field 4) $(field 6) $(field 9)" = "Started proj editor a@x" ] || fail "hook: session start"
jq -n '{oauthAccount:{emailAddress:"b@x"}}' > "$CLAUDE_SWITCH_CONFIG"
h '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/x/proj","tool_name":"Bash"}'
[ "$(field 3) $(field 9)" = "Running Bash a@x" ] || fail "hook: a session keeps the account it started with"
h '{"hook_event_name":"Notification","session_id":"s1","cwd":"/x/proj","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}'
[ "$(field 3)" = "Claude needs your permission to use Bash" ] || fail "hook: notification status"
tail -1 "$d/attention" | grep -q "permission to use Bash" || fail "hook: notification reaches notify"
h '{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/x/proj"}'
[ -s "$d/attention" ] && fail "hook: a prompt clears waiting"; [ "$(field 3)" = Working ] || fail "hook: working"
h '{"hook_event_name":"Stop","session_id":"s1","cwd":"/x/proj"}'; [ "$(field 3)" = Done ] || fail "hook: stop"
h 'not json' || fail "hook: bad input must not fail"
h '{"hook_event_name":"Stop","session_id":"../../evil"}'; [ -e "$d/evil" ] && fail "hook: session id stays in its folder"
h '{"hook_event_name":"SessionEnd","session_id":"s1"}'; [ -e "$d/sessions/s1" ] && fail "hook: session end removes it"
# edits: real line counts per edit and per file; the recap adds them up
h '{"hook_event_name":"SessionStart","session_id":"s2","cwd":"/x/proj","source":"startup"}'
h '{"hook_event_name":"UserPromptSubmit","session_id":"s2","cwd":"/x/proj"}'
h '{"hook_event_name":"PostToolUse","session_id":"s2","cwd":"/x/proj","tool_name":"Edit","tool_input":{"file_path":"/x/proj/a.ts","old_string":"a\nb\nc","new_string":"a\nB\nc\nd"}}'
[ "$(cut -d $'\x1f' -f3 "$d/sessions/s2")" = "Edited a.ts (+2 −1)" ] || fail "hook: edit counts"
h '{"hook_event_name":"PostToolUse","session_id":"s2","cwd":"/x/proj","tool_name":"Write","tool_input":{"file_path":"/x/proj/b.ts","content":"1\n2\n3\n"}}'
h '{"hook_event_name":"PostToolUse","session_id":"s2","cwd":"/x/proj","tool_name":"MultiEdit","tool_input":{"file_path":"/x/proj/a.ts","edits":[{"old_string":"x","new_string":"y\nz"}]}}'
[ "$(tr $'\x1f' ' ' < "$d/sessions/s2.files" | paste -sd ',' -)" = "/x/proj/b.ts 3 0,/x/proj/a.ts 4 2" ] || fail "hook: files touched"
$S recap | grep -q "Edits: 3, +7 −2 lines" || fail "recap: $($S recap)"
h '{"hook_event_name":"SessionEnd","session_id":"s2"}'; [ -e "$d/sessions/s2.files" ] && fail "hook: session end removes files list"

# request: waits for the app's answer only when that's on; allow, deny, answers, in Claude, and no answer
r() { echo "$1" | CLAUDE_SWITCH_ASSUME_APP=1 CLAUDE_SWITCH_REQUEST_WAIT=5 $S request; }
answer() { ( for _ in $(seq 40); do f=$(ls "$d"/requests/*.json 2>/dev/null | head -1); [ -n "$f" ] && break; sleep 0.1; done
             printf '%s' "$1" > "${f%.json}.answer" ) & }
perm='{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/x/proj","tool_name":"Bash","tool_input":{"command":"npm test"}}'
[ -z "$(r "$perm")" ] || fail "request: off unless turned on"
touch "$d/approvals"
answer allow; r "$perm" | grep -q '"behavior":"allow"' || fail "request: allow"; wait
answer deny; r "$perm" | grep -q '"behavior":"deny"' || fail "request: deny"; wait
answer claude; [ -z "$(r "$perm")" ] || fail "request: in Claude says nothing"; wait
answer '{"answers":[{"question":"Which DB?","answer":"Postgres"}]}'
r '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/x/proj","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which DB?","options":[{"label":"Postgres"}]}]}}' \
  | grep -q '"Which DB?\\" → Postgres' || fail "request: question answered"; wait
[ -z "$(echo "$perm" | CLAUDE_SWITCH_ASSUME_APP=1 CLAUDE_SWITCH_REQUEST_WAIT=1 $S request)" ] || fail "request: no answer says nothing"
# always: Claude's own suggestion when there is one, otherwise a rule added to the user settings; dismiss; edit diffs
answer always; r "$perm" | grep -q '"behavior":"allow"' || fail "request: always allows"; wait
$S rules list | grep -qxF 'Bash(npm test:*)' || fail "rules: always adds npm test"
answer always; r '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ls:*"}]}]}' \
  | grep -q '"updatedPermissions"' || fail "request: always passes Claude's suggestion"; wait
$S rules remove 'Bash(npm test:*)' >/dev/null; [ -z "$($S rules list)" ] || fail "rules remove"
answer '{"message":"use yarn instead"}'; r "$perm" | grep -q 'said: use yarn instead' || fail "request: typed reply to a permission"; wait
answer dismiss; r '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?"}]}}' | grep -q 'dismissed' || fail "request: dismiss"; wait
( for _ in $(seq 40); do f=$(ls "$d"/requests/*.json 2>/dev/null | head -1); [ -n "$f" ] && break; sleep 0.1; done
  jq -r .diff "$f" > "$d/diff"; printf deny > "${f%.json}.answer" ) &
r '{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/x/a.ts","old_string":"a\nb","new_string":"a\nB"}}' >/dev/null; wait
grep -qx -- '-b' "$d/diff" && grep -qx -- '+B' "$d/diff" || fail "request: edit diff"
[ -z "$(ls "$d/requests")" ] || fail "request: leaves nothing behind"
rm -f "$d/approvals"
echo "claude-switch hooks: ALL PASS"

# running / --quit-running: finds Claude in a terminal and in VS Code, says so after a switch, and quits them on request
mkdir -p "$d/bin" "$d/ext/anthropic.claude-code-9/resources/native-binary"
ln -s "$(command -v sleep)" "$d/bin/claude"; ln -s "$(command -v sleep)" "$d/ext/anthropic.claude-code-9/resources/native-binary/claude"
"$d/bin/claude" 30 & t1=$!; "$d/ext/anthropic.claude-code-9/resources/native-binary/claude" 30 & t2=$!
sleep 0.5
r=$($S running)
grep -qx "$t1	terminal" <<<"$r" && grep -qx "$t2	editor" <<<"$r" || fail "running: $r"
export CLAUDE_SWITCH_STORE=file; rm -f "$d/list"
login a@x orgA A1-; $S save >/dev/null; login b@x orgB B1-; $S save >/dev/null
$S a@x | grep -q "still running (1 in VS Code, 1 in a terminal) with b@x" || fail "switch: running sessions named"
$S --quit-running b@x | grep -q "Quit 2 Claude session" || fail "quit running"; on b@x B1-
kill -0 $t1 2>/dev/null || kill -0 $t2 2>/dev/null && fail "quit running: still alive"
[ -z "$($S running)" ] || fail "running: none left"
echo "claude-switch running: ALL PASS"

echo "Building the app for its selftest..."
swiftc -swift-version 5 -O -o "$tmpbin/ClaudeSwitch" "$root"/src/*.swift || fail "app did not compile"
"$tmpbin/ClaudeSwitch" --selftest; ok=$?
defaults delete ClaudeSwitch >/dev/null 2>&1  # the bare binary's own settings domain
[ $ok -eq 0 ] || fail "app selftest"
