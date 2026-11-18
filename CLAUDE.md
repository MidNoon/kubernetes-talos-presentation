# Kubernetes on Talos hands-on lab

Automation and teaching material for a university session. Each student gets a seat on one shared Proxmox host:
- their own Omni;
- their own private network;
- a Proxmox pool and a storage of their own for install images;
- a browser workspace with the tools and files, and the guide as a step-by-step panel.

Students build a Talos install image in their Omni, have Proxmox download it, make a VM template from it and clone three Talos VMs, watch them join their Omni, build a cluster of 1 control plane and 2 workers, publish a site through a Cloudflare Tunnel, and watch it survive losing a worker and a rolling upgrade of every machine. They need only a browser, and one email and password sign them in everywhere.

`./lab` builds the host and the seats, and rehearses a student's run on any seat so the whole flow can be built, broken and torn down repeatedly. `docs/hands-on.md` is the student version of the same flow.

## Commands

```bash
./lab access up|down                         # SSH to a site host through a Cloudflare Tunnel behind Access
./lab access serve                           # hand the site host its bootstrap once, as a one-line curl command
./lab access target                          # API token and disk storage on the site's Proxmox, written to .lab/pve-target.env
./lab access verify [SHA256:...]             # record the site host's key on first contact, then check it
./lab access ssh [command...]                # a shell or a command on the site host, without the run lock
./lab campus [ssh|proxmox open|close]        # what the site host's campus network can reach; no argument shows it
./lab campus close|reset                     # close every service to campus, or remove the campus rules
./lab proxmox up|verify|down                 # nested Proxmox VM on the local libvirt host
./lab host up|verify|down                    # shared services on the Proxmox host
./lab seats create <count>|delete            # per-seat network, Omni, ISO storage, workspace, logins, site tunnel
./lab seat <n> up                            # rehearse a student's run: image, template, clones, cluster, the guide's commands
./lab seat <n> failover [worker-a|worker-b]  # hard-stop a worker under a public probe
./lab seat <n> upgrade                       # upgrade Talos, then Kubernetes, under a public probe
./lab seat <n> reset                         # remove every cluster, machine, VM, image and preset, keep the seat
./lab seat <n> delete                        # remove one seat, leave the others running

tools/site-check.sh [host:port ...]          # KVM, gateway, DNS and egress checks on a candidate site host
tests/guards.sh                              # stubbed guard tests, no real services, needs node and unzip
shellcheck -s bash -x -e SC1090,SC1091,SC2034,SC2154,SC2016,SC2317,SC2024,SC2029 lab lib/*.sh tests/guards.sh tools/site-check.sh
```

A full rehearsal is `./lab proxmox up`, `./lab host up`, `./lab seats create 1`, `./lab seat 1 up`, `./lab seat 1 failover`, `./lab seat 1 upgrade`, `./lab seat 1 reset`, `./lab seats delete`, `./lab host down`. Above Proxmox it takes about 30 minutes:

| Step | Time |
| --- | --- |
| `host up` | about 30 seconds |
| `seats create 1` | under a minute |
| `seat 1 up` | 5 to 8 minutes, including the image download |
| `seat 1 failover` | about 3.5 minutes, including the 120 second image wait |
| `seat 1 upgrade` | about 10 minutes: Talos 5.5, Kubernetes 3.3 |
| `seat 1 reset` | under 2 minutes |
| `seats delete` and `host down` | under a minute |

Running `seats create` again leaves running seats untouched, because a seat's Omni restarts only when its configuration changed. A seat's workspace restarts when its unit, password or guide extension changed, which closes the student's terminals. To rehearse while someone uses seat 1, run `./lab seats create 2` and rehearse on seat 2, then `./lab seat 2 delete`.

## Layout

