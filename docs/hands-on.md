# Run a website on your own Kubernetes cluster

By the end of this session you will have a real Kubernetes cluster running a public website. Then you will pull the power on one of its servers, and later upgrade every server, and watch the site keep going both times.

Your machines have no public IP address and no open inbound ports, and there is no SSH anywhere in this setup. They only make outbound connections, and that is a large part of why this approach is safer than it might sound.

## What you have

Your instructor gives you a card for your seat, number `NN`, with an email address, a password, and four links:

| Link | What it is |
| --- | --- |
| `https://shellNN.<class domain>` | Your workspace: this guide, your files and a terminal, in the browser |
| `https://omniNN.<class domain>` | Your own Omni, where your machines and cluster live |
| `https://pve.<class domain>` | Proxmox, where your virtual machines run |
| `https://teamNN.<class domain>` | Your website, once you publish it |

A browser is all you need. Keep each link open in its own tab.

Your password is three groups of four lowercase letters and digits, and you type the dashes too. It never contains `l`, `o`, `0` or `1`.

## The pieces

- **Proxmox** runs virtual machines, standing in for the physical servers you would use elsewhere.
- **Talos Linux** is an operating system built only to run Kubernetes. It has no shell and no SSH, and it is managed entirely through an API.
- **Omni** is a service that manages Talos machines and creates clusters from them. You have your own Omni for this session, and nobody else's machines appear in it.
- **Image Factory** builds Talos install images to order. You build one that knows how to join your Omni.
- **Kubernetes** keeps your applications running and replaces them when something fails.
- The **descheduler** moves running pods back into balance when a failed server returns.
- **Cloudflare Tunnel** carries visitors to your site over a connection your cluster opens outward, so nothing has to accept connections from the internet.

## Sign in

**Workspace.** Open your workspace link and enter your password. This guide opens there as the **Lab guide** tab, one step at a time, with a terminal below it. **Run in terminal** runs a command for you, and clicking a value such as a name copies it. The buttons at the top open your Omni, Proxmox and site, and copy your email and password for signing in. Where the lab can see your progress, a status line shows it. The file list on the left holds `README.md` (this guide as one page), the `manifests` folder and `token.txt`.

**Omni.** Open your Omni link. It sends you to a sign-in page, where you enter your email address and password. Omni then shows a card with a **Log In** button and finishes signing you in by itself within a few seconds, so leave the button alone. Omni opens on an empty list of machines.

**Proxmox.** Open the Proxmox link. The realm is already **Lab login**, so click **Login (OpenID redirect)** and sign in with the same email address and password. Proxmox then says **No valid subscription**, so click **OK**. Proxmox VE is free and open source, and a subscription pays for support and its enterprise update repository, which this lab does not need. You see your own resource pool, `seatNN`, and your own storage for install images, `seatNN-iso`, and nothing else.

## Build your install image

A Talos machine joins your Omni because its install image tells it where your Omni is. You build that image in Omni.

On Omni's home page, click **Download Installation Media** on the right. You can also open **Installation Media** under **Machine Management** on the left. Either way, Omni walks you through a few pages titled **Create New Media**. Click **Next** after each one.

**Hardware Type.** Choose **Bare-metal Machine**. Its description covers generic virtual machines, which is what Proxmox gives you. **Cloud Server** images expect the platform to hand each machine its settings, the way a cloud provider does, and **Single Board Computer** is for boards like the Raspberry Pi. Your machines need neither.

**Choose Talos Linux Version.** Omni shows **1.14.5**, the version it recommends, so keep it. **Automatic** would follow whatever Omni recommends in the future, and picking a number pins it, and today both give you 1.14.5. Later in this session you upgrade your cluster to a newer release while it runs.

On the same page:
- Leave **Tunnel Omni management traffic over HTTP/2** unticked. Your machines reach Omni over WireGuard, which uses UDP. The tunnel is a slower fallback for networks that block UDP, and yours doesn't.
- Keep **Join Token** on **Automatic**. A join token is the secret a new machine presents so that Omni accepts it, and Automatic uses your Omni's default token.
- Leave **Machine User Labels** empty. You label your machines later, once you can tell them apart.

