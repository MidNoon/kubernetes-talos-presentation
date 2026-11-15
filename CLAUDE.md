# Kubernetes on Talos hands-on lab

Automation and teaching material for a university session. Each student gets a seat on one shared Proxmox host:
- their own Omni;
- their own private network;
- a Proxmox pool with a ready VM template;
- a browser workspace with the tools, files and guide.

Students clone three Talos VMs from the template, watch them join their Omni, build a cluster of 1 control plane and 2 workers, publish a site through a Cloudflare Tunnel, and watch it survive losing a worker. They need only a browser, and one email and password sign them in everywhere.

`./lab` builds the host and the seats, and rehearses a student's run on any seat so the whole flow can be built, broken and torn down repeatedly. `docs/hands-on.md` is the student version of the same flow.

## Commands

```bash
./lab proxmox up|verify|down                 # nested Proxmox VM on the local libvirt host
./lab host up|verify|down                    # shared services on the Proxmox host
./lab seats create <count>|delete            # per-seat network, Omni, template, workspace, logins, site tunnel
./lab seat <n> up                            # rehearse a student's run: clones, cluster, the guide's commands
./lab seat <n> failover [worker-a|worker-b]  # hard-stop a worker under a public probe
./lab seat <n> reset                         # remove every cluster, machine and cloned VM, keep the seat

tools/site-check.sh [host:port ...]          # KVM, gateway, DNS and egress checks on a candidate site host
tests/guards.sh                              # stubbed guard tests, no real services
shellcheck -s bash -x -e SC1090,SC1091,SC2034,SC2154,SC2016,SC2317,SC2024,SC2029 lab lib/*.sh tests/guards.sh tools/site-check.sh
```

A full rehearsal is `./lab proxmox up`, `./lab host up`, `./lab seats create 1`, `./lab seat 1 up`, `./lab seat 1 failover`, `./lab seat 1 reset`, `./lab seats delete`, `./lab host down`. Above Proxmox it takes about 15 minutes:

| Step | Time |
| --- | --- |
| `host up` | about 30 seconds |
| `seats create 1` | about 2 minutes, mostly downloading the seat's ISO |
| `seat 1 up` | about 7 minutes |
| `seat 1 failover` | about 4.5 minutes, including the 120 second image wait |
| `seat 1 reset` | under 2 minutes |
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
- `host/` holds the downloaded binaries, the Dex client secrets for Omni and Proxmox, `users.tsv`, the host resolver in `host-dns`, and the host tunnel token.
- `seats/seatNN/` holds the seat's Omni account ID and etcd key, and its Admin and workspace Operator service account keys. It also holds the site tunnel token, `sheet.txt` (the card to hand the student), and the rehearsal kubeconfig, cluster template and failover runs.
- `logs/` and `failures/`, which holds the context a failed run saved.