- `lab` dispatches commands and takes the run lock.
- `lib/common.sh` has the Talos and Kubernetes versions a cluster starts on and is upgraded to, logging, config loading, the lock, exit hooks and `lab_public_curl`.
- `lib/pve-api.sh` is the Proxmox REST client, root SSH and SSH forwards, the Cloudflare Access transport, and the guest name guards.
- `lib/cloudflare.sh` is the only path to `cf`, through `cf_query` and its allowlist, plus tunnel and DNS primitives.
- `lib/proxmox-layer.sh` builds the nested Proxmox VM with libvirt.
- `lib/access-layer.sh` builds and removes the SSH path to a site host through Cloudflare Access, and its bootstrap script.
- `lib/campus-layer.sh` controls what the campus network beside a site host can reach on it.
- `lib/host-layer.sh` builds the shared services on the Proxmox host.
- `lib/seats-layer.sh` builds and removes seats. `seat_omnictl` is the only path to a seat's Omni.
- `lib/rehearsal-layer.sh`, `lib/site-layer.sh`, `lib/failover-layer.sh` and `lib/upgrade-layer.sh` play a student's run on a seat. The site layer holds the public probe, timeline and summary that failover and upgrade share.
- `manifests/` holds the Kubernetes manifests students apply unchanged: the site, the tunnel connectors, and the descheduler pinned by digest.
- `patches/` holds the Talos config patches students paste into Omni when they create the cluster: one for every machine, one for the control plane machine. The rehearsal applies the same files, and a guard test keeps the guide's copies identical.
- `workspace/lab-guide/` is the code-server extension behind the workspace's **Lab guide** tab. `extension.js` builds the panel from `~/README.md`, sends commands to the `Lab` terminal, copies values and opens links. `status.js` holds the status checks, and `node status.js` prints them all as JSON. A command with `--watch` or `-w` runs in its own `Watch` terminal beside `Lab`. A step stays ticked once its check passes, even if the check later fails, for example during the failover. `media/` holds the panel's script, styles and icon.
- `docker/pve-assistant/` builds the image that prepares the unattended Proxmox installer.
- `tools/site-check.sh` runs standalone on a Proxmox host or desktop at a candidate site, with no dependency on the rest of the repo.
- `tools/access-bootstrap.sh` runs standalone as root on a site host with our SSH public key and the tunnel connector token as arguments. A guard test keeps its `cloudflared` pin and paths identical to the lab's.
- `docs/site-request.md` is the hosting request to hand a site's IT staff: size per seat count, nested virtualization, outbound destinations, remote access options, security, and questions to settle.

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
- `guide/lab-guide.vsix`, the packed guide extension.
- `access/` holds the site host's SSH key pair and known_hosts in `ssh/`, the Access service token in `service-token.env`, the tunnel connector token, `bootstrap.sh` for the site host, and the control socket `master`. `access down` keeps the key pair.
- `logs/` and `failures/`, which holds the context a failed run saved.

`.lab/pve-target.env` is the interface between Proxmox and everything above it. `./lab proxmox up` writes it for the nested lab, and `./lab access target` writes it for a site host reached through Access. It refuses to replace a target that points at another host. For any other Proxmox, write it by hand with these keys:
- `PVE_URL`, `PVE_NODE`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET` and `PVE_TLS_PIN`.
- `PVE_DISK_STORAGE`, which holds VM disks.
- `PVE_SSH` (`root@host`), `PVE_SSH_KEY` and `PVE_SSH_KNOWN_HOSTS`.
- `PVE_SSH_ACCESS`, optional, the path of `.lab/access/service-token.env`. It sends SSH through Cloudflare Access with `PVE_SSH=root@ssh.<zone>`, the key and known_hosts in `.lab/access/ssh/`, and `PVE_URL=https://127.0.0.1:<port>`. Each run then opens one SSH connection that forwards that port to the host's API on 8006 and reopens it when it drops. Every other SSH call opens its own connection.

The token belongs to `talos-lab@pve`, which has the roles `PVEVMAdmin`, `PVEDatastoreAdmin`, `PVESDNUser` and `PVEPoolAdmin` on `/`. `PVE_TLS_PIN` is the base64 SHA-256 of the server's public key. Root SSH is key-only and checks the host key strictly.

## Safety rules

**Proxmox calls.** With `b = 9000 + 10n`, seat n owns:
- container `b` named `omniNN`;
- container `b + 4` named `workspaceNN`;
- the rehearsal template `b + 9` named `seatNN-template`;
- the rehearsal VMs `b + 1..3` named `seatNN-cp`, `seatNN-worker-a` and `seatNN-worker-b`.

These guests are only started, stopped or deleted when their ID and name both match. Students' own templates and clones have IDs and names they choose, so `seat reset` and `seats delete` remove a VM because it is a member of pool `seatNN`, and never touch anything outside that pool. They remove install images only from the seat's own storage `seatNN-iso`.

**Cloudflare calls.** The `cf` login reaches every zone and tunnel in the account. `cf_assert_allowed` limits writes to the tunnels `talos-lab-host` and `talos-student-NN`, and to CNAME records named `teamNN`, `omniNN`, `kubeNN`, `shellNN`, `auth` and `pve` in the zone. Tunnel and record IDs come only from exact-name lookups. A hostname holding anything other than a tunnel CNAME is refused. `host up`, `host down`, `seats create` and `seats delete` compare every other tunnel and DNS record before and after, and fail on any difference.