**Machine Architecture.** Choose **amd64**, which covers Intel and AMD processors. **arm64** is for ARM servers. Leave **SecureBoot** unticked, because Secure Boot needs UEFI firmware set up to trust Sidero's signing key, and your machines start with BIOS firmware.

**System Extensions.** Search for `qemu-guest-agent` and select `siderolabs/qemu-guest-agent`. Talos ships with only what Kubernetes needs, and extensions add the rest for particular hardware or platforms. This one lets Proxmox see inside each machine, for example its IP address, and shut it down cleanly.

**Customization.** Leave all three sections as they are:
- **Extra kernel command line arguments** changes how the Linux kernel starts, for example which screen or serial port shows the boot messages.
- **Embedded machine configuration** bakes Talos settings into the image. Omni already embeds what your machines need, as the next page shows.
- **Bootloader** stays on **Auto**, which picks the boot support the image type needs. The ISO it builds starts on your machines' BIOS firmware.

**The last page** shows the result:
- **Schematic Ready** gives your image's schematic ID, a fingerprint of every choice you made. The box below it lists those choices. `SideroLinkConfig` holds your Omni's private address and the join token, and the other two entries send each machine's events and kernel log to your Omni. Your extension is listed at the end.
- **First Boot** offers the same image in several formats. The ISO boots like a CD, disk images suit clouds and VM imports, and PXE boots machines over the network. Right-click the **ISO** link and choose **Copy link address**. Don't click the link itself, because that downloads the whole 370 MB image into your browser.
- **Initial Installation** names the installer image Talos uses when it installs itself to disk, and **PXE Boot with booter** helps network-boot real servers. You need neither here.

Image Factory builds your image the first time anyone asks for that schematic. Anything that boots it joins your Omni and nobody else's.

## Bring the image into Proxmox

In Proxmox, select your storage **seatNN-iso** in the tree on the left and open **ISO Images**. Click **Download from URL**, paste the link and click **Query URL**, which fills in the file name. Click **Download**.

Proxmox fetches the image from Image Factory itself, so the 370 MB file never passes through your browser. It takes a minute or two.

## Make a template

Click **Create VM** at the top right. Change only these settings and leave the rest at their defaults:

| Tab | Setting | Value |
| --- | --- | --- |
| General | Name | `talos-template` |
| General | Resource Pool | `seatNN` |
| OS | Storage, ISO image | `seatNN-iso`, the image you downloaded |
| System | SCSI Controller | VirtIO SCSI |
| System | Qemu Agent | ticked |
| CPU | Cores | 2 |
| Memory | Memory (MiB) | 3072 |
| Memory | Ballooning Device | unticked, shown when you tick **Advanced** at the bottom |
| Network | Bridge | `seatNN` |

On **Confirm**, leave **Start after created** unticked and click **Finish**.

Each of these matters:
- Proxmox lets you create machines only in your own pool.
- The default, VirtIO SCSI single, can hang Talos during bootstrap.
- The Qemu Agent setting pairs with the extension you put in the image.
- A memory balloon stops Talos from seeing all of its memory.
- The bridge `seatNN` is your private network, where your Omni is. Your machines reach Omni there, not through the internet.

Right-click the new machine and choose **Convert to template**. A template never runs. It is the master copy you clone machines from, so all three start out identical.

## Create three machines

Right-click `talos-template` and choose **Clone**. Fill in:

- **Name:** `talos-cp`
- **Mode:** Linked Clone
- **Resource Pool:** `seatNN`

Clone twice more, as `talos-worker-a` and `talos-worker-b`. A linked clone shares the template's disk and stores only its own changes, so it is ready in seconds. Each clone still gets its own hardware ID and network address, so Omni sees three different machines.

Then start each of the three. Select the machine in the tree and click **Start** at the top right. A clone does not start by itself.

