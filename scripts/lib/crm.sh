#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - helpers for crm.sh (pull, build, deploy a CRM + storefront)
# =============================================================================
# shellcheck disable=SC2034  # variables here are consumed by crm.sh
# shellcheck disable=SC2016  # the bash -c scripts are single-quoted on purpose: they run as the app user
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CRM_WORK="${CRM_WORK:-/var/lib/pulsedeploy}"
CRM_ASKPASS="${CRM_ASKPASS:-/usr/local/lib/pulsedeploy-git-askpass}"
declare -A CRM_VARS=()

# ── definitions (parsed, never executed) ──────────────────────────────────────
# registry_load <file> <prefix> "<scalar keys>" "<list keys>"
# "KEY=value" sets ${prefix}_KEY; "KEY+=value" appends to the array ${prefix}_KEY.
registry_load() {
  local file="$1" prefix="$2" scalars=" $3 " lists=" $4 " line key op val ln=0 k
  [[ -f "$file" ]] || error "Definition not found: $file"
  for k in $3; do printf -v "${prefix}_${k}" '%s' ""; done
  for k in $4; do declare -ga "${prefix}_${k}=()"; done
  while IFS= read -r line || [[ -n "$line" ]]; do
    ln=$((ln + 1))
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then continue; fi
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)(\+?)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; op="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
    else
      error "$file:$ln: cannot parse line (expected KEY=value or KEY+=value)"
    fi
    if [[ "$op" == "+" ]]; then
      [[ "$lists" == *" $key "* ]] || error "$file:$ln: '$key' is not a list key (use '=' instead of '+=')"
      declare -n _pd_list="${prefix}_${key}"
      _pd_list+=("$val")
      unset -n _pd_list
    else
      [[ "$scalars" == *" $key "* ]] || error "$file:$ln: unknown key '$key'"
      printf -v "${prefix}_${key}" '%s' "$val"
    fi
  done <"$file"
}

# Fill {PLACEHOLDERS} from CRM_VARS; a leftover placeholder is a typo, so fail.
crm_expand() {
  local s="$1" k
  shopt -u patsub_replacement 2>/dev/null || true
  for k in "${!CRM_VARS[@]}"; do
    s="${s//\{$k\}/${CRM_VARS[$k]}}"
  done
  if [[ "$s" =~ \{([A-Z_]+)\} ]]; then
    error "Unknown placeholder {${BASH_REMATCH[1]}} in '$1'"
  fi
  printf '%s' "$s"
}

# ── users and processes ───────────────────────────────────────────────────────
# Run a command as the app user with a proper HOME (runuser -u keeps root's).
crm_as_app() {
  local home
  home="$(getent passwd "$APP_USER" | cut -d: -f6)"
  # cd / first: the caller's directory (often /root) is not readable by the app user
  (cd / && runuser -u "$APP_USER" -- env HOME="$home" PATH="$PATH" "${CRM_RUN_ENV[@]}" "$@")
}
CRM_RUN_ENV=()

# ── git ───────────────────────────────────────────────────────────────────────
# Authentication for private repositories. The token is passed through the
# environment to a tiny askpass helper, so it never appears in a command line.
crm_git_setup() {
  # HTTP/1.1: GitHub over HTTP/2 can drop a long fetch on NAT/VM networks ("curl 92 stream not closed cleanly")
  CRM_RUN_ENV=(GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1)
  if [[ -n "${CRM_GIT_TOKEN:-}" ]]; then
    local askpass="$CRM_ASKPASS"
    if [[ $EUID -ne 0 ]]; then askpass="$(mktemp)"; else install -d -m 755 "$(dirname "$askpass")"; fi
    cat >"$askpass" <<'ASKPASS'
#!/bin/sh
# Answers git's credential prompts from the environment (no secret stored here)
case "$1" in
  *sername*) echo "x-access-token" ;;
  *) printf '%s' "$PULSE_GIT_TOKEN" ;;
esac
ASKPASS
    chmod 755 "$askpass"
    CRM_RUN_ENV+=("GIT_ASKPASS=$askpass" "PULSE_GIT_TOKEN=$CRM_GIT_TOKEN")
  fi
  if [[ -n "${CRM_GIT_SSH_KEY_EFFECTIVE:-}" ]]; then
    CRM_RUN_ENV+=("GIT_SSH_COMMAND=ssh -i ${CRM_GIT_SSH_KEY_EFFECTIVE} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new")
  fi
  return 0
}