The access layer may write only the tunnel `talos-lab-access`, the CNAME `ssh`, and the Access application and service token named `talos-lab-access`. The application must be self-hosted on `ssh.<zone>`. Deletes take only IDs from exact-name lookups. `access up` and `access down` compare every other tunnel, DNS record, Access application and service token before and after. The host layer's own checks treat the access tunnel as someone else's, so `host down` runs while access is up.

**Omni calls.** A seat's Omni is reached only through `seat_omnictl`, with that seat's service account key, over an SSH forward to its container.

**Runs.** `flock` on `.lab/lock` prevents concurrent runs. Each `./lab` invocation loads `lab` and `lib/` fresh, so do not edit them during a multi-command sequence.

**Secrets.** Connector tokens, kubeconfigs, the Proxmox root password and SSH key, Omni service account keys and seat passwords stay in `.lab/` with mode 600. `.lab/host/users.tsv` keeps each seat's password in plain text so it can be handed out, and Dex only receives the bcrypt hash. Passwords are three dash-separated groups of four lowercase letters and digits, without `l`, `o`, `0` or `1`, so they can be typed from a printed card. On the host and in the seat containers, `/etc/talos-lab` and `/var/lib/talos-lab` are root-only. The workspace keeps the seat password in `~/.config/talos-lab/seat.json` with mode 600 for the guide's **Copy password** button. The panel only asks for it by name, and the extension host puts it on the clipboard, so the webview never holds it.

## How the layers work

**Proxmox.** An unattended 9.x install in a libvirt VM with 24 GB RAM, 8 vCPUs and a sparse 200 GB disk. The answer file installs the lab SSH public key for root, and the host key is recorded on first contact after the install. It has its own libvirt network `talos-lab`, bridge `virbr-talos`, subnet `10.77.0.0/24` and storage pool. ufw drops forwarded traffic by default, so the layer adds rules for that bridge only and removes them on teardown.

**Access.** `./lab access up` makes the path to a site host's SSH:
- the tunnel `talos-lab-access`, whose only route is `ssh.<zone>` to `ssh://localhost:22`;
- the service token `talos-lab-access`;
- the self-hosted Access application `talos-lab-access` on `ssh.<zone>`, whose only policy is Service Auth for that token;
- `.lab/access/bootstrap.sh`, which is `tools/access-bootstrap.sh` with the access public key and connector token set. Run as root on the site host, it installs openssh-server and curl when missing, adds the key to root, downloads the pinned `cloudflared` and checks its SHA-256, runs it as `talos-access` from `/usr/local/lib/talos-access` with the connector token in `/etc/talos-access`, and prints the host's ed25519 key fingerprint. Its body is one function called on the last line, so `curl | bash` reads all of it before anything can read stdin.

`./lab access serve` hands that file out once, so nobody types the token at a console. It serves it from this machine through a Cloudflare quick tunnel at a random `trycloudflare.com` address, under a random 16-hex-digit path, with an empty page at `/`. It prints `curl -fsSL <address>/<path> | bash` and stops after the first successful fetch or after an hour. A quick tunnel needs no Cloudflare account resources.

`./lab access verify SHA256:...` connects through `cloudflared access ssh` with the service token and records the host key only if it matches that fingerprint. Later calls check it strictly. `./lab access down` has the host remove its connector, unit and our key 5 seconds later, then deletes the application, token, record and tunnel.

`./lab access target` creates `talos-lab@pve` and its token over SSH, adds the directory storage `lab-disks` at `/var/lib/lab-disks` for VM disks and container root filesystems, so students never see the host's `local` storage, and reads the pin from the live web interface on 8006.

**Campus.** `./lab campus` works only on a target reached through Access, so closing the campus side never cuts off the lab. It loads the nftables table `inet talos_campus` from `/etc/talos-campus.nft` through `talos-campus.service`, before the network comes up at boot. On the uplink, the table drops every new inbound connection except DHCP replies, ping and the services opened: `ssh` (22) and `proxmox` (8006 and the SPICE proxy on 3128). Everything else listening there, such as rpcbind, avahi and the seats' DHCP server, stays closed while the rules exist. The open services are listed in `/etc/talos-campus.open`. Without rules, everything is reachable, so the first change starts from both services open. Each change arms a 2 minute removal of the rules on the host, opens a new SSH connection through Access, and cancels the removal only when it succeeds. `./lab campus reset` removes the rules, and `access down` removes them with the connector.

