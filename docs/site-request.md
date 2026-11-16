# Hosting request: Kubernetes on Talos hands-on lab

## The lab in brief

Each student builds a small Kubernetes cluster from three virtual machines, publishes a website from it, and watches the site survive a failed server and a rolling upgrade. Students need only a laptop with a browser.

Everything runs on one machine at the university: a Proxmox VE host that we install and run. It contains:
- every student's virtual machines, each student on a private network of their own;
- one Omni (the cluster manager) per student, in its own container;
- one browser workspace per student, in its own container.

Students reach all of it through a Cloudflare Tunnel that the host opens outward, so no inbound firewall ports are needed.

## What we ask for

- **One virtual machine**, or a physical server, sized for the number of seats in the table below.
- **Nested virtualization** turned on for that VM, because Proxmox runs virtual machines inside it.
- **An operating system:** Proxmox VE 9 installed from the official ISO, or a minimal Debian 13 that we turn into Proxmox VE 9.
- **Outbound internet access** to the destinations listed under Network, and **no inbound access** from the internet.
- **Remote access for the two of us** to set up and run the host. Our options are under Remote access, in order of preference.
- **Time:** the VM a week before the session, so we can install it and rehearse full runs, until we remove everything after the session.

## Size

One seat is one student, or a pair of students if resources are short. Each seat runs:
- three Talos VMs, each with 2 vCPUs, 3 GB of RAM and a 32 GB thin disk;
- the Omni container, with 2 vCPUs, 1 GB of RAM and a 4 GB disk;
- the workspace container, with 2 vCPUs, 1.5 GB of RAM and an 8 GB disk.

That reserves 11.5 GB of RAM per seat. A running seat measured about 6.5 GB in use, and the host itself needs about 4 GB. vCPUs are shared, and the heaviest load comes when every student creates a cluster at the same moment.

| Seats | RAM, comfortable | RAM, tight | vCPUs | SSD |
| --- | --- | --- | --- | --- |
| 10 | 128 GB | 88 GB | 24 to 32 | 300 GB |
| 15 | 192 GB | 128 GB | 32 to 48 | 450 GB |
| 20 | 256 GB | 168 GB | 48 to 64 | 550 GB |

"Comfortable" gives every seat its full reservation. "Tight" relies on seats using less than they reserve, which our measurements support.

The cluster databases need SSD storage, and disks are thin, so storage is used only as data is written.

## Nested virtualization

The VM must expose the CPU's virtualization extensions:
- **VMware vSphere or ESXi:** in the VM's CPU settings, tick **Expose hardware assisted virtualization to the guest OS**.
- **Hyper-V:** with the VM off, run `Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions $true`.
- **Proxmox VE:** give the VM CPU type `host`, with nested virtualization enabled in the host's KVM module.
- **KVM or libvirt:** use CPU mode `host-passthrough`.

Student VMs reach the network through the host's own address, so the hypervisor needs no promiscuous mode or MAC address spoofing.

## Network

Inbound: nothing from the internet. We need SSH (TCP 22) and the Proxmox web interface (TCP 8006) from the remote access path we agree on.

Outbound, from the VM:

| Purpose | Destinations | Ports |
| --- | --- | --- |
| Cloudflare Tunnel for students' and our access | `region1.v2.argotunnel.com`, `region2.v2.argotunnel.com` | 7844 UDP and TCP |
| Cloudflare tunnel setup | `api.cloudflare.com` | 443 TCP |
| Talos install images | `factory.talos.dev`, `ghcr.io`, `pkg-containers.githubusercontent.com` | 443 TCP |
| Talos cluster discovery | `discovery.talos.dev` | 443 TCP |
| Kubernetes container images | `registry.k8s.io` and the Google `*.pkg.dev` storage it redirects to | 443 TCP |
| Website container images | `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` | 443 TCP |
| Time | `time.cloudflare.com` | 123 UDP |
| Packages, during setup | `deb.debian.org`, `security.debian.org`, `download.proxmox.com` | 80 TCP |
| DNS | the university's resolvers | 53 |

A transparent firewall is easiest. If outbound traffic must go through a web proxy, we need to know, because the tunnel and Talos must be configured for it.

Each seat downloads its own 370 MB install image when the student builds it, plus about 1 to 2 GB of container images over the session. For 20 seats, that is roughly 30 to 50 GB during the session.

Students' laptops need ordinary HTTPS access to Cloudflare and to the lab's domain from the classroom network.

## Remote access

In order of preference:
- **University VPN with SSH.** VPN accounts for two people, and from the VPN, TCP 22 and 8006 to the VM. This uses your standard path and needs nothing extra on the VM.
- **Outbound management tunnel.** If VPN access is not possible, we run a Cloudflare Tunnel on the VM that carries only SSH, behind Cloudflare Access, which requires our sign-in before any connection reaches the VM. It uses the same outbound ports the lab already needs, so nothing new opens.
- **Console only.** Someone on site pastes commands we send. This works for the first steps and is too slow for running the lab.

On the first day, someone with console or root access does two things:
- tells us the VM's address;
- adds our SSH public key, which we send beforehand, to `root`:

```bash
install -d -m 700 /root/.ssh
printf '%s\n' '<our public key>' >>/root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

After that, we do the rest: a network and virtualization check, the Proxmox install if the VM runs Debian, and the lab itself.

## Security and data

- No inbound ports are open to the internet. The host makes only outbound connections.
- Each student gets their own private network, cluster manager, Proxmox resource pool and storage. Omni and Proxmox show each student only their own.
- Logins are issued by the lab for the session, one per seat. No university accounts or student personal data are used.
- Students' VMs reach the internet through the host's address. We can block traffic between student networks, and from student networks to university-internal address ranges you name. Alternatively, the VM can sit on an isolated network segment.
- Student websites appear under a domain we own, through Cloudflare.
- Nothing is kept after the session. We remove every seat, tunnel and DNS record, and the VM can then be deleted.

## Questions for the meeting

- How many students, and can they work in pairs if needed?
- Session date and time, when the VM can be ready, and when it must be gone.
- Which hypervisor, and can nested virtualization be turned on?
- Proxmox VE 9 or Debian 13, and who installs it?
- What RAM, vCPUs and SSD storage are available?
- Is VPN access with SSH to the VM possible? If not, is the outbound management tunnel acceptable?
- Are any outbound ports or destinations blocked, is there a proxy, and which DNS servers should the VM use?
- Static address or DHCP? Is the VM on an isolated segment, or are there internal ranges to block?
- Who has console access on the first day?
- Are there policies or forms for external services, such as Cloudflare and Sidero Labs' Image Factory?
- Who is our contact in IT?
