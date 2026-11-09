# Kubernetes on Talos hands-on lab

Automation and teaching material for a university session. Students boot Talos Linux VMs on Proxmox, join them to Sidero Omni with an Image Factory image, build a cluster of 1 control plane and 2 workers, publish a site through a Cloudflare Tunnel, and watch it survive losing a worker.

`./lab` runs that whole flow unattended so it can be built, broken and torn down repeatedly. `docs/hands-on.md` is the student version of the same flow.

## Commands

```bash
./lab gate                              # run the machine cap check
./lab proxmox up|verify|down            # nested Proxmox VM on the local libvirt host
./lab machines up                       # token, image, 3 VMs, registration in Omni
./lab cluster up|prove-reconnect        # create the cluster, revoke the token, restart test
./lab site up|verify                    # rebalance CoreDNS, deploy the hello site
./lab tunnel up|verify                  # tunnel, DNS record, connectors, public check
./lab up                                # machines, cluster, site and tunnel
./lab failover [worker-a|worker-b]      # hard-stop a worker under a public probe
./lab students create <count>|delete    # pre-create student tunnels and tokens
./lab reset                             # remove everything above Proxmox

tests/cap-guard.sh                      # stubbed guard tests, no real services
shellcheck -s bash -x -e SC1090,SC1091,SC2034,SC2154,SC2016,SC2317,SC2024 lab lib/*.sh tests/cap-guard.sh
```

A full rehearsal is `./lab proxmox up`, `./lab up`, `./lab failover`, `./lab reset`. `./lab up` takes about 10 minutes and `./lab reset` about 5, nearly all of it waiting for Omni to notice the VMs have stopped.

## Layout

- `lab` dispatches commands and takes the run lock.
- `lib/common.sh` has logging, config loading, the lock, and `lab_public_curl`.
- `lib/omni.sh` is the only path to `omnictl`, through `omni_run` and `omni_query`.
- `lib/cap.sh` holds the fixed machine identities, the cap gate, join token and preset handling, the watchdog, and the guarded boot.
- `lib/pve-api.sh` is the Proxmox REST client and the VM name guards.
- `lib/proxmox-layer.sh` builds the nested Proxmox VM with libvirt.
- `lib/machines-layer.sh` holds the machines and cluster layers and `lab_reset`.
- `lib/site-layer.sh`, `lib/tunnel-layer.sh`, `lib/failover-layer.sh` and `lib/students-layer.sh` hold the remaining layers. `lib/tunnel-layer.sh` is the only path to `cf`, through `cf_query`.
- `manifests/` holds the Kubernetes manifests students apply unchanged.
- `docker/pve-assistant/` builds the image that prepares the unattended Proxmox installer.

## Configuration and state

`lab.env` is git-ignored, and `lab.env.example` lists its keys:

- `LAB_OMNI_PROFILE` is the clusterctls profile name.
- `LAB_OMNI_ENDPOINT` is the exact Omni URL that profile must resolve to.
- `LAB_OMNI_PROTECTED_CLUSTER` names an existing cluster in the same account. Leave it empty for an account with no other clusters.
- `LAB_CF_ACCOUNT_ID`, `LAB_TUNNEL_ZONE` and `LAB_TUNNEL_HOSTNAME` scope Cloudflare calls. The hostname is exactly one level below the zone, because the free certificate covers nothing deeper.

The repository is intended to become public. Account names, endpoints, account IDs and the domain live only in `lab.env`, so tracked files use placeholders.

`.lab/` is git-ignored and holds run state: `lock`, `pve-target.env`, `proxmox/` (ISO, installer, root password), `cluster/` (template, kubeconfig), `tunnel/`, `students/teamNN.token`, `logs/`, `failures/` (context saved by a failed run) and `failover/` (probe data and timelines).