## Watch your machines appear

<!-- status: machines -->

Go back to **Machines** in Omni. Each machine appears within about a minute of starting, with no login and no configuration from you. The install image did that work.

Open the **Console** of one machine in Proxmox to see the Talos dashboard. It shows the machine's **UUID** at the top left, its IP address, **SIDEROLINK** with your Omni's address and a tick once it is connected, and the **STAGE**, which is **Maintenance** until the machine joins a cluster. Talos has no login prompt, so the console only shows status and logs.

## Set up your cluster

In Omni, go to **Clusters** and click **Create Cluster**. This page has several sections, and this step covers everything above the list of machines.

**Cluster Name.** Name it `seatNN`.

**Talos Version and Kubernetes Version.** Keep Omni's choices, Talos **1.14.5** and Kubernetes **1.37.1**. Newer patch releases exist, and near the end of this session you upgrade a running cluster to them, which is how clusters stay current in production.

**Config Patches.** A config patch changes the Talos configuration Omni generates. Click **Config Patches**, paste this patch and click **Save**. It applies to every machine in the cluster. This editor holds one patch, so pasting another one here replaces it:

```yaml
apiVersion: v1alpha1
kind: KubeletConfig
config:
  nodeLeaseDurationSeconds: 20
```

Kubernetes normally gives a silent node 50 seconds before it treats the node as down. Until then, it keeps sending requests to pods that no longer exist. This patch makes the kubelet on each node check in every 5 seconds instead of every 10. A second patch, which you add to the control plane in the next step, makes Kubernetes give up on a node after 20 seconds of silence. You see the difference when you break a worker. Production clusters tune these numbers too, trading faster reactions against false alarms on a slow network.

**Cluster Labels.** Leave empty. Labels help you find and group clusters when you run many.

**Cluster Features:**
- Keep **Encrypt Disks** ticked. Talos encrypts each machine's data with a key your Omni holds, so a disk pulled from a machine is unreadable. You cannot change this after the cluster exists.
- Leave **Workload Service Proxying** off. It would publish web services from your cluster through Omni's own address, and you publish through Cloudflare instead.
- Leave **Enable Node Audit Skip** off. Omni deletes Kubernetes nodes that have no matching machine, and this option exempts special virtual nodes. You have none.
- Leave **Control Plane Backups** off. It saves the cluster's database to storage that this lab doesn't provide.
- Keep **Discovery Service** on **Public**. Your nodes use Sidero's discovery service at `discovery.talos.dev` to find each other.

**Machine Sets.** `CP` is the control plane and `W0` is the main worker pool. Both use **Manual** allocation, meaning you pick the machines. **Machine Class** would let Omni pick machines by their labels, which helps once you have dozens.

## Add your machines

<!-- status: cluster -->

Under **Available Machines**, Omni lists your three machines by ID, so first find out which is which. Each ID is the machine's hardware UUID. In Proxmox, open the **Console** of `talos-cp`, and the **UUID** at the top left of the Talos dashboard matches one of the IDs in Omni. **Options**, then **SMBIOS settings (type1)**, shows the same value. In that machine's row, click **new label**, type `talos-cp` and press Enter. Do the same for `talos-worker-a` and `talos-worker-b`. In real deployments, labels like these are how you track which machine is which.

The decision to give up on a silent node belongs to the controller manager, which only the control plane runs, so this patch goes on `talos-cp` alone. A worker given it rejects its whole configuration and never joins. Click the gear in the `talos-cp` row, not **Config Patches** above, paste this patch and click **Save**:

```yaml
apiVersion: v1alpha1
kind: KubeControllerManagerConfig
extraArgs:
  node-monitor-grace-period: 20s
```

Each row also shows what Omni knows about the machine: that it is **available** and **connected**, its Talos version, its platform, and its cores, memory, disk, processor and architecture. **Install Disk** is the disk Talos installs itself to, and **Auto** picks the only disk your machine has. The puzzle icon changes that machine's extensions, and the gear holds config patches for that machine alone, like the one you just added.

