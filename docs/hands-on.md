# Run a website on your own Kubernetes cluster

By the end of this session you will have a real Kubernetes cluster running a public website. Then you will pull the power on one of its servers and watch the site keep going.

Your machines have no public IP address and no open inbound ports, and there is no SSH anywhere in this setup. They only make outbound connections, and that is a large part of why this approach is safer than it might sound.

## What you need

Your instructor gives you:

- A login for the Proxmox server.
- A tunnel token, which is a long string of characters. Treat it like a password.
- Your site address, in the form `https://teamNN.<class domain>`.
- The `manifests` folder containing `hello.yaml` and `cloudflared.yaml`.

Set these up before the session:

- An account at [Sidero Omni](https://siderolabs.com/omni-signup). Three machines fit within the free Hobby plan.
- [kubectl](https://kubernetes.io/docs/tasks/tools/).
- The `oidc-login` plugin for kubectl. On macOS or Linux, run `brew tap siderolabs/tap`, `brew trust siderolabs/tap` and `brew install siderolabs/tap/sidero-tools`. On Windows, follow the [kubelogin guide](https://github.com/int128/kubelogin#getting-started).

Confirm both tools work:

```bash
kubectl version --client
kubectl oidc-login --version
```

## The pieces

- **Proxmox** runs virtual machines, standing in for the physical servers you would use elsewhere.
- **Talos Linux** is an operating system built only to run Kubernetes. It has no shell and no SSH, and it is managed entirely through an API.
- **Omni** is a web service that manages Talos machines and creates clusters from them.
- **Image Factory** builds Talos install images to order. The image you download already knows how to join your Omni account.
- **Kubernetes** keeps your applications running and replaces them when something fails.
- **Cloudflare Tunnel** carries visitors to your site over a connection your cluster opens outward, so nothing has to accept connections from the internet.

## Build your install image

In the Omni dashboard, click **Download Installation Media** to open the **Create New Media** wizard. Choose:

- Talos version **1.14.5**
- Architecture **amd64**
- Bare metal as the hardware type
- The **qemu-guest-agent** extension, if the wizard offers extensions

On the **Schematic Ready** page, download the **ISO**.

This image contains the details that let a machine join your account, so anyone who boots it can add a machine to your Omni. Keep it to yourself.

## Create three virtual machines

Upload your ISO in Proxmox under the `local` storage, in **ISO Images**. If your instructor has already created your VMs, attach your ISO to each one and skip to starting them.

Otherwise create three VMs with **Create VM**, named and sized like this:

| VM | Cores | Memory |
| --- | --- | --- |
| `talos-cp` | 2 | 4096 MiB |
| `talos-worker-a` | 2 | 3072 MiB |
| `talos-worker-b` | 2 | 3072 MiB |

Use these settings for all three:

| Tab | Setting | Value |
| --- | --- | --- |
| OS | ISO image | Your Talos ISO |
| System | Machine | q35 |
| System | BIOS | OVMF (UEFI), with an EFI disk |
| System | Pre-Enroll keys | Off |
| System | SCSI Controller | VirtIO SCSI, not VirtIO SCSI single |
| System | Qemu Agent | On |
| Disks | Size | 32 GiB |
| Disks | Cache | Write through |
| Disks | Discard | On |
| CPU | Type | host |
| Memory | Ballooning Device | Off (under Advanced) |
| Network | Bridge | The one your instructor names |
| Network | Model | VirtIO |

Two of these matter more than they look. VirtIO SCSI single can hang Talos during bootstrap, and memory ballooning stops Talos from seeing all of its memory.

Start all three VMs.

## Watch your machines appear

Open **Machines** in Omni. Each VM appears within about a minute of booting, with no login and no configuration from you. The image did that work.

## Create the cluster

In Omni, go to **Clusters** and click **Create Cluster**:

- Give it a name.
- Select Talos **1.14.5** and Kubernetes **1.37.2**.
- Under **Available Machines**, click **CP** on one machine to make it the control plane.
- Click **W0** on the other two to make them workers.
- Click **Create Cluster**.

Allow about five minutes. Talos installs itself to each disk and reboots, then Kubernetes starts. The control plane runs Kubernetes itself and the workers run your applications. One control plane is fine for learning, and production clusters use three so that losing one is not an emergency.

## Connect to the cluster

Open your cluster in Omni and click **Download kubeconfig**. Point kubectl at the file, using its real name and location:

```bash
export KUBECONFIG=~/Downloads/your-cluster-kubeconfig.yaml
```

In PowerShell:

```powershell
$env:KUBECONFIG = "$HOME\Downloads\your-cluster-kubeconfig.yaml"
```

Run this. A browser window opens the first time so you can sign in:

```bash
kubectl get nodes
```

You should see three nodes, all `Ready`.

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

You should see two `hello` pods on two different workers. Open `manifests/hello.yaml` and look at what you just deployed:

- The **ConfigMap** holds the web page and the server configuration, so there is no custom image to build.
- The **Deployment** asks for 2 replicas. Its `topologySpreadConstraints` keep them on different workers.
- The **tolerations** tell Kubernetes to replace these pods 30 seconds after a node is marked down. The default is 5 minutes, and 30 seconds suits a demo better.
- The **Service** gives both replicas a single stable address.

## Publish it to the internet

Save your tunnel token in a file called `token.txt`, then store it in the cluster as a Secret:

```bash
kubectl create secret generic cloudflared-token --from-literal=token="$(cat token.txt)"
```

In PowerShell:

```powershell
kubectl create secret generic cloudflared-token --from-literal=token="$((Get-Content token.txt -Raw).Trim())"
```

Start the tunnel connectors:

```bash
kubectl apply -f manifests/cloudflared.yaml
kubectl rollout status deployment/cloudflared
```

Open your site address in a browser. Each square on the page is one request, and each color is the node that answered it. You should see two colors.

Your site is now public, and your cluster still accepts no inbound connections. The `cloudflared` pods connect out to Cloudflare, and visitors' requests come back down those connections.

## Break a worker

Keep your site open where you can see it, and watch the pods in a terminal:

```bash
kubectl get pods -o wide --watch
```

In Proxmox, select one of your workers and click **Stop**. Use Stop and not Shutdown, because Shutdown lets the machine exit politely. Stop is the same as pulling the power cord.

Here is what to expect:

- **For the first 50 seconds or so**, some squares turn red. Kubernetes doesn't yet know the node is gone, so some requests are still sent to it.
- **At about 50 seconds**, Kubernetes marks the node as not ready and stops sending it traffic. The red squares stop.
- **At about 80 seconds**, replacement pods are running on the surviving worker, and you are back to two replicas.

Check the node from another terminal:

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

Your tunnel and its address stop working after the session, but your Omni account is yours to keep. With a domain of your own and a free Cloudflare account, you can set up the same thing at home on any spare computer.
