# Kubernetes on Talos hands-on lab

Automation and teaching material for a university session. Each student gets a seat on one shared Proxmox host: their own Omni, their own private network, and a Proxmox login limited to their own VMs. Students boot Talos Linux VMs from their seat's install image, watch them join their Omni, build a cluster of 1 control plane and 2 workers, publish a site through a Cloudflare Tunnel, and watch it survive losing a worker. They reach everything through a browser at hostnames under one zone, with logins the lab issues.

`./lab` builds the host and the seats, and rehearses a student's run on any seat so the whole flow can be built, broken and torn down repeatedly. `docs/hands-on.md` is the student version of the same flow.

## Commands

```bash
./lab proxmox up|verify|down                 # nested Proxmox VM on the local libvirt host
./lab host up|verify|down                    # shared services on the Proxmox host
./lab seats create <count>|delete            # per-seat network, Omni container, logins, image, site tunnel
./lab seat <n> up                            # rehearse a student's run: VMs, cluster, site, tunnel
./lab seat <n> failover [worker-a|worker-b]  # hard-stop a worker under a public probe
./lab seat <n> reset                         # remove the seat's cluster, machines and VMs, keep the seat

tools/site-check.sh [host:port ...]          # KVM, gateway, DNS and egress checks on a candidate site host
tests/guards.sh                              # stubbed guard tests, no real services
shellcheck -s bash -x -e SC1090,SC1091,SC2034,SC2154,SC2016,SC2317,SC2024,SC2029 lab lib/*.sh tests/guards.sh tools/site-check.sh
```

A full rehearsal is `./lab proxmox up`, `./lab host up`, `./lab seats create 1`, `./lab seat 1 up`, `./lab seat 1 failover`, `./lab seat 1 reset`, `./lab seats delete`, `./lab host down`. Above Proxmox it takes about 16 minutes:

| Step | Time |
| --- | --- |
| `host up` | about 25 seconds |
| `seats create 1` | about 90 seconds, mostly downloading the seat's ISO |
| `seat 1 up` | about 7 minutes |
| `seat 1 failover` | about 5 minutes, including the 120 second image wait |
| `seat 1 reset` | about 2 minutes |
| `seats delete` and `host down` | under a minute |

Running `seats create` again leaves running seats untouched, because a seat's Omni restarts only when its configuration changed.

## Layout

- `lab` dispatches commands and takes the run lock.
- `lib/common.sh` has the pinned Talos and Kubernetes versions, logging, config loading, the lock, exit hooks and `lab_public_curl`.
- `lib/pve-api.sh` is the Proxmox REST client, root SSH and SSH forwards, and the guest name guards.
- `lib/cloudflare.sh` is the only path to `cf`, through `cf_query` and its allowlist, plus tunnel and DNS primitives.
- `lib/proxmox-layer.sh` builds the nested Proxmox VM with libvirt.
- `lib/host-layer.sh` builds the shared services on the Proxmox host.
- `lib/seats-layer.sh` builds and removes seats. `seat_omnictl` is the only path to a seat's Omni.
- `lib/rehearsal-layer.sh`, `lib/site-layer.sh` and `lib/failover-layer.sh` play a student's run on a seat.
- `manifests/` holds the Kubernetes manifests students apply unchanged.
- `docker/pve-assistant/` builds the image that prepares the unattended Proxmox installer.
- `tools/site-check.sh` runs standalone on a Proxmox host or desktop at a candidate site, with no dependency on the rest of the repo.

## Configuration and state

`lab.env` is git-ignored, and `lab.env.example` lists its keys:

- `LAB_CF_ACCOUNT_ID` and `LAB_TUNNEL_ZONE` scope Cloudflare calls. Every lab hostname is exactly one level below the zone, because the free certificate covers nothing deeper.
- `LAB_OMNI_EULA_NAME` and `LAB_OMNI_EULA_EMAIL` are the person accepting Sidero's EULA for the seat Omni instances, which do not start without them.

