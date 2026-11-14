readonly SEAT_MAX=20

SEATS_STATE="$LAB_STATE/seats"

seat_user() {
  printf 'student%02d' "$((10#$1))"
}

seat_pool() {
  printf 'seat%02d' "$((10#$1))"
}

seat_password() {
  awk -F'\t' -v u="$1" '$1 == u {print $3}' "$HOST_STATE/users.tsv"
}

seat_omni_user() {
  local email="$1@$LAB_TUNNEL_ZONE" identities
  identities="$(host_omnictl get identities -o json 2>&1)" || die "could not list Omni identities: $identities"
  if jq -e -s --arg email "$email" 'any(.[]; .metadata.id == $email)' <<<"$identities" >/dev/null 2>&1; then
    return 0
  fi
  host_omnictl user create "$email" --role Operator >/dev/null || die "could not create Omni user $email"
  log "Omni user $email created with the Operator role"
}

seat_proxmox_user() {
  local user="$1" pool="$2" password="$3"
  host_remote USER_ID="$user@pve" POOL="$pool" PASSWORD="$password" \
    ISO_STORAGE="$PVE_ISO_STORAGE" DISK_STORAGE="$PVE_DISK_STORAGE" ZONE="$HOST_SDN_ZONE" VNET="$HOST_VNET" <<'EOF'
set -euo pipefail
pveum pool list --output-format json | grep -q "\"poolid\":\"$POOL\"" || pveum pool add "$POOL"
if ! pveum user list --output-format json | grep -q "\"userid\":\"$USER_ID\""; then
  pveum user add "$USER_ID" --password "$PASSWORD"
fi
pveum acl modify "/pool/$POOL" --users "$USER_ID" --roles PVEVMAdmin
pveum acl modify "/storage/$ISO_STORAGE" --users "$USER_ID" --roles PVEDatastoreUser
pveum acl modify "/storage/$DISK_STORAGE" --users "$USER_ID" --roles PVEDatastoreUser
pveum acl modify "/sdn/zones/$ZONE/$VNET" --users "$USER_ID" --roles PVESDNUser
EOF
  log "Proxmox user $user@pve with pool $pool"
}

seat_sheet() {
  local number="$1" user password
  user="$(seat_user "$number")"
  password="$(seat_password "$user")"
  mkdir -p "$SEATS_STATE"
  {
    printf 'username  %s\n' "$user"
    printf 'password  %s\n' "$password"
    printf 'omni      https://%s (sign in as %s@%s)\n' "$(host_name omni)" "$user" "$LAB_TUNNEL_ZONE"
    printf 'proxmox   https://%s (realm Proxmox VE authentication server, user %s)\n' "$(host_name pve)" "$user"
    printf 'site      https://%s\n' "$(printf 'team%02d.%s' "$((10#$number))" "$LAB_TUNNEL_ZONE")"
    printf 'pool      %s\n' "$(seat_pool "$number")"
  } >"$SEATS_STATE/$(seat_pool "$number").txt"
}

seats_create() {
  local count="${1:-}" number user
  if [[ ! "$count" =~ ^[1-9][0-9]*$ ]] || ((count > SEAT_MAX)); then
    die "seats create needs a count from 1 to $SEAT_MAX, got \"$count\""
  fi
  host_load_config
  for ((number = 1; number <= count; number++)); do
    host_ensure_user "$(seat_user "$number")"
  done
  host_stage
  host_install_stage
  host_restart talos-lab-dex
  host_wait_local dex "http://127.0.0.1:$HOST_DEX_PORT/.well-known/openid-configuration"
  for ((number = 1; number <= count; number++)); do
    user="$(seat_user "$number")"
    seat_omni_user "$user"
    seat_proxmox_user "$user" "$(seat_pool "$number")" "$(seat_password "$user")"
    seat_sheet "$number"
  done
  students_create "$count"
  log "$count seats ready, sign-in sheets in $SEATS_STATE"
}
