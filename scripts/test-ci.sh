#!/usr/bin/env bash
# Tests for the shared CI and the weekly matrix: error grouping, issue sync (fake gh), cell statuses, report, workflow shape,
# the badge step. No network, no Mojo. Prints `ok`/`FAIL` per test and `PASS n/m`; exit 1 on any FAIL.
set -euo pipefail
cd "$(dirname "$0")/.."; root=$PWD
T=$root/.work/test-ci; rm -rf "$T"; mkdir -p "$T"
n=0; ok=0
t() { n=$((n+1)); if ( set -e; eval "$2" ) >"$T/last.out" 2>&1; then ok=$((ok+1)); echo "ok   $1"; else echo "FAIL $1"; sed 's/^/     /' "$T/last.out" | tail -8; fi; }
cell() {  # DIR LIB CHANNEL STATUS LOGTEXT: a fake cell
  mkdir -p "$1"; printf '%b' "$5" > "$1/$2-$3.log"; jq -n --arg l "$2" --arg c "$3" --arg s "$4" '{lib:$l,channel:$c,status:$s,error:""}' > "$1/$2-$3.json"; }
Q="'"
E1="ok 1\nFAIL build: tests/a.mojo\n/home/runner/work/x/src/dec.mojo:12:5: error: use of unknown declaration ${Q}foo${Q}\n"
E1P="ok 9\nFAIL build: tests/a.mojo\n/tmp/other/place/lib/dec.mojo:97:1: error: use of unknown declaration ${Q}foo${Q}\n"
E2="FAIL build: tests/b.mojo\n/home/runner/work/y/b.mojo:3:3: error: cannot convert String to Int\n"

# --- error line and grouping (M3)
G=$T/g3; cell "$G" lib-a stable fail "$E1"; cell "$G" lib-b stable fail "$E1P"; cell "$G" lib-c stable fail "$E2"; cell "$G" lib-d stable pass 'PASS ci\n'
t "M3 three fake logs (2 same error, 1 different) give 2 groups" '[ "$(scripts/matrix-issues.sh "$G" --groups | tail -1)" = "groups: 2" ]'
t "M3 the 2-library group lists lib-a and lib-b" 'scripts/matrix-issues.sh "$G" --groups | grep -E "lib-a stable, lib-b stable"'
N=$T/g-neg; cell "$N" lib-a stable fail "$E1"; cell "$N" lib-b stable fail "$E1P"
t "M3 negative control: identical errors with different paths and lines still group as 1" '[ "$(scripts/matrix-issues.sh "$N" --groups | tail -1)" = "groups: 1" ]'
D=$T/g-diff; cell "$D" lib-a stable fail "$E1"; cell "$D" lib-b stable fail "FAIL build: x\n/p/dec.mojo:1:1: error: use of unknown declaration ${Q}bar${Q}\n"
t "M3 control: same path, different message stays 2 groups" '[ "$(scripts/matrix-issues.sh "$D" --groups | tail -1)" = "groups: 2" ]'
t "error-line takes the error after FAIL, not an earlier expected one" 'printf "%b" "error: expected, from a passing test\nFAIL x\ny.mojo:1:1: error: real\n" > "$T/e.log"; [ "$(scripts/error-line.sh "$T/e.log" --key)" = "error: real" ]'
t "error-line on an empty log says no output" ': > "$T/empty.log"; [ "$(scripts/error-line.sh "$T/empty.log")" = "no output" ]'
t "error-line without any error: line falls back to the FAIL line" 'printf "a\nFAIL setup: uv sync\nb\n" > "$T/f.log"; [ "$(scripts/error-line.sh "$T/f.log")" = "FAIL setup: uv sync" ]'

# --- issue sync with a fake gh: state in $T/gh/issues.json, calls in $T/gh/calls
mkdir -p "$T/gh"; cat > "$T/gh/gh" <<'EOF'
#!/usr/bin/env bash
d=$(dirname "$0"); echo "$*" >> "$d/calls"
case "$1 $2" in
  "issue list") cat "$d/issues.json" ;;
  "issue create") b=$(cat "$(sed -E 's/.*--body-file ([^ ]+).*/\1/' <<<"$*")"); jq --arg b "$b" '. + [{number:(length+1),state:"OPEN",body:$b}]' "$d/issues.json" > "$d/i.tmp" && mv "$d/i.tmp" "$d/issues.json" ;;
  "issue edit") n=$3; a="$*"; b=$(cat "${a##*--body-file }"); jq --argjson n "$n" --arg b "$b" 'map(if .number==$n then .body=$b else . end)' "$d/issues.json" > "$d/i.tmp" && mv "$d/i.tmp" "$d/issues.json" ;;
  "issue close") jq --argjson n "$3" 'map(if .number==$n then .state="CLOSED" else . end)' "$d/issues.json" > "$d/i.tmp" && mv "$d/i.tmp" "$d/issues.json" ;;
  "issue reopen") jq --argjson n "$3" 'map(if .number==$n then .state="OPEN" else . end)' "$d/issues.json" > "$d/i.tmp" && mv "$d/i.tmp" "$d/issues.json" ;;