Now give the machines their jobs:
- Click **CP** on `talos-cp` to make it the control plane.
- Click **W0** on `talos-worker-a` and `talos-worker-b` to make them workers.
- Click **Create Cluster**.

Allow about five minutes. Talos installs itself to each disk and reboots, then Kubernetes starts. The control plane runs Kubernetes itself, and the workers run your applications. One control plane is fine for learning, and production clusters use three so that losing one is not an emergency.

If a machine rejects its configuration, this step's status names it and gives Omni's reason. **only allowed on control plane machines** means the controller manager patch reached the workers, usually because it replaced the kubelet patch in the cluster's **Config Patches**. In Omni, open your cluster's **Config Patches**, replace that patch with the kubelet patch, and put the controller manager patch on `talos-cp` alone. Start any worker that is stopped in Proxmox. The workers pick up the corrected configuration within a minute or two.

## Connect to the cluster

<!-- status: nodes -->

In your workspace terminal, run:

```bash
connect
kubectl get nodes
```

`connect` is a small helper made for this lab. It asks your Omni for a kubeconfig, the file that tells `kubectl` where your cluster is and how to prove who you are, and saves it as `~/.kube/config`. Outside this lab, you click **Download kubeconfig** on your cluster in Omni instead, and `kubectl` with the `oidc-login` plugin signs you in through your browser.

You should see three nodes, all `Ready`.

## Spread cluster DNS across your nodes

<!-- status: coredns -->

Services inside a cluster find each other through DNS, provided by two CoreDNS pods. They usually start on the same node, because at startup only one node is ready. If that node failed, name lookups in your cluster would stop, so restart them to spread them out:

