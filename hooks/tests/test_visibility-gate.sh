#!/usr/bin/env bash
# Unit tests for visibility-gate.sh
set -u
GATE=$(cd "$(dirname "$0")/.." && pwd)/visibility-gate.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

# Runs $2 in a repo configured for visibility $1 ("" = leave unset,
# "no-remote" = no remote at all). Echoes "<rc>|<stdout>".
run_in() {
  local vis="$1" cmd="$2" d
  d=$(mktemp -d -p /tmp/claude)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  [ "$vis" = "no-remote" ] || git -C "$d" remote add origin https://github.com/x/y.git
  case "$vis" in public|private|local) git -C "$d" config ticket-flow.visibility "$vis" ;; esac
  local out rc
  out=$( cd "$d" && printf '{"tool_input":{"command":"%s"}}' "$cmd" | "$GATE" 2>/dev/null )
  rc=$?
  echo "$rc|$out"
}

expect_rc() {  # <label> <vis> <cmd> <want-rc>
  local r; r=$(run_in "$2" "$3")
  [ "${r%%|*}" = "$4" ] && ok "$1" || nope "$1" "got rc=${r%%|*}, want $4"
}

echo "test_visibility-gate.sh"

# Commands that create the public state: refused regardless of context.
expect_rc "gh repo create --public is refused"            no-remote "gh repo create me/x --public --source . --push" 2
expect_rc "…even in a repo marked private"                private   "gh repo create me/x --public" 2
expect_rc "gh repo create --private passes"               no-remote "gh repo create me/x --private --source ." 0
expect_rc "gh repo edit --visibility public is refused"   private   "gh repo edit me/x --visibility public" 2
expect_rc "…also in the --visibility=public spelling"     private   "gh repo edit me/x --visibility=public" 2
expect_rc "gh repo edit --visibility private passes"      private   "gh repo edit me/x --visibility private" 0

# Ref-carrying pushes: judged by destination, not by host.
expect_rc "push --tags refused when public"               public    "git push --tags" 2
expect_rc "push --tags allowed when private"              private   "git push --tags" 0
expect_rc "push --tags allowed without a remote"          no-remote "git push --tags" 0
expect_rc "push --mirror refused when public"             public    "git push --mirror origin" 2
expect_rc "explicit refspec refused when public"          public    "git push origin refs/archive/x:refs/archive/x" 2
expect_rc "bd dolt push refused when public"              public    "bd dolt push" 2
expect_rc "bd dolt push allowed when private"             private   "bd dolt push" 0

# Unknown visibility escalates instead of guessing either way.
r=$(run_in "" "git push --tags")
{ [ "${r%%|*}" = "0" ] && case "${r#*|}" in *'"permissionDecision": "ask"'*) true ;; *) false ;; esac; } \
  && ok "unknown visibility asks the user" || nope "unknown visibility asks the user" "$r"

# Ordinary commands are untouched.
expect_rc "plain push of the current branch passes"       public    "git push origin main" 0
expect_rc "unrelated command passes"                      public    "ls -la" 0

# The deliberate override, used by /ticket-flow:publish after the user says yes.
expect_rc "explicit override passes"                      private   "TICKET_FLOW_VISIBILITY_OK=1 gh repo edit me/x --visibility public" 0
expect_rc "…and it is not implied by anything else"       private   "gh repo edit me/x --visibility public" 2

# Fail closed on unparseable input.
out=$(echo 'not json at all' | "$GATE" 2>/dev/null); rc=$?
[ "$rc" -eq 2 ] && ok "unparseable input fails closed" || nope "unparseable input fails closed" "rc=$rc"

# Empty command is not an error.
out=$(printf '{"tool_input":{}}' | "$GATE" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "missing command passes" || nope "missing command passes" "rc=$rc"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
