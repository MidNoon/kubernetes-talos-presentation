readonly TUNNEL_PUBLIC_TIMEOUT=420

LAB_TUNNEL_NAME=""
LAB_TUNNEL_HOSTNAME=""
CF_LAB_TUNNEL_ID=""
CF_LAB_DNS_RECORD_ID=""
CF_LAB_DNS_RECORD_CONTENT=""

cf_tunnel_name_owned() {
  [[ "$1" == talos-lab-host || "$1" =~ ^talos-student-[0-9]{2}$ ]]
}

cf_hostname_owned() {
  [[ "$1" =~ ^((team|omni|kube)[0-9]{2}|auth|pve)\. && "${1#*.}" == "$LAB_TUNNEL_ZONE" ]]
}

cf_assert_allowed() {
  case "${1:-} ${2:-} ${3:-}" in
    "tunnels list "*)
      return 0
      ;;
    "tunnels create --name")
      cf_tunnel_name_owned "${4:-}" && [[ "${4:-}" == "$LAB_TUNNEL_NAME" && "${5:-}" == --config-source && "${6:-}" == cloudflare ]] && return 0
      ;;
    "tunnels token get" | "tunnels config update" | "tunnels connections cleanup" | "tunnels connections list")
      [[ -n "$CF_LAB_TUNNEL_ID" && "${4:-}" == "$CF_LAB_TUNNEL_ID" ]] && return 0
      ;;
    "tunnels delete "*)
      [[ -n "$CF_LAB_TUNNEL_ID" && "${3:-}" == "$CF_LAB_TUNNEL_ID" ]] && return 0
      ;;
    "dns records list")
      [[ "${4:-}" == -z && "${5:-}" == "$LAB_TUNNEL_ZONE" ]] && return 0
      ;;
    "dns records create")
      if [[ "${4:-}" == -z && "${5:-}" == "$LAB_TUNNEL_ZONE" && "${6:-}" == --body ]] &&
        cf_hostname_owned "$LAB_TUNNEL_HOSTNAME" &&
        jq -e --arg host "$LAB_TUNNEL_HOSTNAME" '.name == $host and .type == "CNAME"' <<<"${7:-}" >/dev/null 2>&1; then
        return 0
      fi
      ;;
    "dns records delete")
      [[ -n "$CF_LAB_DNS_RECORD_ID" && "${4:-}" == "$CF_LAB_DNS_RECORD_ID" && "${5:-}" == -z && "${6:-}" == "$LAB_TUNNEL_ZONE" ]] && return 0
      ;;
  esac
  printf 'error: refusing Cloudflare call outside the lab allowlist: cf %s\n' "$(lab_scrub "$*")" >&2
  return 1
}

cf_query() {
  local stderr_file output status=0 message
  cf_assert_allowed "$@" || return 1
  stderr_file="$(mktemp)" || return 1
  output="$(CLOUDFLARE_ACCOUNT_ID="$LAB_CF_ACCOUNT_ID" timeout "${LAB_CF_TIMEOUT:-90}" cf "$@" 2>"$stderr_file")" || status=$?
  if ((status != 0)); then
    message="$(cat "$stderr_file")"
    rm -f "$stderr_file"
    fail "cf $* exited $status: $message"
    return 1
  fi
  rm -f "$stderr_file"
  printf '%s\n' "$output"
}

cf_results() {
  jq -c '(if type == "object" and has("result") then .result else . end)[]'
}

cf_lookup_tunnel() {
  local raw ids count
  CF_LAB_TUNNEL_ID=""
  raw="$(cf_query tunnels list --name "$LAB_TUNNEL_NAME" --is-deleted false)" || return 1
  ids="$(cf_results <<<"$raw" | jq -r --arg name "$LAB_TUNNEL_NAME" 'select(.name == $name and .deleted_at == null) | .id' 2>&1)" || {
    fail "Cloudflare tunnel listing was not in the expected format: $ids"
    return 1
  }
  count="$(grep -c . <<<"$ids" || true)"
  if ((count > 1)); then
    fail "found $count tunnels named $LAB_TUNNEL_NAME, expected at most one"
    return 1
  fi
  CF_LAB_TUNNEL_ID="$ids"
}

cf_lookup_dns_record() {
  local raw row count type content
  CF_LAB_DNS_RECORD_ID=""
  CF_LAB_DNS_RECORD_CONTENT=""
  raw="$(cf_query dns records list -z "$LAB_TUNNEL_ZONE" --name-exact "$LAB_TUNNEL_HOSTNAME")" || return 1
  row="$(cf_results <<<"$raw" | jq -s -c --arg host "$LAB_TUNNEL_HOSTNAME" 'map(select(.name == $host))' 2>&1)" || {
    fail "Cloudflare DNS listing was not in the expected format: $row"
    return 1
  }
  count="$(jq 'length' <<<"$row")"
  ((count > 0)) || return 0
  if ((count > 1)); then
    fail "found $count DNS records named $LAB_TUNNEL_HOSTNAME, expected at most one"
    return 1
  fi
  type="$(jq -r '.[0].type' <<<"$row")"
  content="$(jq -r '.[0].content' <<<"$row")"
  if [[ "$type" != CNAME || ! "$content" =~ ^[0-9a-f-]{36}\.cfargotunnel\.com$ ]]; then
    fail "DNS record $LAB_TUNNEL_HOSTNAME is $type $content, which is not a tunnel record, refusing to touch it"
    return 1
  fi
  CF_LAB_DNS_RECORD_ID="$(jq -r '.[0].id' <<<"$row")"
  CF_LAB_DNS_RECORD_CONTENT="$content"
}

