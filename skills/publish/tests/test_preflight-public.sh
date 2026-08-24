#!/usr/bin/env bash
# Unit tests for preflight-public.sh
set -u
PREFLIGHT=$(cd "$(dirname "$0")/.." && pwd)/preflight-public.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

newrepo() {
  local d; d=$(mktemp -d -p /tmp/claude)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo clean > "$d/readme"; git -C "$d" add readme
  git -C "$d" commit --quiet -m "initial commit"
  echo "$d"
}

echo "test_preflight-public.sh"

# 1. Clean repo passes.
d=$(newrepo)
out=$("$PREFLIGHT" "$d" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in *FINDINGS=0*) true ;; *) false ;; esac; } \
  && ok "clean repo passes with exit 0" || nope "clean repo passes with exit 0" "$out (rc=$rc)"

# 2. A file that is gitignored now but was committed earlier.
d=$(newrepo)
echo "secret-ish" > "$d/local.env"; git -C "$d" add local.env
git -C "$d" commit --quiet -m "add env"
echo "local.env" > "$d/.gitignore"; git -C "$d" add .gitignore
git -C "$d" commit --quiet -m "ignore env"
out=$("$PREFLIGHT" "$d" 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && case "$out" in *"ignored-but-committed: local.env"*) true ;; *) false ;; esac; } \
  && ok "finds a file ignored now but committed before" || nope "finds a file ignored now but committed before" "$out"

# 3. Refs outside heads/tags are listed.
d=$(newrepo)
git -C "$d" update-ref refs/archive/old "$(git -C "$d" rev-parse HEAD)"
out=$("$PREFLIGHT" "$d" 2>&1)
case "$out" in *"extra-ref: refs/archive/old"*) ok "lists refs outside the push scope" ;;
               *) nope "lists refs outside the push scope" "$out" ;; esac

# 4. Content check reads history, not just the tip — the class `git grep` misses.
d=$(newrepo)
echo "path is /Users/someone/thing" > "$d/doc.md"; git -C "$d" add doc.md
git -C "$d" commit --quiet -m "add doc"
echo "path is redacted" > "$d/doc.md"; git -C "$d" add doc.md
git -C "$d" commit --quiet -m "redact doc"
out=$("$PREFLIGHT" "$d" 2>&1)
case "$out" in *content:*) ok "finds a home path present only in history" ;;
               *) nope "finds a home path present only in history" "$out" ;; esac
[ -z "$(git -C "$d" grep -l '/Users/someone' HEAD 2>/dev/null)" ] \
  && ok "and the tip-only check would have missed it" || nope "and the tip-only check would have missed it" "grep found it at tip"

# 5. Commit message body, not just subject.
d=$(newrepo)
echo x > "$d/a"; git -C "$d" add a
git -C "$d" commit --quiet -m "english subject" -m "aber der Body enthält Umlaute"
out=$("$PREFLIGHT" "$d" 2>&1)
case "$out" in *commit-message:*) ok "scans commit bodies, not only subjects" ;;
               *) nope "scans commit bodies, not only subjects" "$out" ;; esac

# 6. Scope: content outside the push scope is not reported unless asked for.
d=$(newrepo)
side=$(mktemp -d -p /tmp/claude)
echo "leak /Users/someone/x" > "$d/side.md"; git -C "$d" add side.md
git -C "$d" commit --quiet -m "side"
sha=$(git -C "$d" rev-parse HEAD)
git -C "$d" reset --hard --quiet HEAD~1
git -C "$d" update-ref refs/archive/side "$sha"
out=$("$PREFLIGHT" "$d" 2>&1)
case "$out" in *content:*) nope "archived content is not scanned by default" "$out" ;;
               *) ok "archived content is not scanned by default" ;; esac
out=$("$PREFLIGHT" --all-refs "$d" 2>&1)
case "$out" in *content:*) ok "--all-refs does scan it" ;;
               *) nope "--all-refs does scan it" "$out" ;; esac

# 7. Project-supplied patterns are honoured.
d=$(newrepo)
echo "internal-codename-zebra" > "$d/f.txt"; git -C "$d" add f.txt
git -C "$d" commit --quiet -m "add"
out=$("$PREFLIGHT" "$d" 2>&1)
case "$out" in *content:*) nope "unknown string passes without a pattern" "$out" ;;
               *) ok "unknown string passes without a pattern" ;; esac
printf '# project patterns\ninternal-codename-[a-z]+\n' > "$d/.ticket-flow-private-patterns"
out=$("$PREFLIGHT" "$d" 2>&1)
case "$out" in *content:*) ok "picks up .ticket-flow-private-patterns" ;;
               *) nope "picks up .ticket-flow-private-patterns" "$out" ;; esac

# 8. Not a repo at all.
out=$("$PREFLIGHT" /tmp/claude 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "non-repo exits 2" || nope "non-repo exits 2" "rc=$rc"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
