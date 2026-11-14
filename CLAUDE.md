# Kubernetes on Talos hands-on lab

Automation and teaching material for a university session. Students boot Talos Linux VMs on Proxmox, join them to Sidero Omni with an Image Factory image, build a cluster of 1 control plane and 2 workers, publish a site through a Cloudflare Tunnel, and watch it survive losing a worker.

`./lab` runs that whole flow unattended so it can be built, broken and torn down repeatedly. `docs/hands-on.md` is the student version of the same flow.

Omni comes in two forms here. The machines, cluster, site, tunnel and failover layers use an Omni SaaS account. The host and seats layers run a self-hosted Omni on the Proxmox host, with Dex logins and a tunnel, so students need nothing but a browser and lab-issued credentials.

## Commands

```bash
./lab gate                              # run the machine cap check
./lab proxmox up|verify|down            # nested Proxmox VM on the local libvirt host
./lab host up|verify|down               # private network, Omni, Dex and cloudflared on the Proxmox host
./lab seats create <count>              # Dex, Omni and Proxmox logins plus a site tunnel per seat
./lab machines up                       # token, image, 3 VMs, registration in Omni
./lab cluster up|prove-reconnect        # create the cluster, revoke the token, restart test
./lab site up|verify                    # rebalance CoreDNS, deploy the hello site
./lab tunnel up|verify                  # tunnel, DNS record, connectors, public check
./lab up                                # machines, cluster, site and tunnel
./lab failover [worker-a|worker-b]      # hard-stop a worker under a public probe
./lab students create <count>|delete    # pre-create student tunnels and tokens
./lab reset                             # remove everything above Proxmox

tools/site-check.sh [host:port ...]     # KVM, gateway, DNS and egress checks on a candidate site host
tests/cap-guard.sh                      # stubbed guard tests, no real services
shellcheck -s bash -x -e SC1090,SC1091,SC2034,SC2154,SC2016,SC2317,SC2024,SC2029 lab lib/*.sh tests/cap-guard.sh tools/site-check.sh
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
- `lib/host-layer.sh` builds the self-hosted stack on the Proxmox host over SSH. `host_omnictl` is the only path to the self-hosted Omni.
- `lib/seats-layer.sh` provisions student seats on the self-hosted stack.
- `manifests/` holds the Kubernetes manifests students apply unchanged.
- `docker/pve-assistant/` builds the image that prepares the unattended Proxmox installer.
- `tools/site-check.sh` runs standalone on a Proxmox host or desktop at a candidate site, with no dependency on the rest of the repo.

## Configuration and state

`lab.env` is git-ignored, and `lab.env.example` lists its keys:

- `LAB_OMNI_PROFILE` is the clusterctls profile name.
- `LAB_OMNI_ENDPOINT` is the exact Omni URL that profile must resolve to.
- `LAB_OMNI_PROTECTED_CLUSTER` names an existing cluster in the same account. Leave it empty for an account with no other clusters.
- `LAB_CF_ACCOUNT_ID`, `LAB_TUNNEL_ZONE` and `LAB_TUNNEL_HOSTNAME` scope Cloudflare calls. The hostname is exactly one level below the zone, because the free certificate covers nothing deeper.
- `LAB_OMNI_EULA_NAME` and `LAB_OMNI_EULA_EMAIL` are the person accepting Sidero's EULA for the self-hosted Omni, which does not start without them.

The repository is intended to become public. Account names, endpoints, account IDs, the domain and the EULA acceptance live only in `lab.env`, so tracked files use placeholders.

`.lab/` is git-ignored and holds run state: `lock`, `pve-target.env`, `proxmox/` (ISO, installer, root password, `ssh/` key and known_hosts), `host/` (binaries, the Omni etcd key, the Dex client secret, `users.tsv`, the Omni service account key, the host tunnel token), `seats/seatNN.txt` (sign-in sheets), `cluster/` (template, kubeconfig), `tunnel/`, `students/teamNN.token`, `logs/`, `failures/` (context saved by a failed run) and `failover/` (probe data and timelines).

`.lab/pve-target.env` is the interface between Proxmox and everything above it. `./lab proxmox up` writes it for the nested lab. For another Proxmox, write it by hand with `PVE_URL`, `PVE_NODE`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET`, `PVE_TLS_PIN`, `PVE_ISO_STORAGE`, `PVE_DISK_STORAGE`, `PVE_BRIDGE`, `PVE_SSH` (`root@host`), `PVE_SSH_KEY` and `PVE_SSH_KNOWN_HOSTS`. The token needs the roles `PVEVMAdmin`, `PVEDatastoreAdmin` and `PVESDNUser`. `PVE_TLS_PIN` is the base64 SHA-256 of the server's public key. Root SSH is key-only and checks the host key strictly.

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