`.lab/pve-target.env` is the interface between Proxmox and everything above it. `./lab proxmox up` writes it for the nested lab. For another Proxmox, write it by hand with these keys:
- `PVE_URL`, `PVE_NODE`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET` and `PVE_TLS_PIN`.
- `PVE_ISO_STORAGE` and `PVE_DISK_STORAGE`.
- `PVE_SSH` (`root@host`), `PVE_SSH_KEY` and `PVE_SSH_KNOWN_HOSTS`.

The token needs the roles `PVEVMAdmin`, `PVEDatastoreAdmin`, `PVESDNUser` and `PVEPoolAdmin`. `PVE_TLS_PIN` is the base64 SHA-256 of the server's public key. Root SSH is key-only and checks the host key strictly.

## Safety rules

**Proxmox calls.** With `b = 9000 + 10n`, seat n owns:
- container `b` named `omniNN`;
- container `b + 4` named `workspaceNN`;
- the template `b + 9` named `seatNN-template`;
- the rehearsal VMs `b + 1..3` named `seatNN-cp`, `seatNN-worker-a` and `seatNN-worker-b`.

These guests are only started, stopped or deleted when their ID and name both match. Students' own clones have IDs and names they choose, so `seat reset` and `seats delete` remove a VM because it is a member of pool `seatNN`, and never touch anything outside that pool.

**Cloudflare calls.** The `cf` login reaches every zone and tunnel in the account. `cf_assert_allowed` limits writes to the tunnels `talos-lab-host` and `talos-student-NN`, and to CNAME records named `teamNN`, `omniNN`, `kubeNN`, `shellNN`, `auth` and `pve` in the zone. Tunnel and record IDs come only from exact-name lookups. A hostname holding anything other than a tunnel CNAME is refused. `host up`, `host down`, `seats create` and `seats delete` compare every other tunnel and DNS record before and after, and fail on any difference.

**Omni calls.** A seat's Omni is reached only through `seat_omnictl`, with that seat's service account key, over an SSH forward to its container.

**Runs.** `flock` on `.lab/lock` prevents concurrent runs. Each `./lab` invocation loads `lab` and `lib/` fresh, so do not edit them during a multi-command sequence.

**Secrets.** Connector tokens, kubeconfigs, the Proxmox root password and SSH key, Omni service account keys and seat passwords stay in `.lab/` with mode 600. `.lab/host/users.tsv` keeps each seat's password in plain text so it can be handed out, and Dex only receives the bcrypt hash. On the host and in the seat containers, `/etc/talos-lab` and `/var/lib/talos-lab` are root-only.

## How the layers work

**Proxmox.** An unattended 9.x install in a libvirt VM with 24 GB RAM, 8 vCPUs and a sparse 200 GB disk. The answer file installs the lab SSH public key for root, and the host key is recorded on first contact after the install. It has its own libvirt network `talos-lab`, bridge `virbr-talos`, subnet `10.77.0.0/24` and storage pool. ufw drops forwarded traffic by default, so the layer adds rules for that bridge only and removes them on teardown.

**Host.** The host layer prepares the Proxmox host:
- It disables the enterprise apt sources, installs dnsmasq, and loads the WireGuard module.
- It creates the SDN simple zone `talab` with DHCP, and downloads the Debian 13 container template.
- It puts Omni, the five `omnictl` builds, Dex, cloudflared, `kubectl` and code-server in `/usr/local/lib/talos-lab`. Each is pinned by version and checksum, downloaded locally, and uploaded only when it differs.
- It adds the Proxmox OpenID realm `lab` ("Lab login") as the default realm. That realm signs in through Dex and uses the `username` claim. It also adds `instructor@lab`, who is PVEAuditor and PVEVMAdmin on `/` and so can see and power every seat's VMs.

It runs two systemd services:
- `talos-lab-dex` serves OIDC on `127.0.0.1:5556` with static passwords from `users.tsv`. It has two clients: `omni`, with a redirect URI per seat, and `proxmox`, whose redirect URI is `https://pve.<zone>`.
- `talos-lab-cloudflared` runs the `talos-lab-host` tunnel. That tunnel maps `auth` to Dex and `pve` to Proxmox on 8006. For each seat, it maps `omniNN` and `kubeNN` to the seat's Omni API and Kubernetes proxy, and `shellNN` to its workspace.

`host verify` asks Proxmox for an OpenID login URL and checks that Dex accepts it, so the Proxmox login is proven without a password.

**Seats.** Seat n gets:
- the vnet `seatNN` on `10.88.n.0/24`, with gateway `.1` on the host, SNAT out, DHCP from `.100` to `.199`, and the host's resolver;
- an unprivileged Debian container `omniNN` at `10.88.n.2`, with `/dev/net/tun` passed in and the host's binary directory mounted read-only at `/opt/talos-lab`. It runs one Omni with every listener on `10.88.n.2`, its own account ID and etcd key, `studentNN@<zone>` and `instructor@<zone>` as Admins, and an Admin service account whose key the lab pulls out;
- a media preset `talos-lab` in that Omni, with the pinned Talos version and the guest agent extension. Its ISO is uploaded to Proxmox as `seatNN-talos.iso`;
- the pool `seatNN` holding `seatNN-template`, a VM template that boots that ISO on vnet `seatNN`. The template uses q35, OVMF with pre-enrolled keys off, CPU type `host`, 2 cores, 3 GB without ballooning, VirtIO SCSI (`virtio-scsi-pci`), a 32 GB write-through discard disk, the guest agent, and boot order disk then ISO;
- a Proxmox user `studentNN@lab` with no Proxmox password, who is PVEVMAdmin on pool `seatNN`, can use both storages, and can use only the vnet `seatNN`;
- the tunnel `talos-student-NN` for `teamNN.<zone>`, which points at the `hello` Service. Its connector token is in `site-token`;
- an unprivileged Debian container `workspaceNN` at `10.88.n.3` that runs code-server as the user `student`, behind the seat password, at `shellNN.<zone>`. The home folder holds the student guide as `README.md` (code-server opens it at start), `manifests/` and `token.txt`. `kubectl` comes from the shared mount. `omnictl` reaches the seat's Omni directly at `10.88.n.2:8080` with an Operator service account. `connect` writes `~/.kube/config` for the student's cluster, choosing it by itself when there is exactly one;
- `sheet.txt`, the card to hand the student, with the email, password and four links.

