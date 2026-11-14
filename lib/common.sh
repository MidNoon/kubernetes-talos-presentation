LAB_STATE="${LAB_STATE:-$LAB_ROOT/.lab}"
LAB_EXIT_HOOKS=()

lab_on_exit() {
  local hook
  for hook in "${LAB_EXIT_HOOKS[@]}"; do
    [[ "$hook" == "$1" ]] && return 0
  done
  LAB_EXIT_HOOKS+=("$1")
  trap lab_run_exit_hooks EXIT
}

lab_run_exit_hooks() {
  local hook
  for hook in "${LAB_EXIT_HOOKS[@]}"; do
    "$hook" || true
  done
}

log() {
  printf '%s %s\n' "$(date +%T)" "$*" >&2
}

lab_scrub() {
  local text="$1"
  if [[ -n "${LAB_SCRUB:-}" ]]; then
    text="${text//"$LAB_SCRUB"/<join-token>}"
  fi
  printf '%s' "$text"
}

fail() {
  printf 'error: %s\n' "$(lab_scrub "$*")" >&2
  return 1
}

die() {
  printf 'error: %s\n' "$(lab_scrub "$*")" >&2
  exit 1
}

lab_load_config() {
  local config="${LAB_CONFIG:-$LAB_ROOT/lab.env}" var
  [[ -r "$config" ]] || die "config not readable: $config (copy lab.env.example to lab.env)"
  source "$config"
  for var in LAB_OMNI_PROFILE LAB_OMNI_ENDPOINT; do
    [[ -n "${!var:-}" ]] || die "config $config does not set $var"
  done
  [[ "$LAB_OMNI_ENDPOINT" == https://* ]] || die "config $config has a non-https LAB_OMNI_ENDPOINT: $LAB_OMNI_ENDPOINT"
}

lab_lock() {
  mkdir -p "$LAB_STATE"
  exec 9>>"$LAB_STATE/lock"
  if ! flock -n 9; then
    die "another lab run holds $LAB_STATE/lock: $(cat "$LAB_STATE/lock")"
  fi
  : >"$LAB_STATE/lock"
  printf 'pid=%d started=%s command=%s\n' "$$" "$(date -Is)" "$*" >&9
}

lab_public_curl() {
  curl --doh-url https://cloudflare-dns.com/dns-query "$@"
}