esac
EOF
chmod +x "$T/gh/gh"; echo '[]' > "$T/gh/issues.json"; export GH=$T/gh/gh
cnt() { grep -c "^issue $1" "$T/gh/calls" || true; }
t "M3 first run opens exactly 2 issues for 2 groups" 'scripts/matrix-issues.sh "$G" >/dev/null; [ "$(cnt create)" = 2 ] && [ "$(jq length "$T/gh/issues.json")" = 2 ]'
t "M3 each issue body carries a hidden marker and its libraries" 'jq -r ".[].body" "$T/gh/issues.json" | grep -c "<!-- matrix-group:" | grep -qx 2 && jq -r ".[].body" "$T/gh/issues.json" | grep -q "| lib-b | stable |"'
t "M3 second identical run creates nothing new (dedupe by marker)" ': > "$T/gh/calls"; scripts/matrix-issues.sh "$G" >/dev/null; [ "$(cnt create)" = 0 ] && [ "$(jq length "$T/gh/issues.json")" = 2 ] && [ "$(cnt edit)" = 2 ]'
H=$T/g-green; cell "$H" lib-a stable fail "$E1"; cell "$H" lib-b stable pass 'PASS ci\n'; cell "$H" lib-c stable pass 'PASS ci\n'
t "M3 a group that went green is closed, the live one stays open" ': > "$T/gh/calls"; scripts/matrix-issues.sh "$H" >/dev/null; [ "$(cnt close)" = 1 ] && [ "$(jq "[.[]|select(.state==\"OPEN\")]|length" "$T/gh/issues.json")" = 1 ]'
t "M3 a closed group that fails again is reopened, not duplicated" ': > "$T/gh/calls"; scripts/matrix-issues.sh "$G" >/dev/null; [ "$(cnt reopen)" = 1 ] && [ "$(jq length "$T/gh/issues.json")" = 2 ] && [ "$(jq "[.[]|select(.state==\"OPEN\")]|length" "$T/gh/issues.json")" = 2 ]'
t "M3 an all-green run closes everything and opens nothing" 'A=$T/g-allgreen; cell "$A" lib-a stable pass "PASS ci\n"; : > "$T/gh/calls"; scripts/matrix-issues.sh "$A" >/dev/null; [ "$(cnt create)" = 0 ] && [ "$(jq "[.[]|select(.state==\"OPEN\")]|length" "$T/gh/issues.json")" = 0 ]'
unset GH

# --- cells: pass, fail, na, timeout (fake libraries, no Mojo)
F=$T/fake; mk() { mkdir -p "$F/$1/scripts"; printf '%s\n' "$2" > "$F/$1/scripts/ci.sh"; ( cd "$F/$1" && git init -q -b main && git add . && git -c user.name=t -c user.email=t@t commit -qm x ); }
mk fake-pass '#!/usr/bin/env bash
echo "PASS ci"'
mk fake-fail '#!/usr/bin/env bash
echo "FAIL build: tests/a.mojo"; echo "/x/y/a.mojo:3:4: error: unknown declaration z"; exit 1'
mk fake-mojo '#!/usr/bin/env bash
echo "MOJO=${MOJO:-unset}"; test "${MOJO:-}" = /bin/true'
mk fake-slow '#!/usr/bin/env bash
sleep 30'
run() { MATRIX_SRC=$F/$1 NIGHTLY_MOJO=/bin/true CELL_TIMEOUT=${3:-60} scripts/matrix-cell.sh "$1" "$2" "$T/cells" >/dev/null; jq -r .status "$T/cells/$1-$2.json"; }
t "cell: passing ci.sh -> pass" '[ "$(run fake-pass stable)" = pass ]'
t "cell: failing ci.sh -> fail with the first error line" '[ "$(run fake-fail stable)" = fail ] && jq -r .error "$T/cells/fake-fail-stable.json" | grep -q "error: unknown declaration z"'
t "cell: nightly on a ci.sh without MOJO= -> na (not a silent pass)" '[ "$(run fake-pass nightly)" = na ]'
t "cell: nightly hands MOJO to ci.sh that honours it" '[ "$(run fake-mojo nightly)" = pass ]'
t "cell: stable run does not leak MOJO" '[ "$(MOJO=/bin/true run fake-mojo stable)" = fail ]'
t "cell: timeout -> fail, process killed, FAIL timeout in the log" '[ "$(run fake-slow stable 2)" = fail ] && grep -q "FAIL timeout" "$T/cells/fake-slow-stable.log"'
t "cell: unknown clone source -> fail, not a crash" '[ "$(MATRIX_SRC=$T/nope scripts/matrix-cell.sh fake-x stable "$T/cells" >/dev/null; jq -r .status "$T/cells/fake-x-stable.json")" = fail ]'
t "cell: bad channel is refused" '! scripts/matrix-cell.sh fake-pass beta "$T/cells"'

