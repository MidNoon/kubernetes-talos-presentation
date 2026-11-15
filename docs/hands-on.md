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
- **Image Factory** builds Talos install images to order. Your install image already knows how to join your Omni.
- **Kubernetes** keeps your applications running and replaces them when something fails.
- **Cloudflare Tunnel** carries visitors to your site over a connection your cluster opens outward, so nothing has to accept connections from the internet.

## Sign in

**Workspace.** Open your workspace link and enter your password. This guide opens there as `README.md`. The file list on the left holds the `manifests` folder and `token.txt`. Open a terminal from the menu with **Terminal**, then **New Terminal**.

**Omni.** Open your Omni link. It sends you to a sign-in page, where you enter your email address and password. Omni opens on an empty list of machines.

**Proxmox.** Open the Proxmox link. The realm is already **Lab login**, so click **Login (OpenID redirect)** and sign in with the same email address and password. You see your own resource pool, `seatNN`, and nothing else.

## Create three machines

Your pool holds `seatNN-template`, a virtual machine template that is already set up for Talos. It boots your install image, `seatNN-talos.iso`, which Image Factory built for your Omni. It sits on your own network, `seatNN`, where your Omni can see it.

Right-click the template and choose **Clone**. Fill in:

- **Name:** `talos-cp`
- **Mode:** Linked Clone
- **Resource Pool:** `seatNN`

Proxmox refuses a clone outside your pool, so the pool matters. Clone twice more, as `talos-worker-a` and `talos-worker-b`, then start all three.

To see what the template is made of, select it and open **Hardware**. Two settings matter more than they look:
- The SCSI controller is **VirtIO SCSI**, because VirtIO SCSI single can hang Talos during bootstrap.
- **Ballooning** is off, because a memory balloon stops Talos from seeing all of its memory.

## Watch your machines appear

Go back to **Machines** in Omni. Each machine appears within about a minute of starting, with no login and no configuration from you. The install image did that work.

## Create the cluster

In Omni, go to **Clusters** and click **Create Cluster**:

- Give it a name.
- Select Talos **1.14.5** and Kubernetes **1.37.2**.
- Under **Available Machines**, click **CP** on one machine to make it the control plane.
- Click **W0** on the other two to make them workers.
- Click **Create Cluster**.

Allow about five minutes. Talos installs itself to each disk and reboots, then Kubernetes starts. The control plane runs Kubernetes itself and the workers run your applications. One control plane is fine for learning, and production clusters use three so that losing one is not an emergency.

## Connect to the cluster

In your workspace terminal, run:

```bash
connect
kubectl get nodes
```

`connect` asks your Omni for access to the cluster you just made. You should see three nodes, all `Ready`.

## Spread cluster DNS across your nodes

Services inside a cluster find each other through DNS, provided by two CoreDNS pods. They usually start on the same node, because at startup only one node is ready. If that node failed, name lookups in your cluster would stop, so restart them to spread them out:

```bash
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n kube-system rollout status deployment/coredns
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

The `NODE` column should show two different nodes. If it shows the same node twice, run the restart again.

## Deploy your site

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
