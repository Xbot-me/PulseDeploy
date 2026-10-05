#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && B || fail" is how these checks read
# Exercises bin/pulse-lt with a fake "php artisan" (no database, no services).   lt_case.sh <case>
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE="$1"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/api" "$T/state"
cat >"$T/fakephp" <<'EOF'
#!/usr/bin/env bash
# fake: php [-d x=y] artisan <command> ...   behaves like the CRM's load-test commands
while [[ "$1" == -d ]]; do shift 2; done
shift                                       # artisan
cmd="$1"; shift
env_of() { sed -n "s/^$1=//p" "$API_ENV" | head -n1; }
case "$cmd" in
  list)           [[ -z "${FAKE_NO_LOADTEST:-}" ]] && printf 'loadtest:seed\nloadtest:status\n' ;;
  config:cache)   echo "cached" >>"$FAKE_LOG" ;;
  loadtest:status)
    app="$(env_of APP_ENV)"; req=false; [[ "$(env_of LOADTEST_MODE)" == true ]] && req=true
    eff=false; [[ $req == true && "$app" != production ]] && eff=true
    echo "{\"env\":\"$app\",\"requested\":$req,\"effective\":$eff,\"refused_in_production\":false}" ;;
  loadtest:seed)  echo "$cmd $*" >>"$FAKE_LOG"; echo '{"status":"seeded","requested":{"orders":10},"seconds":1}' ;;
esac
EOF
chmod +x "$T/fakephp"
printf 'APP_ENV=production\nAPP_DEBUG=false\nDB_HOST=localhost\n' >"$T/api/.env"
cp "$T/api/.env" "$T/env.orig"
export PULSE_CONF=/dev/null CRM_CONF="$T/crm.conf" PULSE_LT_ALLOW_NONROOT=1 NO_COLOR=1
APP_USER="$(id -un)"
export APP_USER PHP_BIN="$T/fakephp" API_CURRENT="$T/api" API_ENV="$T/api/.env" PULSE_LT_STATE="$T/state" FAKE_LOG="$T/log"
LT="$ROOT/bin/pulse-lt"
fail=0; no() { echo "$1"; fail=1; }

