#!/usr/bin/env bash
# Executable security and snapshot tests for the FrogPile workbook fetch command.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FETCH="$ROOT/bin/fm-frogpile-workbook-fetch.py"
TMP_ROOT=$(fm_test_tmproot fm-frogpile-workbook-fetch)
HOME_FIXTURE="$TMP_ROOT/home"
mkdir -p "$HOME_FIXTURE/config" "$TMP_ROOT/fakebin"
printf '%s\n' 'https://example.invalid/workbook/exec' > "$HOME_FIXTURE/config/frogpile-workbook.url"
SECRET='fixture-secret-7Q!'
printf '%s' "$SECRET" > "$HOME_FIXTURE/config/frogpile-workbook.key"
chmod 0600 "$HOME_FIXTURE/config/frogpile-workbook.key"

cat > "$TMP_ROOT/fakebin/curl" <<'PY'
#!/usr/bin/env python3
import os
import sys
from pathlib import Path
from urllib.parse import parse_qs, quote

args = sys.argv[1:]
key_option = args[args.index('--data-urlencode') + 1]
assert key_option.startswith('key@/dev/fd/')
key = Path(key_option[4:]).read_bytes().decode('utf-8')
assert key == os.environ['TEST_SECRET']
assert quote(key, safe='') in 'key=' + quote(key, safe='')
assert all(key not in arg for arg in args)
assert args[args.index('--proto-redir') + 1] == '=https'
assert args[args.index('--proto') + 1] == '=https'
assert parse_qs('key=' + quote(key, safe=''))['key'] == [key]
Path(os.environ['TEST_MARKER']).write_text('query-key-received\n')
output = Path(args[args.index('--output') + 1])
mode = os.environ.get('TEST_MODE', 'success')
if mode == 'error':
    output.write_text('failed response may echo ' + key)
    sys.exit(22)
if mode == 'redirect':
    output.write_text('redirect rejected ' + key)
    sys.exit(47)
if mode == 'empty':
    sys.stdout.write('text/csv')
    sys.exit(0)
output.write_bytes(b'row,value\n1,ok\n')
sys.stdout.write('text/csv')
PY
chmod 0755 "$TMP_ROOT/fakebin/curl"
export PATH="$TMP_ROOT/fakebin:$PATH" TEST_SECRET="$SECRET" TEST_MARKER="$TMP_ROOT/marker"

FM_HOME="$HOME_FIXTURE" "$FETCH" --check > "$TMP_ROOT/check.out" 2> "$TMP_ROOT/check.err"
test -s "$TMP_ROOT/check.out" || fail 'readiness check did not report ready'
test ! -e "$TMP_ROOT/marker" || fail 'readiness check fetched data'

FM_HOME="$HOME_FIXTURE" "$FETCH" > "$TMP_ROOT/receipt" 2> "$TMP_ROOT/err"
test -s "$TMP_ROOT/marker" || fail 'curl stub did not receive the query key'
test ! -s "$TMP_ROOT/err" || fail 'success printed stderr'
snapshot=$(sed -n 's/^snapshot=\([^ ]*\) .*/\1/p' "$TMP_ROOT/receipt")
test -s "$snapshot" || fail 'success did not preserve nonempty bytes'
test "$(stat -c '%a' "$snapshot")" = 600 || fail 'snapshot is not private'
metadata="${snapshot%.raw}.json"
python3 - "$metadata" <<'PY' || fail 'metadata is incomplete'
import json
import sys
record = json.load(open(sys.argv[1], encoding='utf-8'))
assert record['byte_count'] == 15
assert record['response_type'] == 'text/csv'
assert record['validation_status'] == 'unvalidated'
assert len(record['sha256']) == 64
assert len(record['source_identity']) == 64
PY

for mode in error redirect empty; do
  if TEST_MODE="$mode" FM_HOME="$HOME_FIXTURE" "$FETCH" > "$TMP_ROOT/$mode.out" 2> "$TMP_ROOT/$mode.err"; then
    fail "$mode response succeeded"
  fi
  test -s "$snapshot" || fail "$mode removed previous snapshot"
  test "$(find "$HOME_FIXTURE/data/frogpile-workbook" -type f | wc -l)" -eq 2 || fail "$mode left a failed artifact"
done

for mode in 0644 0660; do
  chmod "$mode" "$HOME_FIXTURE/config/frogpile-workbook.key"
  if FM_HOME="$HOME_FIXTURE" "$FETCH" --check > "$TMP_ROOT/unsafe.out" 2> "$TMP_ROOT/unsafe.err"; then
    fail "unsafe key mode $mode accepted"
  fi
done
chmod 0600 "$HOME_FIXTURE/config/frogpile-workbook.key"
printf '%s\n%s' "$SECRET" 'second-line' > "$HOME_FIXTURE/config/frogpile-workbook.key"
if FM_HOME="$HOME_FIXTURE" "$FETCH" --check > "$TMP_ROOT/multiline.out" 2> "$TMP_ROOT/multiline.err"; then
  fail 'multiline key accepted'
fi
printf '%s' "$SECRET" > "$HOME_FIXTURE/config/frogpile-workbook.key"
mv "$HOME_FIXTURE/config/frogpile-workbook.key" "$TMP_ROOT/key-real"
ln -s "$TMP_ROOT/key-real" "$HOME_FIXTURE/config/frogpile-workbook.key"
if FM_HOME="$HOME_FIXTURE" "$FETCH" --check > "$TMP_ROOT/symlink.out" 2> "$TMP_ROOT/symlink.err"; then
  fail 'symlink key accepted'
fi
rm "$HOME_FIXTURE/config/frogpile-workbook.key"
mv "$TMP_ROOT/key-real" "$HOME_FIXTURE/config/frogpile-workbook.key"
printf '%s\n' 'https://example.invalid/exec?key=already-set' > "$HOME_FIXTURE/config/frogpile-workbook.url"
if FM_HOME="$HOME_FIXTURE" "$FETCH" --check > "$TMP_ROOT/url.out" 2> "$TMP_ROOT/url.err"; then
  fail 'URL containing key parameter accepted'
fi
printf '%s\n' 'https://user:password@example.invalid/exec' > "$HOME_FIXTURE/config/frogpile-workbook.url"
if FM_HOME="$HOME_FIXTURE" "$FETCH" --check > "$TMP_ROOT/credentials.out" 2> "$TMP_ROOT/credentials.err"; then
  fail 'URL containing credentials accepted'
fi

if grep -R -F -- "$SECRET" "$HOME_FIXTURE/data" "$TMP_ROOT"/*.out "$TMP_ROOT"/*.err "$TMP_ROOT/receipt"; then
  fail 'key leaked into output, metadata, or failure artifacts'
fi
pass 'private workbook fetch behavior'