**Host.** The host layer prepares the Proxmox host:
- It disables the enterprise apt sources, installs dnsmasq, loads the WireGuard module, and turns on IPv4 forwarding through `/etc/sysctl.d/talos-lab.conf`.
- It creates the SDN simple zone `talab` with DHCP, and downloads the Debian 13 container template.
- It puts Omni, the five `omnictl` builds, Dex, cloudflared, `kubectl` and code-server in `/usr/local/lib/talos-lab`. Each is pinned by version and checksum, downloaded locally, and uploaded only when it differs.
- It adds the roles `TalosLabMedia` (`Datastore.Audit` and `Datastore.AllocateTemplate`) and `TalosLabDownload` (`Sys.AccessNetwork`), and the directory `/var/lib/talos-lab/iso` for the seats' install image storages.
- It adds the Proxmox OpenID realm `lab` ("Lab login") as the default realm. That realm signs in through Dex and takes the username from the `name` claim. It also adds `instructor@lab`, who is PVEAuditor and PVEVMAdmin on `/` and so can see and power every seat's VMs.

It runs three systemd services:
- `talos-lab-dex` serves OIDC on `127.0.0.1:5556` with static passwords from `users.tsv`. It has two clients: `omni`, with a redirect URI per seat, and `proxmox`, whose redirect URI is `https://pve.<zone>`.
- `talos-lab-cloudflared` runs the `talos-lab-host` tunnel. That tunnel maps `auth` to Dex and `pve` to Proxmox on 8006. For each seat, it maps `omniNN` and `kubeNN` to the seat's Omni API and Kubernetes proxy, and `shellNN` to its workspace.
- `talos-lab-isolation` loads the nftables table `ip talos_lab` from `/etc/talos-lab/isolation.nft` before guests start. Its forward chain passes traffic from `10.88.0.0/16` to the seat's own subnet, to the resolvers in `host-dns` on port 53, and to the internet. It drops it to every other seat and to `10.0.0.0/8`, `100.64.0.0/10`, `169.254.0.0/16`, `172.16.0.0/12` and `192.168.0.0/16`. Its input chain lets seats reach the host only for DHCP, ping, and replies to connections the host opened. Traffic from anywhere else is untouched.

It installs `/etc/dhcp/dhclient-exit-hooks.d/talos-lab`. When DHCP gives the host an address that differs from its name's entry in `/etc/hosts`, the hook rewrites the entry, then restarts pve-cluster and reloads SDN once pve-cluster runs, so each seat's SNAT uses the new address.

`host verify` checks that the host's name resolves to its current address. It signs in through the public hostnames with the passwords in `users.tsv`, the way a browser does. The instructor signs in to Proxmox. Each seat's student signs in to the workspace, Omni and Proxmox. In Proxmox they must see only their own pool, their disk storage and their own ISO storage, and must be allowed to download into the ISO storage. A rejected password fails the run with the login that rejected it. From each seat's workspace, it probes its own Omni, SSH on the gateway and on the host's main address, the Image Factory, and another seat's Omni when there is one, and resolves a name. Only the seat's own Omni, the Image Factory and the name may get through.

**Seats.** Seat n gets:
- the vnet `seatNN` on `10.88.n.0/24`, with gateway `.1` on the host, SNAT out, DHCP from `.100` to `.199`, and the host's resolver;
- an unprivileged Debian container `omniNN` at `10.88.n.2`, with `/dev/net/tun` passed in and the host's binary directory mounted read-only at `/opt/talos-lab`. It runs one Omni with every listener on `10.88.n.2`, its own account ID and etcd key, `studentNN@<zone>` and `instructor@<zone>` as Admins, and an Admin service account whose key the lab pulls out;
- the empty pool `seatNN`, and the directory storage `seatNN-iso` at `/var/lib/talos-lab/iso/seatNN` for ISOs only;
- a Proxmox user `studentNN@lab` with no Proxmox password. They are PVEVMAdmin and PVEPoolUser on pool `seatNN`, TalosLabMedia on `seatNN-iso`, PVEDatastoreUser on the disk storage, TalosLabDownload on the node, and PVESDNUser on the vnet `seatNN` only;
- the tunnel `talos-student-NN` for `teamNN.<zone>`, which points at the `hello` Service. Its connector token is in `site-token`;
- an unprivileged Debian container `workspaceNN` at `10.88.n.3` that runs code-server as the user `student`, behind the seat password, at `shellNN.<zone>`, in the Dark 2026 theme with AI features and tips off. The home folder holds `README.md`, which is `docs/hands-on.md` with `NN` and `<class domain>` filled in for the seat, `manifests/` and `token.txt`. `kubectl` comes from the shared mount. `omnictl` reaches the seat's Omni directly at `10.88.n.2:8080` with an Operator service account. `connect` writes `~/.kube/config` for the student's cluster, choosing it by itself when there is exactly one;
- the Lab guide extension in that workspace. It opens the **Lab guide** tab and a `Lab` terminal at start. Each `## ` section of the README is a step, a step's `<!-- status: id -->` marker names its check in `status.js`, and the checks poll Omni and the cluster every 10 seconds while the tab is visible. Progress lives in `~/.config/talos-lab/progress.json`. Links to `*.<zone>` open without a confirmation because code-server runs with `--link-protection-trusted-domains`. The lab reinstalls the extension whenever the packed file differs from the one recorded in `~/.config/talos-lab/lab-guide.installed`;
- `sheet.txt`, the card to hand the student, with the email, password and four links.

