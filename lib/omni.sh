omni_assert_allowed() {
  case "${1:-} ${2:-}" in
    "get "*)
      return 0
      ;;
    "jointoken create")
      [[ "${3:-}" == "$LAB_JOIN_TOKEN_NAME" ]] && return 0
      ;;
    "jointoken revoke" | "jointoken delete")
      [[ -n "${3:-}" ]] && return 0
      ;;
    "media preset")
      [[ "${3:-}" =~ ^(create|delete)$ && "${4:-}" == "$LAB_PRESET_NAME" ]] && return 0
      ;;
    "media download")
      [[ "${3:-}" == "$LAB_PRESET_NAME" ]] && return 0
      ;;
    "cluster template")
      [[ "${3:-}" =~ ^(validate|sync|status)$ && "${4:-}" == -f && "${5:-}" == "$(lab_cluster_template)" ]] && return 0
      ;;
    "cluster delete")
      [[ "${3:-}" == "$LAB_CLUSTER_NAME" ]] && return 0
      ;;
    "delete link")
      cap_is_lab_id "${3:-}" && return 0
      ;;
    "kubeconfig "*)
      [[ "${3:-}" == --cluster && "${4:-}" == "$LAB_CLUSTER_NAME" ]] && return 0
      ;;
  esac
  printf 'error: refusing Omni call outside the lab allowlist: omnictl %s\n' "$(lab_scrub "$*")" >&2
  return 1
}

omni_run() {
  (
    local profile_env
    omni_assert_allowed "$@" || exit 1
    profile_env="$(CLUSTERCTLS_NO_UPDATE_CHECK=1 clusterctls profile env "$LAB_OMNI_PROFILE")" || {
      printf 'error: clusterctls could not load profile %s\n' "$LAB_OMNI_PROFILE" >&2
      exit 1
    }
    eval "$profile_env" || {
      printf 'error: could not apply environment of profile %s\n' "$LAB_OMNI_PROFILE" >&2
      exit 1
    }
    if [[ -z "${LAB_OMNI_ENDPOINT:-}" || "${OMNI_ENDPOINT:-}" != "$LAB_OMNI_ENDPOINT" ]]; then
      printf 'error: refusing Omni call: profile %s has endpoint "%s", expected "%s"\n' \
        "$LAB_OMNI_PROFILE" "${OMNI_ENDPOINT:-}" "${LAB_OMNI_ENDPOINT:-}" >&2
      exit 1
    fi
    exec timeout "${LAB_OMNI_TIMEOUT:-120}" omnictl "$@"
  )
}

omni_query() {
  local stderr_file output status=0 message
  stderr_file="$(mktemp)" || return 1
  output="$(omni_run "$@" 2>"$stderr_file")" || status=$?
  if ((status != 0)); then
    message="$(grep -v '^\[WARN\] omnictl version' "$stderr_file" || true)"
    rm -f "$stderr_file"
    if ((status == 124)); then
      fail "omnictl $* timed out after ${LAB_OMNI_TIMEOUT:-120}s: $message"
    else
      fail "omnictl $* exited $status: $message"
    fi
    return 1
  fi
  rm -f "$stderr_file"
  printf '%s\n' "$output"
}