cf_snapshot_others() {
  local tunnels records name id type content
  tunnels="$(cf_query tunnels list --is-deleted false --per-page 1000)" || return 1
  records="$(cf_query dns records list -z "$LAB_TUNNEL_ZONE" --per-page 5000)" || return 1
  {
    while IFS=$'\t' read -r id name; do
      [[ -n "$id" ]] || continue
      cf_tunnel_name_owned "$name" || printf 'tunnel %s %s\n' "$id" "$name"
    done < <(cf_results <<<"$tunnels" | jq -r '[.id, .name] | @tsv')
    while IFS=$'\t' read -r id name type content; do
      [[ -n "$id" ]] || continue
      cf_hostname_owned "$name" || printf 'dns %s %s %s %s\n' "$id" "$name" "$type" "$content"
    done < <(cf_results <<<"$records" | jq -r '[.id, .name, .type, .content] | @tsv')
  } | sort
}

cf_owned_hostnames() {
  local records
  records="$(cf_query dns records list -z "$LAB_TUNNEL_ZONE" --per-page 5000)" || return 1
  cf_results <<<"$records" | jq -r '.name' | while IFS= read -r name; do
    if cf_hostname_owned "$name"; then
      printf '%s\n' "$name"
    fi
  done | sort -u
}

cf_owned_tunnels() {
  local tunnels
  tunnels="$(cf_query tunnels list --is-deleted false --per-page 1000)" || return 1
  cf_results <<<"$tunnels" | jq -r '.name' | while IFS= read -r name; do
    if cf_tunnel_name_owned "$name"; then
      printf '%s\n' "$name"
    fi
  done | sort -u
}

tunnel_ensure() {
  cf_lookup_tunnel || return 1
  if [[ -z "$CF_LAB_TUNNEL_ID" ]]; then
    cf_query tunnels create --name "$LAB_TUNNEL_NAME" --config-source cloudflare >/dev/null || return 1
    cf_lookup_tunnel || return 1
    [[ -n "$CF_LAB_TUNNEL_ID" ]] || {
      fail "tunnel $LAB_TUNNEL_NAME was not found after creating it"
      return 1
    }
    log "tunnel $LAB_TUNNEL_NAME created"
  fi
}

tunnel_set_ingress() {
  cf_query tunnels config update "$CF_LAB_TUNNEL_ID" --tunnel-config-ingress "@$1" >/dev/null
}

tunnel_ensure_dns() {
  local body expected="$CF_LAB_TUNNEL_ID.cfargotunnel.com"
  cf_lookup_dns_record || return 1
  if [[ -n "$CF_LAB_DNS_RECORD_ID" && "$CF_LAB_DNS_RECORD_CONTENT" == "$expected" ]]; then
    return 0
  fi
  if [[ -n "$CF_LAB_DNS_RECORD_ID" ]]; then
    cf_query dns records delete "$CF_LAB_DNS_RECORD_ID" -z "$LAB_TUNNEL_ZONE" --force >/dev/null || return 1
  fi
  body="$(jq -nc --arg name "$LAB_TUNNEL_HOSTNAME" --arg content "$expected" \
    '{type: "CNAME", name: $name, content: $content, proxied: true, ttl: 1}')"
  cf_query dns records create -z "$LAB_TUNNEL_ZONE" --body "$body" >/dev/null || return 1
  log "DNS record created for $LAB_TUNNEL_HOSTNAME"
}

tunnel_remove_dns() {
  cf_lookup_dns_record || return 1
  if [[ -n "$CF_LAB_DNS_RECORD_ID" ]]; then
    cf_query dns records delete "$CF_LAB_DNS_RECORD_ID" -z "$LAB_TUNNEL_ZONE" --force >/dev/null || return 1
    log "DNS record for $LAB_TUNNEL_HOSTNAME removed"
  fi
}

tunnel_store_connector_token() {
  local path="$1" raw token
  raw="$(cf_query tunnels token get "$CF_LAB_TUNNEL_ID")" || return 1
  token="$(jq -r 'if type == "string" then . elif has("result") then .result else empty end' <<<"$raw" 2>/dev/null)" || token="$raw"
  if [[ -z "$token" ]]; then
    token="$raw"
  fi
  local LAB_SCRUB="$token"
  [[ "$token" =~ ^[A-Za-z0-9+/=_-]{100,}$ ]] || {
    fail "Cloudflare returned a connector token in an unexpected format"
    return 1
  }
  mkdir -p "$(dirname "$path")"
  printf '%s' "$token" >"$path"
}

tunnel_remove() {
  local attempt
  cf_lookup_tunnel || return 1
  [[ -n "$CF_LAB_TUNNEL_ID" ]] || return 0
  for ((attempt = 1; attempt <= "${LAB_TUNNEL_DELETE_ATTEMPTS:-24}"; attempt++)); do
    cf_query tunnels connections cleanup "$CF_LAB_TUNNEL_ID" >/dev/null 2>&1 || true
    if cf_query tunnels delete "$CF_LAB_TUNNEL_ID" --force >/dev/null 2>&1; then
      log "tunnel $LAB_TUNNEL_NAME removed"
      return 0
    fi
    sleep "${LAB_TUNNEL_DELETE_DELAY:-5}"
  done
  cf_query tunnels delete "$CF_LAB_TUNNEL_ID" --force >/dev/null
}