**Rehearsal.** `./lab seat <n> up` plays the student's run:
- It creates the media preset `talos-lab` in the seat's Omni with the pinned Talos version and the guest agent extension, and builds the Image Factory ISO link the wizard's **Copy link** gives a student.
- It signs in to Proxmox as the seat's student. With that session it has Proxmox download the ISO into `seatNN-iso`, creates `seatNN-template` with the guide's settings and converts it to a template, and clones the template into the seat's three VMs. The lab token then sets the clones' SMBIOS UUIDs to the seat's fixed machine IDs.
- It boots them one at a time and waits for each to register.
- It syncs a cluster template named `seatNN`, which stands in for the student's clicks in Omni, and waits for Ready. The template matches the guide: Omni's default versions, Encrypt Disks on, the cluster patch, and the control plane patch on the first machine.
- It fetches its own 24 hour service-account kubeconfig, which reaches the cluster through `kubeNN`, for verification. `lab_kubectl` uses that kubeconfig, so use it instead of bare `kubectl`.
- It runs the guide's commands as `student` inside the workspace: `connect`, the CoreDNS restart (repeated until the replicas are on two nodes), applying `manifests/hello.yaml`, the Secret from `token.txt`, applying `manifests/cloudflared.yaml`, and applying `manifests/descheduler.yaml`.
- From outside, it verifies that both replicas answer through the API proxy and at `https://teamNN.<zone>`.
- It runs the guide's status checks inside the workspace before anything else, when every check must be waiting, and at the end, when every check but `upgrade` must be done.

`./lab seat <n> reset` returns a seat to the state `seats create` left:
- It deletes every cluster in the seat's Omni while the machines are online.
- It deletes every VM in pool `seatNN`, templates last, every ISO in `seatNN-iso`, every installation media preset, and every link.
- It removes the workspace kubeconfig and the guide's progress.

**Site.** CoreDNS is restarted first, because at bootstrap both replicas land on the one node that is already Ready. `manifests/hello.yaml` is stock nginx configured by a ConfigMap, with a page that polls `/whoami` every second. `hello` and `cloudflared` each have a PodDisruptionBudget of one, and the descheduler evicts a replica that breaks its spread every 15 seconds.

**Failover.** Waits until the newest pod is 120 seconds old, then hard-stops a worker while probing the public URL once a second. It records the timeline, restarts the worker, and waits for the descheduler to spread both deployments again. Runs are saved under the seat's `failover/`.

**Upgrade.** `./lab seat <n> upgrade` needs a cluster on the start versions. Under the same probe, it syncs the cluster template with the newer Talos, waits until every node runs it, Ready and schedulable, and waits for the spread. Then it does the same for Kubernetes and runs every guide check, which must all be done. It records each node's version, readiness and cordon in the timeline. Runs are saved under the seat's `upgrade/`.

## Platform behavior the design depends on