The repository is intended to become public. Account IDs, the domain and the EULA acceptance live only in `lab.env`, so tracked files use placeholders.

`.lab/` is git-ignored and holds run state:
- `lock` and `pve-target.env`.
- `proxmox/` holds the ISO, the installer, the root password, and `ssh/` with the key and known_hosts.
- `host/` holds the downloaded binaries, the Dex client secret, `users.tsv`, the host resolver in `host-dns`, and the host tunnel token.
- `seats/seatNN/` holds the seat's Omni account ID, its etcd key, its Omni service account key, the site tunnel token, `sheet.txt`, and the rehearsal kubeconfig, cluster template and failover runs.
- `logs/` and `failures/`, which holds the context a failed run saved.

`.lab/pve-target.env` is the interface between Proxmox and everything above it. `./lab proxmox up` writes it for the nested lab. For another Proxmox, write it by hand with these keys:
- `PVE_URL`, `PVE_NODE`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET` and `PVE_TLS_PIN`.
- `PVE_ISO_STORAGE` and `PVE_DISK_STORAGE`.
- `PVE_SSH` (`root@host`), `PVE_SSH_KEY` and `PVE_SSH_KNOWN_HOSTS`.

The token needs the roles `PVEVMAdmin`, `PVEDatastoreAdmin`, `PVESDNUser` and `PVEPoolAdmin`. `PVE_TLS_PIN` is the base64 SHA-256 of the server's public key. Root SSH is key-only and checks the host key strictly.

## Safety rules

**Proxmox calls.** Seat n owns container `9000 + 10n` named `omniNN` and VMs `9000 + 10n + 1..3` named `seatNN-cp`, `seatNN-worker-a` and `seatNN-worker-b`. A guest is only started, stopped or deleted when its ID and name both match.

**Cloudflare calls.** The `cf` login reaches every zone and tunnel in the account. `cf_assert_allowed` limits writes to the tunnels `talos-lab-host` and `talos-student-NN`, and to CNAME records named `teamNN`, `omniNN`, `kubeNN`, `auth` and `pve` in the zone. Tunnel and record IDs come only from exact-name lookups. A hostname holding anything other than a tunnel CNAME is refused. `host up`, `host down`, `seats create` and `seats delete` compare every other tunnel and DNS record before and after, and fail on any difference.

**Omni calls.** A seat's Omni is reached only through `seat_omnictl`, with that seat's service account key, over an SSH forward to its container.

**Runs.** `flock` on `.lab/lock` prevents concurrent runs. Each `./lab` invocation loads `lab` and `lib/` fresh, so do not edit them during a multi-command sequence.

**Secrets.** Connector tokens, kubeconfigs, the Proxmox root password and SSH key, Omni service account keys and seat passwords stay in `.lab/` with mode 600. `.lab/host/users.tsv` keeps each seat's password in plain text so it can be handed out, and Dex only receives the bcrypt hash. On the host and in the seat containers, `/etc/talos-lab` and `/var/lib/talos-lab` are root-only.

## How the layers work

**Proxmox.** An unattended 9.x install in a libvirt VM with 24 GB RAM, 8 vCPUs and a sparse 200 GB disk. The answer file installs the lab SSH public key for root, and the host key is recorded on first contact after the install. It has its own libvirt network `talos-lab`, bridge `virbr-talos`, subnet `10.77.0.0/24` and storage pool. ufw drops forwarded traffic by default, so the layer adds rules for that bridge only and removes them on teardown.

**Host.** The host layer prepares the Proxmox host:
- It disables the enterprise apt sources, installs dnsmasq, and loads the WireGuard module.
- It creates the SDN simple zone `talab` with DHCP, and downloads the Debian 13 container template.
- It puts Omni, the five `omnictl` builds, Dex and cloudflared in `/usr/local/lib/talos-lab`. Each is pinned by version and checksum, downloaded locally, and uploaded only when it differs.

It runs two systemd services:
- `talos-lab-dex` serves OIDC on `127.0.0.1:5556`. It has static passwords from `users.tsv` and one client, `omni`, with a redirect URI per seat.
- `talos-lab-cloudflared` runs the `talos-lab-host` tunnel. That tunnel maps `auth` to Dex and `pve` to Proxmox on 8006, and `omniNN` and `kubeNN` to each seat's Omni API and Kubernetes proxy.

**Seats.** Seat n gets:
- the vnet `seatNN` on `10.88.n.0/24`, with gateway `.1` on the host, SNAT out, DHCP from `.100` to `.199`, and the host's resolver;
- an unprivileged Debian container `omniNN` at `10.88.n.2`, with `/dev/net/tun` passed in and the host's binary directory mounted read-only at `/opt/talos-lab`. It runs one Omni with every listener on `10.88.n.2`, its own account ID and etcd key, `studentNN@<zone>` and `instructor@<zone>` as Admins, and an Admin service account whose key the lab pulls out;
- a media preset `talos-lab` in that Omni, with the pinned Talos version and the guest agent extension. Its ISO is uploaded to Proxmox as `seatNN-talos.iso`;
- a Proxmox user `studentNN@pve` who is PVEVMAdmin on pool `seatNN`, can use both storages, and can use only the vnet `seatNN`;
- the tunnel `talos-student-NN` for `teamNN.<zone>`, which points at the `hello` Service. Its connector token is in `site-token`;
- a sign-in sheet.

**Rehearsal.** `./lab seat <n> up` plays the student's run:
- It creates the seat's three VMs in its pool, on its vnet, from its ISO. Each VM uses q35, OVMF with pre-enrolled keys off, CPU type `host`, ballooning off, VirtIO SCSI (`virtio-scsi-pci`), a 32 GB write-through discard disk, the guest agent, and boot order disk then ISO. The control plane has 2 cores and 4 GB, and each worker 2 cores and 3 GB.
- It boots them one at a time and waits for each to register.
- It syncs a cluster template named `seatNN` and waits for Ready.
- It fetches a 24 hour service-account kubeconfig that reaches the cluster through `kubeNN`. `lab_kubectl` uses that kubeconfig, so use it instead of bare `kubectl`.
- It deploys the site and connects the seat's tunnel.

`./lab seat <n> reset` deletes the cluster while its machines are online, then deletes the VMs and their links, and keeps everything `seats create` made.

**Site.** Restarts CoreDNS first, because at bootstrap both replicas land on the one node that is already Ready. Then applies `manifests/hello.yaml`: stock nginx configured by a ConfigMap, with a page that polls `/whoami` every second. The tunnel step stores the seat's connector token in a Secret and applies `manifests/cloudflared.yaml`, and verification requires both replicas to answer at `https://teamNN.<zone>`.