**Rehearsal.** `./lab seat <n> up` plays the student's run:
- It clones the template into the seat's three VMs and sets their SMBIOS UUIDs to the seat's fixed machine IDs.
- It boots them one at a time and waits for each to register.
- It syncs a cluster template named `seatNN`, which stands in for the student's clicks in Omni, and waits for Ready.
- It fetches its own 24 hour service-account kubeconfig, which reaches the cluster through `kubeNN`, for verification. `lab_kubectl` uses that kubeconfig, so use it instead of bare `kubectl`.
- It runs the guide's commands as `student` inside the workspace: `connect`, the CoreDNS restart (repeated until the replicas are on two nodes), applying `manifests/hello.yaml`, the Secret from `token.txt`, and applying `manifests/cloudflared.yaml`.
- From outside, it verifies that both replicas answer through the API proxy and at `https://teamNN.<zone>`.

`./lab seat <n> reset` returns a seat to the state `seats create` left:
- It deletes every cluster in the seat's Omni while the machines are online.
- It deletes every VM in pool `seatNN` except the template, and every link.
- It removes the workspace kubeconfig.

**Site.** CoreDNS is restarted first, because at bootstrap both replicas land on the one node that is already Ready. `manifests/hello.yaml` is stock nginx configured by a ConfigMap, with a page that polls `/whoami` every second.

**Failover.** Waits until the newest pod is 120 seconds old, then hard-stops a worker while probing the public URL once a second. It records the timeline, restarts the worker, and rolls both deployments to rebalance. Runs are saved under the seat's `failover/`.

## Platform behavior the design depends on

- Omni always creates a WireGuard interface named `siderolink` with the address `fdae:41e4:649b:9303::1/64`, and has no flag to change either. Two Omni instances cannot share a network namespace, so each seat's Omni runs in its own container.
- Omni uses userspace WireGuard, so an unprivileged container needs `/dev/net/tun` passed in (`--dev0 /dev/net/tun`).
- Go treats a `0.0.0.0` bind as dual-stack, which collides with Omni's own listener on the SideroLink address. Every seat Omni listener therefore binds to the seat address.
- Omni serves `omnictl` downloads from `./omnictl/` in its working directory and exits at startup when it is missing. The seat container's working directory holds a symlink to the shared directory.
- Omni has no flag for the OIDC client secret, so it lives in `/etc/talos-lab/omni.yaml`. `--auth-auth0-enabled` cannot be turned off once it is on, so it is never set.
- Omni loads its Talos version and extension lists a few seconds after it starts. Creating a media preset before then fails with NotFound, so the seat waits for `talosextensions` of the pinned version.
- Omni serves plain HTTP when it has no certificate, and the tunnel terminates TLS. Talos machines reach the machine API as `grpc://10.88.n.2:8090` and WireGuard on the seat network, so neither is public.
- Cloudflare answers native gRPC with 403, and Cloudflare Tunnel does not carry gRPC on public hostnames. The Omni web UI, the Dex login and `kubectl` through `kubeNN` work through the tunnel. The lab reaches a seat's Omni over SSH, and the workspace reaches it directly on the seat network.
- Dex's password login asks for the email address, so students sign in as `studentNN@<zone>`.
- The Proxmox OpenID login sends the browser's origin as the redirect URI, so the Dex `proxmox` client allows exactly `https://pve.<zone>`.
- Omni's Operator role cannot read identities. Checks made as the workspace's Operator service account list clusters instead.
- A Proxmox clone gets a new SMBIOS UUID and MAC address, so three clones of one template register as three distinct Talos machines.
- A Talos control plane runs this lab's 3-node cluster in 3 GB, so all three VMs share the template's size.
- Code-server answers `/healthz` without a login, which is how `host verify` checks each workspace through the tunnel.
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
- Per seat, about 9 GB of RAM and 6 vCPUs for the Talos VMs, about 1 GB for the Omni container, and about 1.5 GB for the workspace. Each seat's disks are thin: 96 GB of VM disks, of which Talos fills a few GB, plus 12 GB for the two containers.

No inbound ports are needed. Omni's WireGuard and machine API stay on each seat's network, and students reach everything through the tunnel.

`tools/site-check.sh` tests the TCP side of these from a host on the site. It cannot test UDP 7844, because nothing answers a bare UDP probe.
