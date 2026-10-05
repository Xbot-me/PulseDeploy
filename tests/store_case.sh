#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2015  # variables and stubs are read by the sourced crm.sh functions
# Runs crm.sh's step_store_json against a fake "php artisan".   store_case.sh <created|exists|refused|crash|supplied|catalog>
# Prints a result word per check; exit status 0 only when everything behaved.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE="$1"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
source "$ROOT/scripts/lib/common.sh" 2>/dev/null
source "$ROOT/scripts/lib/crm.sh"
# shellcheck source=/dev/null
for f in write_credentials step_store_json step_store; do
  source <(awk -v f="$f" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^}$/{exit}' "$ROOT/crm.sh")
done

mkdir -p "$TMPD/api"
cat >"$TMPD/fakephp" <<'EOF'
#!/usr/bin/env bash
# fake: php artisan store:provision ...
shift                                    # "artisan"
pwfile=""; args="$*"
for a in "$@"; do case "$a" in --password-file=*) pwfile="${a#*=}" ;; esac; done
echo "$args" >"$FAKE_LOG"
if [[ -n "$pwfile" ]]; then
  [[ -r "$pwfile" ]] || { echo '{"status":"error","message":"Cannot read the password file."}'; exit 1; }
  [[ "$(stat -c %a "$pwfile")" == 600 ]] || { echo '{"status":"error","message":"password file not mode 600"}'; exit 1; }
  echo "pwlen=$(wc -c <"$pwfile")" >>"$FAKE_LOG"
fi
echo "some warning on stderr containing $(cat "$pwfile" 2>/dev/null)" >&2
case "$FAKE_MODE" in
  created)  echo '{"status":"created","store_id":7,"catalog":"starter","categories":20,"products":0,"admin_email":"o@t.test","admin_password":null}' ;;
  exists)   echo '{"status":"exists","subdomain":"volt","message":"Store '"'"'volt'"'"' is already provisioned."}'; exit 2 ;;
  refused)  echo '{"status":"error","message":"The slug must be 2 to 40 characters."}'; exit 1 ;;
  crash)    echo 'PHP Fatal error: boom'; exit 255 ;;
esac
EOF
chmod +x "$TMPD/fakephp"
export FAKE_LOG="$TMPD/log" FAKE_MODE="$CASE"
[[ "$CASE" == supplied || "$CASE" == catalog ]] && export FAKE_MODE=created

CRM_API_CURRENT="$TMPD/api"
crm_as_app() { "$@"; }
APP_USER="$(id -un)"; CRM_PHP_BIN="$TMPD/fakephp"; CREDS_FILE="$TMPD/creds"
STORE=volt; STORE_NAME="Volt Gadgets"; ADMIN_EMAIL=o@t.test; SCHEME=http; ADMIN_HOST=admin.t.test
ADMIN_PASSWORD=""; CATALOG=starter; DEMO=""; VERTICAL=""
[[ "$CASE" == supplied ]] && ADMIN_PASSWORD="my-own-password-123"
[[ "$CASE" == refused || "$CASE" == crash ]] && ADMIN_PASSWORD="leaky-password-123"
[[ "$CASE" == catalog ]] && { CATALOG=demo; DEMO=avenvolt; VERTICAL=electronics; }
CD_STORE_JSON=1; CD_STORE_EXISTS_TEXT="already provisioned"
CD_STORE_ARG=(store:provision '{STORE_NAME}' '{STORE}' '--owner-email={ADMIN_EMAIL}' '--password-file={PASSWORD_FILE}' --json)
declare -A CRM_VARS=([STORE]=volt [STORE_NAME]="Volt Gadgets" [ADMIN_EMAIL]=o@t.test)

out="$(step_store 2>&1)"; rc=$?
fail=0
say() { echo "$1"; }
no_leftover() { ! ls /tmp/pulse-owner-pw.* >/dev/null 2>&1; }
case "$CASE" in
  created|supplied|catalog)
    [[ $rc -eq 0 ]] || { say "step failed rc=$rc"; fail=1; }
    [[ -f "$CREDS_FILE" && "$(stat -c %a "$CREDS_FILE")" == 600 ]] || { say "credentials file missing or not 600"; fail=1; }
    grep -q '^password: .\{12,\}' "$CREDS_FILE" || { say "no usable password in the credentials file"; fail=1; }
    [[ "$CASE" != supplied ]] || grep -q '^password: my-own-password-123$' "$CREDS_FILE" || { say "supplied password not kept"; fail=1; }
    grep -q -- '--password-file=' "$TMPD/log" && ! grep -q -- '--password=' "$TMPD/log" || { say "password not passed by file"; fail=1; }
    grep -qE 'pwlen=(20|19)$' "$TMPD/log" || [[ "$CASE" == supplied ]] || { say "generated password is not 20 characters"; fail=1; }
    grep -q -- '--catalog=' "$TMPD/log" || { say "no --catalog passed"; fail=1; }
    [[ "$CASE" != catalog ]] || { grep -q -- '--catalog=demo' "$TMPD/log" && grep -q -- '--demo=avenvolt' "$TMPD/log" && grep -q -- '--vertical=electronics' "$TMPD/log"; } || { say "catalog options not passed through"; fail=1; }
    if grep -q "$(sed -n 's/^password: //p' "$CREDS_FILE")" <<<"$out"; then say "password leaked into the output"; fail=1; fi
    ;;
  exists)
    [[ $rc -eq 0 ]] || { say "an existing store must not fail the run (rc=$rc)"; fail=1; }
    [[ ! -e "$CREDS_FILE" ]] || { say "credentials were written for an existing store"; fail=1; }
    [[ -z "$ADMIN_PASSWORD" ]] || { say "a generated password was kept for an existing store"; fail=1; }
    ;;
  refused|crash)
    [[ $rc -ne 0 ]] || { say "a refused/crashed provision must fail the run"; fail=1; }
    [[ ! -e "$CREDS_FILE" ]] || { say "credentials written after a failure"; fail=1; }
    ! grep -qF "leaky-password-123" <<<"$out" || { say "password leaked into the error output"; fail=1; }
    [[ "$CASE" != refused ]] || grep -q 'The slug must be' <<<"$out" || { say "the refusal message was not shown"; fail=1; }
    ;;
esac
no_leftover || { say "password temp file left behind"; fail=1; }
exit "$fail"
