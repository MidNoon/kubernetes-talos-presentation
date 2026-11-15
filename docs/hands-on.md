# Run a website on your own Kubernetes cluster

By the end of this session you will have a real Kubernetes cluster running a public website. Then you will pull the power on one of its servers and watch the site keep going.

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
- **Cloudflare Tunnel** carries visitors to your site over a connection your cluster opens outward, so nothing has to accept connections from the internet.

## Sign in

**Workspace.** Open your workspace link and enter your password. This guide opens there as the **Lab guide** tab, one step at a time, with a terminal below it. **Run in terminal** runs a command for you, and clicking a value such as a name copies it. The buttons at the top open your Omni, Proxmox and site, and copy your email and password for signing in. Where the lab can see your progress, a status line shows it. The file list on the left holds `README.md` (this guide as one page), the `manifests` folder and `token.txt`.

**Omni.** Open your Omni link. It sends you to a sign-in page, where you enter your email address and password. Omni then shows a card with a **Log In** button and finishes signing you in by itself within a few seconds, so leave the button alone. Omni opens on an empty list of machines.

**Proxmox.** Open the Proxmox link. The realm is already **Lab login**, so click **Login (OpenID redirect)** and sign in with the same email address and password. Proxmox then says **No valid subscription**, so click **OK**. Proxmox VE is free and open source, and a subscription pays for support and its enterprise update repository, which this lab does not need. You see your own resource pool, `seatNN`, and your own storage for install images, `seatNN-iso`, and nothing else.

## Build your install image

A Talos machine joins your Omni because its install image tells it where your Omni is. You build that image in Omni.

In Omni, open **Installation Media** and click **Create New Media**. Step through the wizard:

- **Hardware Type:** Bare-metal Machine. Its description covers generic virtual machines, which is what Proxmox gives you.
- **Talos Version:** 1.14.5. Leave the join token and the HTTP/2 tunnel option as they are.
- **Machine Architecture:** amd64.
- **System Extensions:** search for `qemu-guest-agent` and select `siderolabs/qemu-guest-agent`. Extensions add to Talos what its minimal image leaves out, and this one lets Proxmox see inside the machine, for example its IP address.
- **Extra Args:** nothing, so move on.

On the last page, find **ISO** under **First Boot** and click its **Copy link** button.

The link points at Image Factory, which builds your image when it is first asked for. The image carries your Omni's address and a join token, so anything that boots it joins your Omni and nobody else's.

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

Clone twice more, as `talos-worker-a` and `talos-worker-b`, then start all three. A linked clone shares the template's disk and stores only its own changes, so it is ready in seconds. Each clone still gets its own hardware ID and network address, so Omni sees three different machines.

## Watch your machines appear

<!-- status: machines -->

Go back to **Machines** in Omni. Each machine appears within about a minute of starting, with no login and no configuration from you. The install image did that work.

## Create the cluster

<!-- status: cluster -->

In Omni, go to **Clusters** and click **Create Cluster**:

- Give it a name.
- Select Talos **1.14.5**. Omni offers Kubernetes 1.37.1, but 1.37.2 is out, so select **1.37.2**. Patch releases carry fixes, and keeping up with them is part of running a cluster.
- Under **Available Machines**, click **CP** on one machine to make it the control plane.
- Click **W0** on the other two to make them workers.
- Click **Create Cluster**.

Allow about five minutes. Talos installs itself to each disk and reboots, then Kubernetes starts. The control plane runs Kubernetes itself and the workers run your applications. One control plane is fine for learning, and production clusters use three so that losing one is not an emergency.

## Connect to the cluster

<!-- status: nodes -->

In your workspace terminal, run:

```bash
connect
kubectl get nodes
```

`connect` asks your Omni for access to the cluster you just made. You should see three nodes, all `Ready`.

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

## Break a worker

Give your site at least two minutes after your last deployment before you do this. New container images reach the disk in the background, and cutting the power right after a download can leave a damaged copy behind.

Keep your site open where you can see it, and watch the pods in the terminal:

```bash
kubectl get pods -o wide --watch
```

In Proxmox, select one of your workers and click **Stop**. Use Stop and not Shutdown, because Shutdown lets the machine exit politely. Stop is the same as pulling the power cord.

Here is what to expect:

- **For the first 50 seconds or so**, some squares turn red. Kubernetes doesn't yet know the node is gone, so some requests are still sent to it.
- **At about 50 seconds**, Kubernetes marks the node as not ready and stops sending it traffic. The red squares stop.
- **At about 80 seconds**, replacement pods are running on the surviving worker, and you are back to two replicas.

Press `Ctrl+C` to stop watching, then check the node:

```bash
kubectl get nodes
```

Kubernetes waits before acting because a brief network problem looks exactly like a dead server, and it should not reshuffle everything over a blip. The old pods stay listed as `Terminating` because the machine that would confirm they stopped is switched off.

Nobody logged in to fix anything. You told Kubernetes you wanted two replicas, and it went back to two replicas by itself.

## Bring the worker back

Press **Start** on the worker in Proxmox. It rejoins the cluster in about half a minute.

Look at your site again. It's still all one color, because Kubernetes does not move healthy pods just because a node came back. Rebalance them yourself:

```bash
kubectl rollout restart deployment/hello deployment/cloudflared
kubectl rollout status deployment/hello
kubectl rollout status deployment/cloudflared
```

The second color returns, and this time no squares should turn red. Kubernetes starts each new pod before stopping an old one.

## What you built

You took blank virtual machines to a public, self-healing website, and you never logged in to a server, opened a firewall port or installed an operating system by hand. These are the same tools companies use to run production systems.

Your seat, its Omni and its tunnel are removed after the session. Sidero Omni has a free Hobby plan, so with a free Cloudflare account and a domain of your own you can build the same thing at home on any spare computer. On your own laptop, install [kubectl](https://kubernetes.io/docs/tasks/tools/) and the [oidc-login plugin](https://github.com/int128/kubelogin#getting-started), then use **Download kubeconfig** on your cluster in Omni.
