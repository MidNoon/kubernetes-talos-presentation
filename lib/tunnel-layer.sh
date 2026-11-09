readonly LAB_TUNNEL_SERVICE=http://hello.default.svc.cluster.local:80
readonly TUNNEL_PUBLIC_TIMEOUT=420

LAB_TUNNEL_NAME=talos-lab
CF_LAB_TUNNEL_ID=""
CF_LAB_DNS_RECORD_ID=""

lab_tunnel_token_file() {
  printf '%s' "${LAB_TUNNEL_TOKEN_FILE:-$LAB_STATE/tunnel/connector-token}"
}

cf_tunnel_name_owned() {
  [[ "$1" == talos-lab || "$1" =~ ^talos-student-[0-9]{2}$ ]]
}

cf_hostname_owned() {
  [[ -n "${CF_CONFIGURED_HOSTNAME:-}" && "$1" == "$CF_CONFIGURED_HOSTNAME" ]] && return 0
  [[ "$1" =~ ^team[0-9]{2}\. && "${1#*.}" == "$LAB_TUNNEL_ZONE" ]]
}

cf_load_config() {
  local var label
  for var in LAB_CF_ACCOUNT_ID LAB_TUNNEL_ZONE LAB_TUNNEL_HOSTNAME; do
    [[ -n "${!var:-}" ]] || die "config does not set $var"
  done
  [[ "$LAB_TUNNEL_HOSTNAME" == *".$LAB_TUNNEL_ZONE" ]] || die "LAB_TUNNEL_HOSTNAME $LAB_TUNNEL_HOSTNAME is not inside zone $LAB_TUNNEL_ZONE"
  label="${LAB_TUNNEL_HOSTNAME%".$LAB_TUNNEL_ZONE"}"
  [[ "$label" =~ ^[a-z0-9-]+$ ]] || die "LAB_TUNNEL_HOSTNAME must be exactly one level below $LAB_TUNNEL_ZONE, the free certificate covers nothing deeper"
  CF_CONFIGURED_HOSTNAME="$LAB_TUNNEL_HOSTNAME"
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

cf_lookup_tunnel() {
  local raw ids count
  CF_LAB_TUNNEL_ID=""
  raw="$(cf_query tunnels list --name "$LAB_TUNNEL_NAME" --is-deleted false)" || return 1
  ids="$(jq -r --arg name "$LAB_TUNNEL_NAME" \
    '(if type == "object" and has("result") then .result else . end)[] | select(.name == $name and .deleted_at == null) | .id' <<<"$raw" 2>&1)" || {
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
  raw="$(cf_query dns records list -z "$LAB_TUNNEL_ZONE" --name-exact "$LAB_TUNNEL_HOSTNAME")" || return 1
  row="$(jq -c --arg host "$LAB_TUNNEL_HOSTNAME" \
    '[(if type == "object" and has("result") then .result else . end)[] | select(.name == $host)]' <<<"$raw" 2>&1)" || {
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
  local tunnels records
  tunnels="$(cf_query tunnels list --is-deleted false --per-page 1000)" || return 1
  records="$(cf_query dns records list -z "$LAB_TUNNEL_ZONE" --per-page 5000)" || return 1
  jq -r --arg name "$LAB_TUNNEL_NAME" \
    '(if type == "object" and has("result") then .result else . end)[] | select(.name != $name) | "tunnel \(.id) \(.name)"' <<<"$tunnels" | sort || return 1
  jq -r --arg host "$LAB_TUNNEL_HOSTNAME" \
    '(if type == "object" and has("result") then .result else . end)[] | select(.name != $host) | "dns \(.id) \(.name) \(.type) \(.content)"' <<<"$records" | sort
}

tunnel_capture_failure() {
  local reason="$1" dir
  dir="$LAB_STATE/failures/tunnel-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$dir"
  lab_kubectl get pods -o wide >"$dir/pods.txt" 2>&1 || true
  lab_kubectl logs deployment/cloudflared --all-containers --tail=120 >"$dir/cloudflared-logs.txt" 2>&1 || true
  lab_kubectl describe deployment cloudflared >"$dir/cloudflared-deployment.txt" 2>&1 || true
  if [[ -n "$CF_LAB_TUNNEL_ID" ]]; then
    cf_query tunnels connections list "$CF_LAB_TUNNEL_ID" >"$dir/connections.json" 2>&1 || true
  fi
  lab_public_curl --silent --show-error --max-time 15 --verbose --output /dev/null "https://$LAB_TUNNEL_HOSTNAME/whoami" >"$dir/curl.txt" 2>&1 || true
  die "$reason. Context saved in $dir"
}

tunnel_ensure_dns() {
  local body expected="$CF_LAB_TUNNEL_ID.cfargotunnel.com"
  cf_lookup_dns_record || exit 1
  if [[ -n "$CF_LAB_DNS_RECORD_ID" && "$CF_LAB_DNS_RECORD_CONTENT" == "$expected" ]]; then
    return 0
  fi
  if [[ -n "$CF_LAB_DNS_RECORD_ID" ]]; then
    cf_query dns records delete "$CF_LAB_DNS_RECORD_ID" -z "$LAB_TUNNEL_ZONE" --force >/dev/null || exit 1
  fi
  body="$(jq -nc --arg name "$LAB_TUNNEL_HOSTNAME" --arg content "$expected" \
    '{type: "CNAME", name: $name, content: $content, proxied: true, ttl: 1}')"
  cf_query dns records create -z "$LAB_TUNNEL_ZONE" --body "$body" >/dev/null || exit 1
  log "DNS record created for $LAB_TUNNEL_HOSTNAME"
}

tunnel_store_connector_token() {
  local raw token path
  raw="$(cf_query tunnels token get "$CF_LAB_TUNNEL_ID")" || exit 1
  token="$(jq -r 'if type == "string" then . elif has("result") then .result else empty end' <<<"$raw" 2>/dev/null)" || token="$raw"
  if [[ -z "$token" ]]; then
    token="$raw"
  fi
  local LAB_SCRUB="$token"
  [[ "$token" =~ ^[A-Za-z0-9+/=_-]{100,}$ ]] || die "Cloudflare returned a connector token in an unexpected format"
  path="$(lab_tunnel_token_file)"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$token" >"$path"
}

tunnel_verify() {
  local url="https://$LAB_TUNNEL_HOSTNAME/whoami" deadline=$((SECONDS + TUNNEL_PUBLIC_TIMEOUT)) body="" pod attempt seen="" nodes
  nodes="$(site_distinct_nodes default app=cloudflared)" || tunnel_capture_failure "could not read cloudflared placement"
  ((nodes == 2)) || tunnel_capture_failure "cloudflared pods are on $nodes nodes, expected 2"
  until body="$(lab_public_curl --silent --fail --max-time 8 "$url" 2>/dev/null)"; do
    if ((SECONDS >= deadline)); then
      tunnel_capture_failure "$url did not answer within ${TUNNEL_PUBLIC_TIMEOUT}s"
    fi
    sleep 5
  done
  log "$url is answering"
  for ((attempt = 1; attempt <= 40; attempt++)); do
    body="$(lab_public_curl --silent --fail --max-time 8 "$url")" || tunnel_capture_failure "$url failed during verification on request $attempt"
    pod="$(jq -er .pod <<<"$body")" || tunnel_capture_failure "$url returned an unreadable body: $body"
    if ! grep -qxF "$pod" <<<"$seen"; then
      seen+="$pod"$'\n'
    fi
  done
  (($(grep -c . <<<"$seen") == 2)) || tunnel_capture_failure "only saw these pods answer in 40 public requests: $seen"
  log "tunnel verified: both connectors running on 2 nodes and both site replicas answering at https://$LAB_TUNNEL_HOSTNAME"
}

tunnel_provision() {
  local ingress
  cf_lookup_tunnel || exit 1
  if [[ -z "$CF_LAB_TUNNEL_ID" ]]; then
    cf_query tunnels create --name "$LAB_TUNNEL_NAME" --config-source cloudflare >/dev/null || exit 1
    cf_lookup_tunnel || exit 1
    [[ -n "$CF_LAB_TUNNEL_ID" ]] || die "tunnel $LAB_TUNNEL_NAME was not found after creating it"
    log "tunnel $LAB_TUNNEL_NAME created"
  fi

  mkdir -p "$LAB_STATE/tunnel"
  ingress="$LAB_STATE/tunnel/$LAB_TUNNEL_NAME-ingress.json"
  jq -n --arg host "$LAB_TUNNEL_HOSTNAME" --arg service "$LAB_TUNNEL_SERVICE" \
    '[{hostname: $host, service: $service}, {service: "http_status:404"}]' >"$ingress"
  cf_query tunnels config update "$CF_LAB_TUNNEL_ID" --tunnel-config-ingress "@$ingress" >/dev/null || exit 1
  tunnel_ensure_dns
  tunnel_store_connector_token
}

tunnel_up() {
  lab_load_config
  cf_load_config
  site_require_cluster
  lab_kubectl get deployment hello >/dev/null 2>&1 || die "the hello site is not deployed, run ./lab site up first"

  tunnel_provision
  lab_kubectl create secret generic cloudflared-token \
    --from-file=token="$(lab_tunnel_token_file)" \
    --dry-run=client -o yaml | lab_kubectl apply -f - >/dev/null
  lab_kubectl apply -f "$LAB_ROOT/manifests/cloudflared.yaml" >/dev/null
  lab_kubectl rollout status deployment/cloudflared --timeout="$SITE_ROLLOUT_TIMEOUT" >/dev/null ||
    tunnel_capture_failure "cloudflared did not finish rolling out"
  tunnel_verify
}

tunnel_remove_current() {
  local attempt deleted=false
  cf_lookup_tunnel || exit 1
  cf_lookup_dns_record || exit 1

  if [[ -n "$CF_LAB_DNS_RECORD_ID" ]]; then
    cf_query dns records delete "$CF_LAB_DNS_RECORD_ID" -z "$LAB_TUNNEL_ZONE" --force >/dev/null || exit 1
    log "DNS record for $LAB_TUNNEL_HOSTNAME removed"
  fi

  if [[ -n "$CF_LAB_TUNNEL_ID" ]]; then
    for ((attempt = 1; attempt <= "${LAB_TUNNEL_DELETE_ATTEMPTS:-24}"; attempt++)); do
      cf_query tunnels connections cleanup "$CF_LAB_TUNNEL_ID" >/dev/null 2>&1 || true
      if cf_query tunnels delete "$CF_LAB_TUNNEL_ID" --force >/dev/null 2>&1; then
        deleted=true
        break
      fi
      sleep "${LAB_TUNNEL_DELETE_DELAY:-5}"
    done
    [[ "$deleted" == true ]] || {
      cf_query tunnels delete "$CF_LAB_TUNNEL_ID" --force >/dev/null
      exit 1
    }
    log "tunnel $LAB_TUNNEL_NAME removed"
  fi
}

tunnel_down() {
  local before after leftovers=()
  cf_load_config
  before="$(cf_snapshot_others)" || exit 1
  tunnel_remove_current
  rm -rf "$LAB_STATE/tunnel"

  cf_lookup_tunnel || exit 1
  [[ -z "$CF_LAB_TUNNEL_ID" ]] || leftovers+=("tunnel $LAB_TUNNEL_NAME")
  cf_lookup_dns_record || exit 1
  [[ -z "$CF_LAB_DNS_RECORD_ID" ]] || leftovers+=("dns record $LAB_TUNNEL_HOSTNAME")
  ((${#leftovers[@]} == 0)) || die "tunnel teardown left resources behind: ${leftovers[*]}"

  after="$(cf_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed during teardown. Before: $before. After: $after"
  log "tunnel layer removed, other tunnels and DNS records unchanged"
}