```bash
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n kube-system rollout status deployment/coredns
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

The `NODE` column should show two different nodes. If it shows the same node twice, run the restart again.

## Deploy your site

<!-- status: site -->

```bash
kubectl apply -f manifests/hello.yaml
kubectl rollout status deployment/hello
kubectl get pods -o wide
```

You should see two `hello` pods on two different workers. Open `manifests/hello.yaml` from the file list and look at what you just deployed:

- The **ConfigMap** holds the web page and the server configuration, so there is no custom image to build.
- The **Deployment** asks for 2 replicas. Its `topologySpreadConstraints` keep them on different workers.
- The **tolerations** tell Kubernetes to replace these pods 30 seconds after a node is marked down. The default is 5 minutes, and 30 seconds suits a demo better.
- The **PodDisruptionBudget** allows only one replica to be taken away on purpose at a time, for example while a machine is drained for an upgrade.
- The **Service** gives both replicas a single stable address.

## Publish it to the internet

<!-- status: publish -->

Your tunnel token is in `token.txt`. Treat it like a password. Store it in the cluster as a Secret, then start the tunnel connectors:

```bash
kubectl create secret generic cloudflared-token --from-literal=token="$(cat token.txt)"
kubectl apply -f manifests/cloudflared.yaml
kubectl rollout status deployment/cloudflared
```

Open your site link. Each square on the page is one request, and each color is the node that answered it. You should see two colors.

Your site is now public, and your cluster still accepts no inbound connections. The `cloudflared` pods connect out to Cloudflare, and visitors' requests come back down those connections.

## Keep replicas balanced

<!-- status: balance -->

Kubernetes places a pod when the pod starts and never moves it afterwards. If a worker dies and comes back, both replicas stay on the survivor until something moves one. The descheduler is that something:

```bash
kubectl apply -f manifests/descheduler.yaml
kubectl -n kube-system rollout status deployment/descheduler
```

Every 15 seconds, it looks for pods that break their own placement rules, like two `hello` replicas on one worker while the other worker is free. It evicts one, and Kubernetes places the replacement where the rules allow. The `PodDisruptionBudget` at the end of `hello.yaml` and `cloudflared.yaml` lets it take away only one replica at a time, so your site always has one left.

## Break a worker

Give your site at least two minutes after your last deployment before you do this. New container images reach the disk in the background, and cutting the power right after a download can leave a damaged copy behind.

Keep your site open where you can see it, and watch the pods:

```bash
kubectl get pods -o wide --watch
```

**Run in terminal** opens this in its own **Watch** terminal next to the main one, so you can keep using the main terminal.

In Proxmox, select one of your workers and click **Stop**. Use Stop and not Shutdown, because Shutdown lets the machine exit politely. Stop is the same as pulling the power cord.

Here is what to expect:

- **For about 20 seconds**, some squares turn red. Kubernetes doesn't yet know the node is gone, so some requests still go to it.
- **At about 20 seconds**, Kubernetes marks the node as not ready and stops sending it traffic. The red squares stop. Without your config patch, this would take 50 seconds.
- **At about a minute**, replacement pods are running on the surviving worker, and you are back to two replicas.

Check the node in the main terminal:

```bash
kubectl get nodes
```

Kubernetes waits before acting because a brief network problem looks exactly like a dead server, and it should not reshuffle everything over a blip. The old pods stay listed as `Terminating` because the machine that would confirm they stopped is switched off.

Nobody logged in to fix anything. You told Kubernetes you wanted two replicas, and it went back to two replicas by itself.

## Bring the worker back

Press **Start** on the worker in Proxmox. It rejoins the cluster in about half a minute.

Watch your site. Within about 30 seconds of the worker returning, the descheduler moves one replica of each deployment back, and the second color returns without any red squares. Kubernetes starts the replacement before the old pod stops serving.

## Upgrade your cluster

<!-- status: upgrade -->

Talos 1.14.6 and Kubernetes 1.37.2 are out, so upgrade your running cluster to them while your site stays up. Keep your site and the **Watch** terminal visible.

**Talos first.** Open your cluster in Omni and update its Talos version. In the **Update Talos** dialog, choose **1.14.6** and confirm. Omni upgrades one machine at a time:
- Kubernetes cordons the machine, so no new pods land on it, and drains it, so its pods move to the other worker before anything stops.
- Talos installs the new version and reboots.
- The machine rejoins, and the descheduler moves a replica back to it.

The control plane goes first. While it reboots, `kubectl` stops answering for a minute or two, but your site keeps serving, because the workers don't need the control plane to keep running their pods. The whole Talos upgrade takes about five minutes.

**Kubernetes next.** When every machine shows Talos 1.14.6, open the **Update Kubernetes** dialog the same way, choose **1.37.2** and confirm. This replaces the Kubernetes components on each machine without rebooting it, and takes about three minutes.

Check the result:

```bash
kubectl get nodes -o wide
```

Every node shows `v1.37.2` and `Talos (v1.14.6)`. Your site shows a red square or two at most over the whole upgrade, usually while the control plane is away. Without a cluster manager, upgrading the operating system and Kubernetes on every machine is a planned outage. Here it is two choices in a dialog.

## What you built

You built an install image, made machines from it in Proxmox, and turned them into a Kubernetes cluster without logging in to any of them. Talos installed itself from your image, and Omni configured it. Your site stayed up through a dead server and through an upgrade of every machine, and nobody had to move anything by hand.

Nothing here is special to this lab:
- Talos Linux and Kubernetes are open source and free. You can run Talos without Omni, using its command-line tool `talosctl` and plain configuration files. Omni makes managing machines and clusters simpler, which is why this session uses it.
- Omni is free to run yourself for non-commercial use, which is how this lab runs it. Sidero Labs also hosts it for you on a paid plan, including a Hobby plan for personal projects.
- Proxmox VE is free and open source.
- Cloudflare Tunnel works on Cloudflare's free plan. It needs a domain whose DNS Cloudflare manages, and a domain costs a yearly fee from a registrar.

A spare computer running Proxmox, or a few old PCs booted straight from a Talos image, can run the same setup at home. Your seat, its Omni and its tunnel are removed after the session.