case "$CASE" in
  cycle)
    "$LT" throttles off >/dev/null 2>&1 || no "throttles off failed"
    grep -q '^APP_ENV=staging' "$T/api/.env" && grep -q '^LOADTEST_MODE=true' "$T/api/.env" || no "off did not set staging + LOADTEST_MODE"
    "$LT" status 2>&1 | grep -q '"effective":true' || no "status does not show it in effect"
    "$LT" throttles off >/dev/null 2>&1 || no "a second off must not fail"
    "$LT" throttles on >/dev/null 2>&1 || no "throttles on failed"
    cmp -s "$T/env.orig" "$T/api/.env" || no ".env is not byte-identical after on"
    [[ ! -f "$T/state/env-backup" ]] || no "backup left behind"
    "$LT" throttles on >/dev/null 2>&1 || no "on with nothing to restore must succeed"
    ;;
  keeps-existing-mode)
    printf 'LOADTEST_MODE=false\n' >>"$T/api/.env"; cp "$T/api/.env" "$T/env.orig"
    "$LT" throttles off >/dev/null 2>&1; "$LT" throttles on >/dev/null 2>&1
    cmp -s "$T/env.orig" "$T/api/.env" || no "an existing LOADTEST_MODE line was not restored"
    ;;
  old-crm)
    FAKE_NO_LOADTEST=1 "$LT" throttles off >/dev/null 2>&1 && no "off must refuse a CRM without LOADTEST_MODE"
    cmp -s "$T/env.orig" "$T/api/.env" || no ".env changed although the command refused"
    ;;
  seed)
    printf 'STORE=main\n' >"$CRM_CONF"
    "$LT" seed main --yes >/dev/null 2>&1 && no "seeding the live store must be refused"
    "$LT" seed main --force --yes >/dev/null 2>&1 || no "--force must allow the installed store on a test server"
    grep -q 'loadtest:seed main .* --force' "$T/log" || no "--force not passed on to the CRM"
    : >"$T/log"
    "$LT" seed 'bad;slug' --yes >/dev/null 2>&1 && no "bad slug accepted"
    "$LT" seed lt1 --profile huge --yes >/dev/null 2>&1 && no "bad profile accepted"
    "$LT" seed lt1 --as-of tomorrow --yes >/dev/null 2>&1 && no "bad date accepted"
    "$LT" seed lt1 --profile small --seed 7 --as-of 2026-10-01 --reset --yes >/dev/null 2>&1 || no "valid seed failed"
    grep -q 'loadtest:seed lt1 --profile=small --seed=7 --json --as-of=2026-10-01 --reset --env=staging' "$T/log" || no "seed arguments wrong: $(cat "$T/log" 2>/dev/null)"
    grep -q '^APP_ENV=production' "$T/api/.env" || no "seeding must not change the server's own APP_ENV"
    ;;
  diff)
    mk() { jq -n --arg id "$1" --argjson conns "$2" --argjson p95 "$3" \
      '{id:$id, environment:{vm:{vcpu:2}, versions:{php:"8.3"}, commits:{crm_commit:"abc"}},
        config:{settings:{mysql:{max_connections:$conns}}, dataset:{seed:42}},
        server:{nginx:{"pulse-api.access.log":{p95_ms:$p95}}, cpu_io:{cpu_user_pct_avg:10, cpu_system_pct_avg:5}},
        client:{total:100, failed:0, worst_p95_ms:$p95, endpoints:[{name:"GET /x", requests:100, failures:0, p50_ms:10, p95_ms:$p95, p99_ms:90}]}}'; }
    mk a 150 300 >"$T/a.json"; mk b 300 200 >"$T/b.json"
    out="$("$LT" diff "$T/a.json" "$T/b.json" 2>&1)"
    grep -q 'config.settings.mysql.max_connections: 150 -> 300' <<<"$out" || no "changed setting not listed"
    ! grep -q 'vcpu' <<<"$out" || no "an unchanged value was listed as a difference"
    grep -q 'GET /x .*300 -> 200' <<<"$out" || no "endpoint p95 change not shown"
    "$LT" render_md >/dev/null 2>&1 && no "unknown command accepted"
    ;;
  nginx)
    # statistics only from the bytes written after the offset, per log
    mkdir -p "$T/ng"; export NGINX_LOG_DIR="$T/ng"
    printf '1.1.1.1 "GET /old HTTP/1.1" 200 5 rt=9.999 urt=1 "ua"\n' >"$T/ng/pulse-api.access.log"
    printf '1.1.1.1 "GET /other HTTP/1.1" 200 5 "no timing here"\n' >"$T/ng/pulse-shop.access.log"
    # shellcheck source=/dev/null
    source "$LT"
    trap - ERR
    offs="$(nginx_offsets_json)"
    for i in $(seq 1 100); do printf '1.1.1.1 "GET /x HTTP/1.1" %s 9 rt=0.%03d urt=0.1 "ua"\n' "$([ $((i%10)) -eq 0 ] && echo 429 || echo 200)" "$i" >>"$T/ng/pulse-api.access.log"; done
    out="$(nginx_all_json "$offs")"
    [[ "$(jq -r '."pulse-api.access.log".requests' <<<"$out")" == 100 ]] || no "requests counted from the wrong offset: $out"
    [[ "$(jq -r '."pulse-api.access.log".p50_ms' <<<"$out")" == 50 ]] || no "p50 wrong: $out"
    [[ "$(jq -r '."pulse-api.access.log".p95_ms' <<<"$out")" == 95 ]] || no "p95 wrong: $out"
    [[ "$(jq -r '."pulse-api.access.log".status["429"]' <<<"$out")" == 10 ]] || no "429 count wrong: $out"
    [[ "$(jq -r 'has("pulse-shop.access.log")' <<<"$out")" == false ]] || no "a log without timing was reported"
    ;;
  usage)
    "$LT" help 2>&1 | grep -q 'pulse-lt record start' || no "help text missing"
    "$LT" bogus >/dev/null 2>&1 && no "unknown command accepted"
    "$LT" record start 'bad id' >/dev/null 2>&1 && no "bad record id accepted"
    ;;
esac
exit "$fail"