**Failover.** Waits until the newest pod is 120 seconds old, then hard-stops a worker while probing the public URL once a second. It records the timeline, restarts the worker, and rolls both deployments to rebalance. Runs are saved under the seat's `failover/`.

## Platform behavior the design depends on

- Omni always creates a WireGuard interface named `siderolink` with the address `fdae:41e4:649b:9303::1/64`, and has no flag to change either. Two Omni instances cannot share a network namespace, so each seat's Omni runs in its own container.
- Omni uses userspace WireGuard, so an unprivileged container needs `/dev/net/tun` passed in (`--dev0 /dev/net/tun`).
- Go treats a `0.0.0.0` bind as dual-stack, which collides with Omni's own listener on the SideroLink address. Every seat Omni listener therefore binds to the seat address.
- Omni serves `omnictl` downloads from `./omnictl/` in its working directory and exits at startup when it is missing. The seat container's working directory holds a symlink to the shared directory.
- Omni has no flag for the OIDC client secret, so it lives in `/etc/talos-lab/omni.yaml`. `--auth-auth0-enabled` cannot be turned off once it is on, so it is never set.
- Omni loads its Talos version and extension lists a few seconds after it starts. Creating a media preset before then fails with NotFound, so the seat waits for `talosextensions` of the pinned version.
- Omni serves plain HTTP when it has no certificate, and the tunnel terminates TLS. Talos machines reach the machine API as `grpc://10.88.n.2:8090` and WireGuard on the seat network, so neither is public.
- Cloudflare answers native gRPC with 403, and Cloudflare Tunnel does not carry gRPC on public hostnames. The Omni web UI, the Dex login and `kubectl` through `kubeNN` work through the tunnel, and `omnictl` reaches a seat's Omni over SSH.
- Dex's password login asks for the email address, so students sign in as `studentNN@<zone>`.
- The install ISO is about 350 MB, more than Cloudflare's 100 MB request limit for proxied uploads on the free plan, so the lab stages each seat's ISO in Proxmox instead of students uploading it through `pve`.
- Talos machines register with their seat's Omni about 30 seconds after boot, and a 3-machine cluster is Ready about 4 minutes after the template sync.
- Deleting a cluster while its machines are online returns them to maintenance, so reset deletes the cluster before stopping VMs. When every machine is disconnected, Omni will not remove the last control plane while its cluster exists.
- Omni takes about 4.5 minutes to show a stopped machine as disconnected, so demos and timing use Kubernetes' view.
- A stopped node's Ready condition becomes `Unknown`, not `False`, after about 50 seconds.
- During those 50 seconds the Service still routes to the dead pod, so some requests fail. Failures stop once the node is marked down. Expect 10 to 13 failures from a once-a-second probe with a 3 second timeout.
- Hard-stopping a node within about a minute of pulling an image can leave a damaged copy on its disk. It shows as `exec format error` and `CrashLoopBackOff` once the node returns. Deleting the pod does not help, because the damaged image stays on that node. `kubectl set image` to a different version pulls clean layers.
- `tolerationSeconds: 30` brings replacements up about 80 seconds after the stop. The Kubernetes default is 300 seconds.
- `whenUnsatisfiable: DoNotSchedule` with `nodeTaintsPolicy: Honor` spreads replicas strictly. The replacement can still schedule on the surviving worker, because the dead node's untolerated taint removes it from the calculation.
- Pods do not move back when a worker returns. `kubectl rollout restart` rebalances them, and `matchLabelKeys: pod-template-hash` makes that placement clean.
- `keepalive_timeout 0` in nginx closes each connection, so `cloudflared` reconnects through the Service and traffic reaches both replicas.
- The `preStop` sleep on `hello` keeps a terminating pod serving until it leaves the endpoints, which prevents failed requests during a rollout.
- Cloudflare negative DNS responses last 30 minutes for this zone type. A lookup that happens before a record exists can cause "not found" for that long, so `lab_public_curl` resolves through a public resolver, and seats are created before anyone looks up their names.
- `cf` writes a `.cloudflare/` cache containing account details into the working directory, and it is git-ignored.
- In `jq`, `false // x` returns `x`. Compare booleans explicitly when `false` is a meaningful value.

## Network requirements on a new site

- A Proxmox VE 9 host with root SSH, or a Debian 13 VM to install it on.
- Outbound TCP 443, and outbound UDP and TCP 7844 for `cloudflared`, which has no alternative port.
- KVM inside the Proxmox host, meaning the `vmx` or `svm` flag and `/dev/kvm`, when Proxmox itself runs as a VM.
- About 10 GB of RAM and 6 vCPUs per seat for the Talos VMs, plus about 1 GB per seat for its Omni container.

No inbound ports are needed. Omni's WireGuard and machine API stay on each seat's network, and students reach everything through the tunnel.

`tools/site-check.sh` tests the TCP side of these from a host on the site. It cannot test UDP 7844, because nothing answers a bare UDP probe.