- Omni always creates a WireGuard interface named `siderolink` with the address `fdae:41e4:649b:9303::1/64`, and has no flag to change either. Two Omni instances cannot share a network namespace, so each seat's Omni runs in its own container.
- Omni uses userspace WireGuard, so an unprivileged container needs `/dev/net/tun` passed in (`--dev0 /dev/net/tun`).
- Go treats a `0.0.0.0` bind as dual-stack, which collides with Omni's own listener on the SideroLink address. Every seat Omni listener therefore binds to the seat address.
- Omni serves `omnictl` downloads from `./omnictl/` in its working directory and exits at startup when it is missing. The seat container's working directory holds a symlink to the shared directory.
- Omni has no flag for the OIDC client secret, so it lives in `/etc/talos-lab/omni.yaml`. `--auth-auth0-enabled` cannot be turned off once it is on, so it is never set.
- Omni loads its Talos version and extension lists a few seconds after it starts. Creating installation media before then fails with NotFound, so the seat waits for `talosextensions` of the pinned version.
- Omni's installation media links point at the public Image Factory, `https://factory.talos.dev/image/<schematic>/<version>/metal-amd64.iso`, and need no login. The schematic embeds the seat's SideroLink address and join token, so each seat's image joins only that seat's Omni. `omnictl media download <preset> --format pxe` prints the PXE link, which carries the same schematic ID.
- Omni's media wizard describes Bare-metal Machine as suited to generic virtual machines, and Cloud Server as suited to Proxmox among others. The lab uses and proves Bare-metal Machine.
- Omni serves plain HTTP when it has no certificate, and the tunnel terminates TLS. Talos machines reach the machine API as `grpc://10.88.n.2:8090` and WireGuard on the seat network, so neither is public.
- Cloudflare answers native gRPC with 403, and Cloudflare Tunnel does not carry gRPC on public hostnames. The Omni web UI, the Dex login and `kubectl` through `kubeNN` work through the tunnel. The lab reaches a seat's Omni over SSH, and the workspace reaches it directly on the seat network.
- Dex's password login asks for the email address, so students sign in as `studentNN@<zone>`.
- The Proxmox OpenID login sends the browser's origin as the redirect URI, so the Dex `proxmox` client allows exactly `https://pve.<zone>`.
- Dex static passwords produce no `preferred_username` claim, so the Proxmox realm reads `name`, which Dex fills from the static password's `username`. `username-claim` is set only when a realm is created, and `pveum realm modify` rejects it.
- The Proxmox clone dialog offers only pools the user has `Pool.Audit` on, and a student without `VM.Allocate` outside their pool cannot clone without choosing it.
- Proxmox's **Download from URL** needs `Datastore.AllocateTemplate` on the storage and `Sys.AccessNetwork` on the node, and the GUI shows the button only then. `Sys.AccessNetwork` allows nothing else, so students get it on the node through `TalosLabDownload`.
- The Proxmox create wizard defaults to SeaBIOS, the i440fx machine, CPU type `x86-64-v2-AES`, VirtIO SCSI single, a 32 GB disk, 2 GB with ballooning, and a firewalled VirtIO NIC. Talos runs on those defaults once the controller, guest agent, cores, memory, ballooning and bridge are changed as the guide lists. IO thread turns off by itself when the controller is VirtIO SCSI before the Disks tab is reached.
- A Proxmox task's status is readable by its owner or with `Sys.Audit` on the node, so the rehearsal waits for a student's download, VM creation and clones through the student's session.
- After the Dex login, Omni's Authenticate UI Access page registers and confirms a browser key by itself, then loads the main view. Its **Log In** button stays enabled during that load. A click there registers a second key, fails to confirm it because the token has left the URL, and stores it anyway, because the confirm step reports the earlier success. Omni then answers 401 to that key and the browser returns to the sign-in page. The guide tells students to leave the button alone.
- Omni's media wizard recommends Talos 1.14.5 and its cluster wizard defaults to Talos 1.14.5 and Kubernetes 1.37.1. Omni also offers Talos 1.14.6 and Kubernetes 1.37.2, so students keep the defaults and upgrade to the newer patches later.
- Talos 1.14 configures the kubelet and the controller manager in separate documents, `KubeletConfig` and `KubeControllerManagerConfig`, and Omni generates them. A patch that sets `.machine.kubelet` or `.cluster.controllerManager` fails with `already set in v1alpha1 config`, and the machines stay in maintenance with no error in the cluster status. Only control plane machines get a `KubeControllerManagerConfig`, so that patch goes on the control plane machine. A worker given it rejects its whole configuration with `the following document kinds are only allowed on control plane machines` and stays in maintenance. Omni records that in the machine's `clustermachinestatuses` as `lastconfigerror`, and the guide's `cluster` check shows it with the machine's label.
- The Create Cluster page's **Config Patches** editor holds one cluster patch, so pasting the control plane patch there replaces the kubelet patch and sends the controller manager patch to every machine.
- Omni's Create Cluster ticks Encrypt Disks by default, and it cannot change after creation.
- The Talos console dashboard shows the machine's UUID at the top left. It equals the VM's SMBIOS UUID and the machine ID in Omni, which is how students tell machines apart.
- Omni upgrades Talos one machine at a time, control plane first. Talos cordons and drains each machine before it reboots, so its pods move first. The control plane's reboot leaves `kubectl` unanswered for about two minutes. The rehearsal's Talos upgrade took 5.5 minutes, and Kubernetes took 3.3 minutes without reboots. 3 of 452 probe requests failed across both.
- Omni's Operator role cannot read identities. Checks made as the workspace's Operator service account list clusters instead.
- `bridge-nf-call-iptables` is 0 on the host, so traffic within a seat's subnet is bridged and never reaches the `ip` forward hook. The isolation table still accepts each seat's own subnet, so turning bridge netfilter on does not cut a seat off from itself.
- A Proxmox clone gets a new SMBIOS UUID and MAC address, so three clones of one template register as three distinct Talos machines.
- A Talos control plane runs this lab's 3-node cluster in 3 GB, so all three VMs share the template's size.
- code-server installs extensions only from a VSIX file or Open VSX. `seat_build_guide` zips `workspace/lab-guide/` into a VSIX with fixed timestamps, so an unchanged extension packs to the same checksum.
- `install -d -o user` gives the owner only to the last folder it creates. code-server cannot create `Machine`, `logs` or `extensions` under a root-owned `~/.local/share/code-server`, so the workspace lists every level explicitly.
- VS Code revives persistent terminal sessions a few seconds after extensions start, so the guide's own `Lab` terminal would appear twice. The workspace turns `terminal.integrated.enablePersistentSessions` off.
- Extensions render markdown through the built-in `markdown.api.render` command, which the guide uses for each step.
- Code-server answers `/healthz` without a login, which is how `host verify` checks each workspace through the tunnel. It answers a wrong password with the same redirect as a right one, and only a right one sets `code-server-session`.
- The install ISO is about 370 MB, more than Cloudflare's 100 MB request limit for proxied uploads on the free plan, so students never upload it through `pve`. Proxmox downloads it from Image Factory instead.
- Talos machines register with their seat's Omni about 30 seconds after boot, and a 3-machine cluster is Ready about 4 minutes after the template sync.
- Deleting a cluster while its machines are online returns them to maintenance, so reset deletes the cluster before stopping VMs. When every machine is disconnected, Omni will not remove the last control plane while its cluster exists.
- Omni takes about 4.5 minutes to show a stopped machine as disconnected, so demos and timing use Kubernetes' view.
- A stopped node's Ready condition becomes `Unknown`, not `False`. With the guide's patches, a 20 second node lease and a 20 second `node-monitor-grace-period`, that takes about 21 seconds instead of about 50.
- Until then the Service still routes to the dead pod, so some requests fail. Failures stop once the node is marked down. The rehearsal saw 3 failures from a once-a-second probe with a 3 second timeout, against 10 to 13 without the patches.
- Hard-stopping a node within about a minute of pulling an image can leave a damaged copy on its disk. It shows as `exec format error` and `CrashLoopBackOff` once the node returns. Deleting the pod does not help, because the damaged image stays on that node. `kubectl set image` to a different version pulls clean layers.
- `tolerationSeconds: 30` brings replacements up about 60 seconds after the stop. The Kubernetes default is 300 seconds.
- `whenUnsatisfiable: DoNotSchedule` with `nodeTaintsPolicy: Honor` spreads replicas strictly. The replacement can still schedule on the surviving worker, because the dead node's untolerated taint removes it from the calculation.
- Pods do not move back when a worker returns. The descheduler's `RemovePodsViolatingTopologySpreadConstraint` evicts one replica within its 15 second interval, about 20 seconds after the node is Ready, and the PodDisruptionBudget keeps it to one replica at a time. A cordoned or tainted node does not count toward the spread, so the descheduler leaves replicas alone while a node is down or draining.
- `keepalive_timeout 0` in nginx closes each connection, so `cloudflared` reconnects through the Service and traffic reaches both replicas.
- The `preStop` sleep on `hello` keeps a terminating pod serving until it leaves the endpoints, which prevents failed requests during a rollout.
- Cloudflare negative DNS responses last 30 minutes for this zone type. A lookup that happens before a record exists can cause "not found" for that long, so `lab_public_curl` resolves through a public resolver, and seats are created before anyone looks up their names.
- `cf` writes a `.cloudflare/` cache containing account details into the working directory, and it is git-ignored.
- `cloudflared access ssh` reads the service token from `TUNNEL_SERVICE_TOKEN_ID` and `TUNNEL_SERVICE_TOKEN_SECRET`, so the secret stays off the command line. Access asks for a browser login unless the policy's decision is Service Auth (`non_identity`). With only that policy, a request without the token, or with a wrong one, gets 403 before it reaches the tunnel. The service token's secret is shown only when it is created, so `access up` replaces a token whose secret is not in `.lab/access/`.
- `ssh -S` replaces an earlier `-o ControlPath`, so a seat's Omni forward keeps its own control socket while other SSH calls share the access connection.
- A new SSH connection through Cloudflare Access takes about a second. A long-lived one can drop, and a command running over a shared connection that drops ends with exit 255 and no message, with no way to tell whether it finished. So only the API forward is long-lived. `pve_ssh` retries a call that failed before its session started, and names the command when it ends with exit 255 otherwise.
- In `jq`, `false // x` returns `x`. Compare booleans explicitly when `false` is a meaningful value.
- Proxmox VE 9 goes on Debian 13 as the Proxmox wiki describes: hostname resolving to the real address in `/etc/hosts`, the no-subscription repository with the trixie keyring, `proxmox-default-kernel` and a reboot, then `proxmox-ve postfix open-iscsi chrony`, then removing the Debian kernels and `os-prober`. The install adds `pve-enterprise.sources`, which fails without a subscription until it is disabled.
- On Proxmox, ifupdown2 runs `dhclient` for an `inet dhcp` interface, and Debian's AppArmor profile for `dhclient` blocks its unix sockets under the Proxmox kernel, so it exits at once. Disabling that profile through `/etc/apparmor.d/disable/sbin.dhclient` fixes it. Until then, an address left by NetworkManager hides the problem until its lease runs out.
- Proxmox VE installed from its ISO forwards IPv4, and Proxmox VE installed on Debian does not. An SDN vnet's `ip-forward on` covers only the vnet's own interface, so without `net.ipv4.ip_forward` a seat's packets leave through SNAT and the replies coming in on the uplink are dropped.
- dhclient-script sources each file in `/etc/dhcp/dhclient-exit-hooks.d` with `/bin/sh` after it configures the interface, so a hook is POSIX shell that returns instead of exiting.
- Proxmox SDN writes each SNAT rule with the uplink's address at the time of the last SDN apply, so the rule needs a reload when DHCP changes the address.
- `pvenetcommit` moves a pending `/etc/network/interfaces.new` over `/etc/network/interfaces` at boot, so a hand edit of `interfaces` is lost when a pending file exists.
- Debian's NetworkManager lets go of interfaces listed in `/etc/network/interfaces` because of `[ifupdown] managed=false`. On a Debian site host with a desktop, NetworkManager is masked rather than removed, because removing it removes the `gnome` metapackage.
- A `$(...)` subshell that calls `lab_on_exit` sets its own EXIT trap and holds a copy of the parent's hooks, so each hook records the process that registered it and runs only when that process exits. Otherwise the first `seat_omnictl` in a subshell would close the run's shared access connection.