**Cloudflare calls.** The `cf` login reaches every zone and tunnel in the account. `cf_assert_allowed` limits writes to the tunnels `talos-lab`, `talos-lab-host` and `talos-student-NN`, and to CNAME records at the configured hostname, `teamNN.<zone>`, and `omni`, `kube`, `auth` and `pve` in the zone. Tunnel and record IDs come only from exact-name lookups. A hostname holding anything other than a tunnel CNAME is refused. `./lab host up` and `./lab host down` compare every other tunnel and DNS record before and after.

**Teardown.** `./lab reset` touches only the lab cluster, the 3 lab machine IDs, the lab tunnel and its record. It compares the protected cluster's machines, the other tunnels and the other DNS records before and after, and fails on any difference.

**Runs.** `flock` on `.lab/lock` prevents concurrent runs. Each `./lab` invocation loads `lab` and `lib/` fresh, so do not edit them during a multi-command sequence.

**Secrets.** Connector tokens, the kubeconfig, the Proxmox root password and SSH key, the Omni service account key and seat passwords stay in `.lab/` with mode 600. `.lab/host/users.tsv` keeps each seat's password in plain text so it can be handed out, and Dex only receives the bcrypt hash. On the host, `/etc/talos-lab` and `/var/lib/talos-lab` are root-only.

## How the layers work

**Proxmox.** An unattended 9.x install in a libvirt VM with 24 GB RAM, 8 vCPUs and a sparse 200 GB disk. The answer file installs the lab SSH public key for root, and the host key is recorded on first contact after the install. It has its own libvirt network `talos-lab`, bridge `virbr-talos`, subnet `10.77.0.0/24` and storage pool. ufw drops forwarded traffic by default, so the layer adds rules for that bridge only and removes them on teardown. The SaaS layers bridge Talos VMs onto that network with DHCP from libvirt.

**Host.** Disables the enterprise apt sources, installs dnsmasq, and creates the SDN simple zone `talab` with vnet `talabnet` on `10.88.0.0/24`. Its gateway `10.88.0.1` is on the host, with SNAT out and DHCP from `.100` to `.199`. VMs get the host's own resolver. It then runs three systemd services:
- `talos-lab-omni` serves its API on `127.0.0.1:8080`, the Kubernetes proxy on `127.0.0.1:8095`, and the machine API and WireGuard on `10.88.0.1`. It logs users in through Dex and writes an Admin service account key on first start.
- `talos-lab-dex` serves OIDC on `127.0.0.1:5556` with static passwords from `users.tsv`.
- `talos-lab-cloudflared` runs the `talos-lab-host` tunnel, which maps `omni`, `kube`, `auth` and `pve` to those local ports and to Proxmox on 8006.

Omni, Dex, the five `omnictl` builds and cloudflared are pinned by version and checksum, downloaded locally, and uploaded only when they differ. `host_omnictl` reaches Omni through an SSH forward to `127.0.0.1:8080`.