# Fail early (before any server change) if a repository or ref is unreachable.
# The message says which of the two it is, and lists the branches that exist.
crm_git_check() { # crm_git_check <url> <ref> <label>
  local url="$1" ref="$2" label="$3" heads="" rc=0
  env "${CRM_RUN_ENV[@]}" git ls-remote --exit-code "$url" "$ref" &>/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    log "$label reachable: $url @ $ref"
    return 0
  fi
  if ! heads="$(env "${CRM_RUN_ENV[@]}" git ls-remote --heads "$url" 2>&1)"; then
    error "Cannot reach $label ($url). Check the URL; for private repositories pass --git-token-file or --git-ssh-key.
${heads##*$'\n'}"
  fi
  # Reachable. A commit SHA is not listed by ls-remote, so accept it as is.
  if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
    log "$label reachable: $url @ $ref"
    return 0
  fi
  local names
  names="$(printf '%s\n' "$heads" | sed -n 's#.*refs/heads/##p' | head -n 8 | tr '\n' ' ')"
  error "$label is reachable but has no branch or tag '$ref'. Branches: ${names:-none}. Use --crm-ref / --storefront-ref."
}

# Shallow checkout of a branch, tag or commit into <dest>, as the app user.
# A dropped connection mid-download is retried from a clean directory.
crm_clone_once() { # crm_clone_once <url> <ref> <dest>
  local url="$1" ref="$2" dest="$3"
  rm -rf -- "${dest:?}"
  install -d -o "$APP_USER" -g "$APP_USER" "$dest"
  crm_as_app bash -c '
    set -e
    cd "$1"
    git init -q
    git remote add origin "$2"
    git fetch -q --depth 1 origin "$3"
    git checkout -q FETCH_HEAD
  ' _ "$dest" "$url" "$ref"
}

crm_clone() { # crm_clone <url> <ref> <dest>
  local dest="$3"
  [[ "$dest" == "$CRM_WORK"/* ]] || error "refusing to use $dest outside $CRM_WORK"
  retry 3 5 crm_clone_once "$1" "$2" "$3" ||
    error "Could not download $1 @ $2 after 3 attempts. Check the network, then re-run (nothing else was changed)."
}

# crm_state_put <KEY> <value>: set one line of the remembered configuration
crm_state_put() {
  local f=/etc/pulsedeploy/crm.conf
  [[ -f "$f" && -n "$2" ]] || return 0
  if grep -q "^$1=" "$f"; then sed -i "s|^$1=.*|$1=$2|" "$f"; else printf '%s=%s\n' "$1" "$2" >>"$f"; fi
}

# ── Next.js ───────────────────────────────────────────────────────────────────
# A JS/TS config without its comments, so "output: 'standalone'" mentioned in a
# comment is not mistaken for a real setting. perl handles block comments; the
# sed fallback removes single-line ones.
crm_strip_js_comments() { # crm_strip_js_comments <file>
  if command -v perl &>/dev/null; then
    perl -0777 -pe 's{/\*.*?\*/}{}gs; s{(?<![:"\x27])//[^\n]*}{}g' "$1"
  else
    sed -E 's:/\*[^*]*\*+([^/*][^*]*\*+)*/::g; s:(^|[^:"'"'"'])//.*$:\1:' "$1"
  fi
}

# The server runs the standalone build, so make sure the config asks for it.
crm_ensure_standalone() { # crm_ensure_standalone <dir>
  local dir="$1" cfg="" f
  for f in next.config.ts next.config.mjs next.config.js next.config.cjs; do
    if [[ -f "$dir/$f" ]]; then cfg="$dir/$f"; break; fi
  done
  [[ -n "$cfg" ]] || error "No next.config.* in $dir: is this a Next.js app?"
  local code
  code="$(crm_strip_js_comments "$cfg")"
  if grep -qE "output[[:space:]]*:[[:space:]]*['\"]standalone['\"]" <<<"$code"; then return 0; fi
  if grep -qE "(^|[{,[:space:]])output[[:space:]]*:" <<<"$code"; then
    error "$cfg sets a different 'output' mode; the server needs output: \"standalone\"."
  fi
  if grep -qE "(const|let|var)[[:space:]]+[A-Za-z_]+[^=]*=[[:space:]]*\{" "$cfg"; then
    sed -i -E '0,/(const|let|var)[[:space:]]+[A-Za-z_]+[^=]*=[[:space:]]*\{/s//&\n  output: "standalone",/' "$cfg"
  elif grep -qE "module\.exports[[:space:]]*=[[:space:]]*\{" "$cfg"; then
    sed -i -E '0,/module\.exports[[:space:]]*=[[:space:]]*\{/s//&\n  output: "standalone",/' "$cfg"
  elif grep -qE "export default[[:space:]]*\{" "$cfg"; then
    sed -i -E '0,/export default[[:space:]]*\{/s//&\n  output: "standalone",/' "$cfg"
  else
    error "Cannot enable standalone output automatically in $cfg. Add  output: \"standalone\"  to its config and use --crm-ref/--storefront-ref for that commit."
  fi
  if [[ $EUID -eq 0 ]]; then chown "$APP_USER:$APP_USER" "$cfg"; fi
  info "Enabled output: \"standalone\" in $(basename "$cfg")" >&2
}

# Build a Next.js app and package the standalone output. Prints the artifact path.
crm_build_next() { # crm_build_next <src> <name> <build-cmd> [KEY=value...]
  local src="$1" name="$2" cmd="$3"
  shift 3
  local ram heap art="$CRM_WORK/artifacts/$name.tar.gz"
  crm_ensure_standalone "$src"
  ram="$(total_ram_mb)"
  heap=$((ram * 70 / 100))
  ((heap > 4096)) && heap=4096
  ((heap < 1024)) && heap=1024
  install -d -o "$APP_USER" -g "$APP_USER" "$CRM_WORK/artifacts"
  info "Building $name (Node heap ${heap}MB)..." >&2
  crm_as_app env NEXT_TELEMETRY_DISABLED=1 CI=1 "NODE_OPTIONS=--max-old-space-size=${heap}" "$@" \
    bash -c 'cd "$1" && eval "$2"' _ "$src" "$cmd" >&2

  local sdir="$src/.next/standalone"
  [[ -d "$sdir" ]] || error "$name: the build produced no .next/standalone (is output: \"standalone\" active?)"
  [[ -f "$sdir/server.js" ]] ||
    error "$name: server.js is not at the top of .next/standalone (monorepo layout). Build from the app's own folder (--storefront-dir) or set outputFileTracingRoot."
  crm_as_app bash -c '
    set -e
    src="$1"; sdir="$2"; art="$3"
    mkdir -p "$sdir/.next"
    rm -rf "$sdir/.next/static"
    [ -d "$src/.next/static" ] && cp -r "$src/.next/static" "$sdir/.next/static"
    if [ -d "$src/public" ]; then rm -rf "$sdir/public"; cp -r "$src/public" "$sdir/public"; fi
    tar -czf "$art" -C "$sdir" .
  ' _ "$src" "$sdir" "$art"
  printf '%s' "$art"
}

crm_build_backend() { # crm_build_backend <src>; prints the artifact path
  local src="$1" art="$CRM_WORK/artifacts/api.tar.gz"
  command -v composer &>/dev/null || error "composer is not installed."
  install -d -o "$APP_USER" -g "$APP_USER" "$CRM_WORK/artifacts"
  [[ -f "$src/artisan" ]] || error "$src is not a Laravel app (no artisan)."
  info "Installing PHP dependencies (composer)..." >&2
  crm_as_app bash -c 'cd "$1" && composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction --no-progress' _ "$src" >&2
  crm_as_app bash -c '
    set -e
    cd "$1"
    tar --exclude=.git --exclude=node_modules --exclude=tests --exclude=.env \
        --exclude="storage/logs/*" --exclude=server.log --exclude=server.err \
        -czf "$2" .
  ' _ "$src" "$art"
  printf '%s' "$art"
}

# ── environment files ─────────────────────────────────────────────────────────
# crm_env_put <file> <KEY> <value> [overwrite]   keeps an existing value unless asked
crm_env_put() {
  local file="$1" key="$2" val="$3" mode="${4:-keep}" q
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || error "Invalid environment variable name '$key'"
  q="$val"
  if [[ "$val" =~ [[:space:]\#\"\'\\] ]]; then
    q="${val//\\/\\\\}"; q="${q//\"/\\\"}"; q="\"${q}\""
  fi
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    [[ "$mode" == "overwrite" ]] || return 0
    conf_set "$file" "$key" "$q" "="
  else
    printf '%s=%s\n' "$key" "$q" >>"$file"
  fi
}

# crm_env_apply <file> <overwrite|keep> <entries...>   entries are KEY=value templates
crm_env_apply() {
  local file="$1" mode="$2" entry key val
  shift 2
  [[ -f "$file" ]] || { install -m 640 -o "$APP_USER" -g "$APP_USER" /dev/null "$file"; }
  for entry in "$@"; do
    entry="$(crm_expand "$entry")"
    [[ "$entry" == *=* ]] || error "Bad environment entry '$entry' (expected KEY=value)"
    key="${entry%%=*}"; val="${entry#*=}"
    crm_env_put "$file" "$key" "$val" "$mode"
  done
  chown "$APP_USER:$APP_USER" "$file"
}

# ── first store ───────────────────────────────────────────────────────────────
# crm_store_create <php-bin> <exists-text> <args...>   returns 0 when created or already present
crm_store_create() {
  local php="$1" exists_text="$2" out rc=0
  shift 2
  out="$(crm_as_app bash -c 'cd /var/www/api/current && exec "$0" artisan "$@"' "$php" "$@" 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then return 0; fi
  if [[ -n "$exists_text" && "$out" == *"$exists_text"* ]]; then return 2; fi
  if [[ -n "${CRM_VARS[ADMIN_PASSWORD]:-}" ]]; then
    out="${out//"${CRM_VARS[ADMIN_PASSWORD]}"/***}" # never leak the password
  fi
  printf '%s\n' "$out" | tail -n 8 >&2
  return 1
}

# crm_artisan_json <php-bin> <artisan args...>
# Runs artisan in the API release as the app user and keeps the two streams apart:
# stdout (one JSON object) -> CRM_JSON_OUT, stderr -> CRM_JSON_ERR. Returns artisan's exit status.
CRM_JSON_OUT=""; CRM_JSON_ERR=""
crm_artisan_json() {
  local php="$1" errf rc=0
  shift
  errf="$(mktemp /tmp/pulse-artisan-err.XXXXXX)"; chmod 666 "$errf"
  CRM_JSON_OUT="$(crm_as_app env CRM_API_CURRENT="${CRM_API_CURRENT:-/var/www/api/current}" bash -c 'cd "$CRM_API_CURRENT" && errf="$1" && bin="$2" && shift 2 && exec "$bin" artisan "$@" 2>>"$errf"' _ "$errf" "$php" "$@")" || rc=$?
  CRM_JSON_ERR="$(cat "$errf" 2>/dev/null || true)"
  rm -f -- "$errf"
  # the owner password must never reach a log, even in an error text
  if [[ -n "${CRM_VARS[ADMIN_PASSWORD]:-}" ]]; then CRM_JSON_ERR="${CRM_JSON_ERR//"${CRM_VARS[ADMIN_PASSWORD]}"/***}"; fi
  return "$rc"
}

# ── smoke tests ───────────────────────────────────────────────────────────────
crm_http_code() { # crm_http_code <host> <path> [curl args...]
  local host="$1" path="$2"
  shift 2
  curl -s -o /dev/null -m 20 -w '%{http_code}' -H "Host: ${host}" "$@" "${CRM_LOCAL_URL:-http://127.0.0.1}${path}" 2>/dev/null || printf '000'
}

# ── remembered configuration (for `update`) ───────────────────────────────────
CRM_STATE_SCALARS="CRM_ID CRM_REPO CRM_REF STORE STORE_NAME DOMAIN SCHEME API_HOST ADMIN_HOST SHOP_HOST STOREFRONT STOREFRONT_REPO STOREFRONT_REF STOREFRONT_DIR STOREFRONT_BUILD_CMD APP_USER CRM_COMMIT PULSEDEPLOY_COMMIT"
CRM_STATE_LISTS="STOREFRONT_BUILD_ENV STOREFRONT_RUNTIME_ENV"