`.lab/pve-target.env` is the interface between Proxmox and everything above it. `./lab proxmox up` writes it for the nested lab. For another Proxmox, write it by hand with `PVE_URL`, `PVE_NODE`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET`, `PVE_TLS_PIN`, `PVE_ISO_STORAGE`, `PVE_DISK_STORAGE` and `PVE_BRIDGE`. The token needs the roles `PVEVMAdmin`, `PVEDatastoreAdmin` and `PVESDNUser`. `PVE_TLS_PIN` is the base64 SHA-256 of the server's public key.

## Safety rules

The Omni account can hold a real cluster and the service account key is Admin, so Omni itself does not protect anything. The scripts do.

**Machine cap.** Registering more machines than the plan allows may be billable, so it is never tested.

- The gate requires (links excluding the 3 lab IDs) + 3 <= min(10, `registeredmachineslimit`). Any failed query or unexpected output aborts it.
- The gate runs before each VM is created and before each VM is powered on, and VMs boot one at a time.
- The links count comes from `omnictl get links`. `machinestatusmetrics` can lag by days, so only the limit is read from it.
- There are exactly 3 VMs with fixed SMBIOS UUIDs and no count parameter. Omni uses those UUIDs as machine IDs.
- The watchdog runs while the join token is live. It stops the lab VMs and force-revokes the lab token if the total passes the cap, an unknown machine appears, Omni is unreadable three times in a row, or the lab run dies without stopping it.

**Join token.** Machines join with a lab-only token created by `cap_token_create` with a 1 hour TTL and passed to the media preset. An empty token is refused, because `omnictl` then falls back to the account default. It is revoked without `--force` once all 3 machines are installed, so Omni's refusal surfaces any machine still depending on it. Token IDs are secrets and never reach logs, and `LAB_SCRUB` redacts them from errors.

**Omni calls.** `omni_run` loads the profile in a subshell, refuses any endpoint other than `LAB_OMNI_ENDPOINT`, and passes `omni_assert_allowed`. Mutations are limited to the lab token, the `talos-lab` preset and cluster, the rendered template, and the 3 lab links. Always go through `omni_query`, because the active shell profile can point at a different Omni account.

**Proxmox calls.** VM IDs 9101 to 9103 are only touched when their names match the expected lab names.

**Cloudflare calls.** The `cf` login reaches every zone and tunnel in the account. `cf_assert_allowed` limits writes to the tunnels `talos-lab` and `talos-student-NN`, and to CNAME records at the configured hostname or `teamNN.<zone>`. Tunnel and record IDs come only from exact-name lookups. A hostname holding anything other than a tunnel CNAME is refused.

**Teardown.** `./lab reset` touches only the lab cluster, the 3 lab machine IDs, the lab tunnel and its record. It compares the protected cluster's machines, the other tunnels and the other DNS records before and after, and fails on any difference.

**Runs.** `flock` on `.lab/lock` prevents concurrent runs. Each `./lab` invocation loads `lab` and `lib/` fresh, so do not edit them during a multi-command sequence.

**Secrets.** Connector tokens, the kubeconfig and the Proxmox root password stay in `.lab/` with mode 600.

## How the layers work

**Proxmox.** An unattended 9.x install in a libvirt VM with 16 GB RAM, 8 vCPUs and a sparse 200 GB disk. It has its own libvirt network `talos-lab`, bridge `virbr-talos`, subnet `10.77.0.0/24` and storage pool. ufw drops forwarded traffic by default, so the layer adds rules for that bridge only and removes them on teardown. Talos VMs bridge onto that network and get DHCP from libvirt.

**Machines.** Creates the token and preset, downloads the image from Omni, uploads it to Proxmox, creates the VMs, then boots each and waits for its link. VM settings: q35, OVMF with pre-enrolled keys off, CPU type `host`, ballooning off, VirtIO SCSI (`virtio-scsi-pci`), a 32 GB write-through discard disk, the guest agent on, boot order disk then ISO. The control plane has 2 cores and 4 GB, and each worker 2 cores and 3 GB.

**Cluster.** Renders a template naming the 3 machines, syncs it, waits for Ready, revokes the token and deletes the preset. `lab_kubectl` uses a service-account kubeconfig with a 24 hour TTL. Always use it instead of bare `kubectl`.

**Site.** Restarts CoreDNS first, because at bootstrap both replicas land on the one node that is already Ready. Then applies `manifests/hello.yaml`: stock nginx configured by a ConfigMap, with a page that polls `/whoami` every second.

**Tunnel.** Creates a remotely managed tunnel with `cf`, sets its ingress to the `hello` Service, creates the CNAME, stores the connector token in a Secret, and applies `manifests/cloudflared.yaml`. Verification requires both replicas to answer at the public URL.

**Failover.** Hard-stops a worker while probing the public URL once a second, records the timeline, restarts the worker, and rolls both deployments to rebalance.

**Students.** `./lab students create` makes one tunnel, record and token file per student, reusing the tunnel layer. Create them before the session, so each DNS record exists before anyone looks it up.

## Platform behavior the design depends on

- Omni will not remove the last control plane while its cluster exists. Reset therefore starts cluster deletion first and then removes links workers-first. `--destroy-disconnected-machines` deadlocks when every machine is disconnected.
- Omni takes about 4.5 minutes to show a stopped machine as disconnected, so demos and timing use Kubernetes' view.
- Installed machines hold persisted unique tokens and reconnect after a restart with the join token revoked. Machines still in maintenance mode depend on the join token.
- A stopped node's Ready condition becomes `Unknown`, not `False`, after about 50 seconds.
- During those 50 seconds the Service still routes to the dead pod, so some requests fail. Failures stop once the node is marked down. Expect 10 to 13 failures from a once-a-second probe with a 3 second timeout.
- `tolerationSeconds: 30` brings replacements up about 80 seconds after the stop. The Kubernetes default is 300 seconds.
- `whenUnsatisfiable: DoNotSchedule` with `nodeTaintsPolicy: Honor` spreads replicas strictly and still lets the replacement schedule on the surviving worker, because the dead node's untolerated taint removes it from the calculation.
- Pods do not move back when a worker returns. `kubectl rollout restart` rebalances them, and `matchLabelKeys: pod-template-hash` makes that placement clean.
- `keepalive_timeout 0` in nginx closes each connection, so `cloudflared` reconnects through the Service and traffic reaches both replicas.
- The `preStop` sleep on `hello` keeps a terminating pod serving until it leaves the endpoints, which prevents failed requests during a rollout.
- Cloudflare negative DNS responses last 30 minutes for this zone type. A lookup that happens before a record exists can cause "not found" for that long, so `lab_public_curl` resolves through a public resolver.
- `cf` writes a `.cloudflare/` cache containing account details into the working directory, and it is git-ignored.
- In `jq`, `false // x` returns `x`. Compare booleans explicitly when `false` is a meaningful value.

## Network requirements on a new site

- Outbound TCP 443.
- Outbound UDP to the WireGuard port shown in the Omni account's `siderolinkapiconfigs`. Each account has its own port. If UDP is blocked, create the preset with `--use-siderolink-grpc-tunnel` to carry that traffic over 443.
- Outbound UDP and TCP 7844 for `cloudflared`, which has no alternative port.
- A Proxmox bridge with DHCP and outbound internet.