**Seats.** `./lab seats create <count>` gives seat NN:
- a Dex user `studentNN` and an Omni user `studentNN@<zone>` with the Operator role;
- a Proxmox user `studentNN@pve` that is PVEVMAdmin on pool `seatNN`, can use both storages, and can use the `talabnet` vnet;
- the student tunnel for `teamNN.<zone>`;
- a sign-in sheet at `.lab/seats/seatNN.txt`.

Every student shares one Omni and can see the other seats' machines and clusters.

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
- Hard-stopping a node within about a minute of pulling an image can leave a damaged copy on its disk, seen as `exec format error` and `CrashLoopBackOff` once the node returns. Deleting the pod does not help, because the damaged image stays on that node. `kubectl set image` to a different version pulls clean layers. `failover_run` waits until the newest pod is 120 seconds old to avoid it.
- `tolerationSeconds: 30` brings replacements up about 80 seconds after the stop. The Kubernetes default is 300 seconds.
- `whenUnsatisfiable: DoNotSchedule` with `nodeTaintsPolicy: Honor` spreads replicas strictly and still lets the replacement schedule on the surviving worker, because the dead node's untolerated taint removes it from the calculation.
- Pods do not move back when a worker returns. `kubectl rollout restart` rebalances them, and `matchLabelKeys: pod-template-hash` makes that placement clean.
- `keepalive_timeout 0` in nginx closes each connection, so `cloudflared` reconnects through the Service and traffic reaches both replicas.
- The `preStop` sleep on `hello` keeps a terminating pod serving until it leaves the endpoints, which prevents failed requests during a rollout.
- Cloudflare negative DNS responses last 30 minutes for this zone type. A lookup that happens before a record exists can cause "not found" for that long, so `lab_public_curl` resolves through a public resolver.
- `cf` writes a `.cloudflare/` cache containing account details into the working directory, and it is git-ignored.
- In `jq`, `false // x` returns `x`. Compare booleans explicitly when `false` is a meaningful value.
- Self-hosted Omni serves `omnictl` downloads from `./omnictl/` in its working directory and exits at startup when that directory is missing. There is no flag for the path.
- Omni has no flag for the OIDC client secret, so it lives in `/etc/talos-lab/omni.yaml`. `--auth-auth0-enabled` cannot be turned off once it is on, so it is never set.
- Omni serves plain HTTP when it has no certificate, and the tunnel terminates TLS. Talos machines connect to the machine API as `grpc://10.88.0.1:8090` and to WireGuard on the private network, so neither is public.
- Cloudflare answers native gRPC on the zone with 403, so `omnictl` cannot use the public hostname. The Omni web UI, the Dex login and `kubectl` through `kube.<zone>` work through the tunnel.
- Dex's password login asks for the email address, so students sign in as `studentNN@<zone>`.
- Talos 1.14.5 machines on the private network register with the self-hosted Omni about 30 seconds after boot, and the 3-machine cluster is Ready about 4 minutes after the template sync.

## Network requirements on a new site

- Outbound TCP 443.
- Outbound UDP to the WireGuard port shown in the Omni account's `siderolinkapiconfigs`. Each account has its own port. If UDP is blocked, create the preset with `--use-siderolink-grpc-tunnel` to carry that traffic over 443.
- Outbound UDP and TCP 7844 for `cloudflared`, which has no alternative port.
- A Proxmox bridge with DHCP and outbound internet.
- KVM inside the Proxmox host, meaning the `vmx` or `svm` flag and `/dev/kvm`, when Proxmox itself runs as a VM.

The self-hosted stack needs less: outbound TCP 443 and TCP and UDP 7844 from the Proxmox host, root SSH to it, and nested virtualization. Omni's WireGuard and machine API stay on the private network, and students reach everything through the tunnel.

`tools/site-check.sh` tests the TCP side of these from a host on the site. Pass the Omni account host as an extra `host:443` argument. It cannot test the UDP ports, because nothing answers a bare UDP probe.