## Looking at the guide panel locally

Run the pinned code-server from `.lab/host/bin/code-server.tar.gz` on `127.0.0.1` with `--auth none`, a test home holding a seat's `README.md` and a `seat.json` with a placeholder password, and the packed VSIX installed. Start it under `env -i` with fake `omnictl` and `kubectl` first in `PATH`, and pass `--user-data-dir` and `--extensions-dir` inside the test home. Otherwise code-server writes into `$XDG_DATA_HOME`, and the panel's terminal inherits `KUBECONFIG` and reaches whatever cluster your shell uses.

## Network requirements on a new site

- A Proxmox VE 9 host with root SSH, or a Debian 13 VM to install it on. `access up` and the site host's `bootstrap.sh` give root SSH through Cloudflare when there is no VPN.
- An upstream IPv4 nameserver first in the host's `/etc/resolv.conf`. Seats get it over DHCP, so a loopback resolver such as systemd-resolved's `127.0.0.53` fails `host up`.
- Outbound TCP 443, outbound UDP and TCP 7844 for `cloudflared`, which has no alternative port, outbound UDP 123 to `time.cloudflare.com` for Talos, and outbound TCP 80 to the Debian and Proxmox package mirrors, which apt uses over HTTP. The bootstrap downloads `cloudflared` from `github.com`, which redirects to `release-assets.githubusercontent.com`.
- KVM inside the Proxmox host, meaning the `vmx` or `svm` flag and `/dev/kvm`, when Proxmox itself runs as a VM.
- Per seat, about 9 GB of RAM and 6 vCPUs for the Talos VMs, about 1 GB for the Omni container, and about 1.5 GB for the workspace. Each seat's disks are thin: 96 GB of VM disks, of which Talos fills a few GB, plus 12 GB for the two containers.
- Per seat, one download of about 370 MB from `factory.talos.dev` while students build their images, about 7.5 GB for 20 seats if they all do it at once. The image lands in `/var/lib/talos-lab/iso` on the host's root filesystem.

No inbound ports are needed. Omni's WireGuard and machine API stay on each seat's network, and students reach everything through the tunnel.

`tools/site-check.sh` tests the TCP side of these from a host on the site. It cannot test UDP 7844, because nothing answers a bare UDP probe.