# --- report
R=$T/rep; cell "$R" mojo-a stable pass 'PASS ci\n'; cell "$R" mojo-a nightly na 'x\n'; cell "$R" mojo-b stable fail "$E1"; cell "$R" mojo-b nightly fail "$E1"
jq '.error="error: use of | pipe"' "$R/mojo-b-stable.json" > "$R/x" && mv "$R/x" "$R/mojo-b-stable.json"
printf 'mojo-a\nmojo-b\nmojo-c\n' > "$T/libs.txt"; scripts/matrix-report.sh "$R" "$T/out" "$T/libs.txt" > "$T/rep.out"
t "report: status.md has a row per library with both channels" 'grep -q "^| mojo-a | pass | na |" "$T/out/status.md" && grep -q "^| mojo-b | fail | fail |" "$T/out/status.md"'
t "report: a library with no cells is missing, never green" 'grep -q "^| mojo-c | missing | missing |" "$T/out/status.md" && jq -r .color "$T/out/shields/mojo-c.json" | grep -qx red'
t "report: a pipe in the error text cannot break the table" 'grep "^| mojo-b" "$T/out/status.md" | sed "s/\\\\|//g" | awk -F"|" "{exit NF != 6}"'
t "report: shields endpoint JSON is valid (schemaVersion, label, message, color)" 'jq -e ".schemaVersion==1 and .label==\"mojo\" and (.message|test(\"stable pass\")) and .color==\"yellowgreen\"" "$T/out/shields/mojo-a.json"'

# --- workflow shape
LC=.github/workflows/lib-ci.yml
t "lib-ci.yml: workflow_call with inputs mojo, apt, pre" 'python3 -I -c "import yaml; d=yaml.safe_load(open(\"$LC\")); i=d[True][\"workflow_call\"][\"inputs\"]; assert set(i)=={\"mojo\",\"apt\",\"pre\"}, i; assert i[\"mojo\"][\"default\"]==\"stable\""'
t "lib-ci.yml: pins the same action versions the libraries use today" 'grep -q "actions/checkout@v7" $LC && grep -q "astral-sh/setup-uv@v10.3.0" $LC'
t "lib-ci.yml: ci.sh teed to ci.log under bash (pipefail)" 'grep -A1 "scripts/ci.sh 2>&1 | tee ci.log" $LC | grep -q "shell: bash"'
t "lib-ci.yml and matrix-cell.sh install the nightly with the same command" 'a=$(grep -o "uv pip install.*mojo max" $LC | sed "s#\$RUNNER_TEMP/nightly#X#g"); b=$(grep -o "uv pip install.*mojo max" scripts/matrix-cell.sh | sed "s#\$out/nightly-venv#X#g"); [ -n "$a" ] && [ "$a" = "$b" ]'
t "lib-ci.yml badge step equals the one repo-badges wrote in a library" 'diff <(sed -n "/- name: Badge/,\$p" $LC) <(git -C "${LIBS_DIR:-$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/../.." && pwd)}/mojo-bench" show main:.github/workflows/ci.yml | sed -n "/- name: Badge/,\$p")'
t "publish-status refuses to run off GitHub (no CI env)" '! env -u CI -u GITHUB_ACTIONS GH_TOKEN=x GITHUB_REPOSITORY=a/b scripts/publish-status.sh "$T"'
if command -v pixi >/dev/null; then
  t "actionlint (pixi exec) on lib-ci.yml, template and matrix.yml" 'pixi exec actionlint $LC templates/ci.yml .github/workflows/matrix.yml'
else echo "NOT RUN: actionlint, pixi missing"; fi

# --- callers
t "ci-adopt: bare caller for a plain library is 3 job lines calling lib-ci.yml@v1" 'scripts/ci-adopt.sh mojo-json-public "$T/ad1" && [ "$(sed -n "/^jobs:/,\$p" "$T/ad1/.github/workflows/ci.yml" | wc -l)" = 3 ] && grep -q "uses: amarbaro/mojo-libs/.github/workflows/lib-ci.yml@v1" "$T/ad1/.github/workflows/ci.yml"'
t "ci-adopt: imkit gets apt, uregex gets pre, both valid YAML" 'scripts/ci-adopt.sh mojo-imkit-public "$T/ad2" && scripts/ci-adopt.sh mojo-uregex-public "$T/ad3" && python3 -I -c "import yaml; a=yaml.safe_load(open(\"$T/ad2/.github/workflows/ci.yml\")); b=yaml.safe_load(open(\"$T/ad3/.github/workflows/ci.yml\")); assert a[\"jobs\"][\"ci\"][\"with\"][\"apt\"]==\"fonts-dejavu-core libfreetype6\"; assert b[\"jobs\"][\"ci\"][\"with\"][\"pre\"].startswith(\"uv sync\")"'

# --- matrix-cell: a ci-setup.tsv row with an empty apt column still runs its pre command (tab collapsed in `read`)
t "matrix-cell: empty apt column, pre command runs before ci.sh" 'R=$T/mc; rm -rf "$R"; mkdir -p "$R/s/fakelib/scripts"; cp -r scripts "$R/scripts"; printf "fakelib\t\ttouch pre-ran\n" > "$R/ci-setup.tsv"
  printf "#!/usr/bin/env bash\ntest -f pre-ran || { echo \"FAIL setup: pre did not run\"; exit 1; }\necho \"PASS ci\"\n" > "$R/s/fakelib/scripts/ci.sh"
  git -C "$R/s/fakelib" init -q && git -C "$R/s/fakelib" add -A && git -C "$R/s/fakelib" -c user.name=t -c user.email=t@t commit -q -m x
  MATRIX_SRC=$R/s/fakelib "$R/scripts/matrix-cell.sh" fakelib stable "$R/out" && [ "$(jq -r .status "$R/out/fakelib-stable.json")" = pass ]'

# --- the badge step, run for real against a local bare repo instead of github.com
badge() {  # CILOG -> prints the checks.json message pushed to the badges branch
  rm -rf "$T/bd"; mkdir -p "$T/bd/remote.git" "$T/bd/w"; git init -q --bare "$T/bd/remote.git"
  python3 -I - "$LC" "$T/bd/remote.git" > "$T/bd/step.sh" <<'PY'
import sys, yaml
steps = next(iter(yaml.safe_load(open(sys.argv[1]))["jobs"].values()))["steps"]
run = next(s["run"] for s in steps if s.get("name") == "Badge")
import re
print(re.sub(r'"https://x-access-token:[^"]*"', '"' + sys.argv[2] + '"', run))
PY
  cp "$1" "$T/bd/w/ci.log"; ( cd "$T/bd/w" && bash -e "$T/bd/step.sh" ); git -C "$T/bd/remote.git" show badges:checks.json | jq -r '"\(.message) \(.color)"'; }
t "badge: PASS 6/6 -> 6/6 brightgreen" 'printf "x\nPASS 6/6\nPASS ci\n" > "$T/c1.log"; [ "$(badge "$T/c1.log")" = "6/6 brightgreen" ]'
t "badge: FAIL 2/6 -> 4/6 red" 'printf "x\nFAIL 2/6\n" > "$T/c2.log"; [ "$(badge "$T/c2.log")" = "4/6 red" ]'
t "badge: no summary line, counts ok / FAIL lines" 'printf "ok a\nok b\nFAIL c\n" > "$T/c3.log"; [ "$(badge "$T/c3.log")" = "2/3 red" ]'

echo "PASS $ok/$n"
[ "$ok" = "$n" ] || { echo "FAIL test-ci: $((n-ok)) of $n failed"; exit 1; }
