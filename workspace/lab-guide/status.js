const { execFile } = require('child_process');
const fs = require('fs');
const https = require('https');
const os = require('os');
const path = require('path');

const MACHINES = 3;
const COMMAND_TIMEOUT_MS = 15000;

function run(command, args) {
  return new Promise((resolve) => {
    execFile(command, args, { timeout: COMMAND_TIMEOUT_MS, maxBuffer: 32 * 1024 * 1024 }, (error, stdout, stderr) => {
      resolve({ ok: !error, stdout: stdout || '', stderr: (stderr || (error && error.message) || '').trim() });
    });
  });
}

function splitJson(text) {
  const objects = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let escaped = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if (c === '{') {
      if (depth === 0) start = i;
      depth++;
    } else if (c === '}') {
      depth--;
      if (depth === 0) objects.push(JSON.parse(text.slice(start, i + 1)));
    }
  }
  return objects;
}

function firstLine(text) {
  return (text.split('\n').find((line) => line.trim()) || 'no output').trim();
}

function hasKubeconfig() {
  return fs.existsSync(path.join(os.homedir(), '.kube', 'config'));
}

async function kubectlJson(args) {
  const result = await run('kubectl', [...args, '-o', 'json']);
  if (!result.ok && /provide credentials|Unauthorized/i.test(result.stderr)) {
    throw Object.assign(new Error('Your cluster login has expired. Run connect again'), { plain: true });
  }
  if (!result.ok) throw new Error(firstLine(result.stderr));
  return JSON.parse(result.stdout);
}

function isReady(item) {
  return (item.status.conditions || []).some((c) => c.type === 'Ready' && c.status === 'True');
}

function plural(count, word) {
  return `${count} ${word}${count === 1 ? '' : 's'}`;
}

async function readyPodNodes(namespace, selector) {
  const pods = await kubectlJson(['-n', namespace, 'get', 'pods', '-l', selector]);
  const ready = pods.items.filter((p) => !p.metadata.deletionTimestamp && isReady(p));
  return { ready: ready.length, nodes: new Set(ready.map((p) => p.spec.nodeName)).size };
}

function configErrors(text) {
  return text
    .split('\n')
    .map((line) => line.replace(/^\s*\*\s*/, '').trim())
    .filter((line) => line && !/^\d+ errors? occurred:?$/.test(line))
    .join('; ');
}

async function machineConfigErrors(cluster) {
  const [statuses, labels] = await Promise.all([
    run('omnictl', ['get', 'clustermachinestatuses', '-o', 'json']),
    run('omnictl', ['get', 'machinelabels', '-o', 'json']),
  ]);
  if (!statuses.ok) return [];
  const names = {};
  if (labels.ok) {
    for (const item of splitJson(labels.stdout)) {
      const name = Object.keys(item.metadata.labels || {}).find((key) => !key.startsWith('omni.sidero.dev/'));
      if (name) names[item.metadata.id] = name;
    }
  }
  return splitJson(statuses.stdout)
    .filter((s) => (s.metadata.labels || {})['omni.sidero.dev/cluster'] === cluster && s.spec && s.spec.lastconfigerror)
    .map((s) => `${names[s.metadata.id] || s.metadata.id.slice(0, 8)} rejected its configuration: ${configErrors(s.spec.lastconfigerror)}`);
}

function fetchStatus(url) {
  return new Promise((resolve) => {
    const request = https.get(url, { timeout: 10000 }, (response) => {
      response.resume();
      resolve(response.statusCode);
    });
    request.on('timeout', () => request.destroy(new Error('timed out')));
    request.on('error', () => resolve(0));
  });
}

const CHECKS = {
  async machines() {
    const result = await run('omnictl', ['get', 'machines', '-o', 'json']);
    if (!result.ok) return { done: false, text: `Omni did not answer: ${firstLine(result.stderr)}` };
    const connected = splitJson(result.stdout).filter((m) => m.spec && m.spec.connected === true).length;
    return { done: connected >= MACHINES, text: `${connected} of ${MACHINES} machines connected to your Omni` };
  },

  async cluster() {
    const result = await run('omnictl', ['get', 'clusterstatus', '-o', 'json']);
    if (!result.ok) return { done: false, text: `Omni did not answer: ${firstLine(result.stderr)}` };
    const clusters = splitJson(result.stdout);
    if (clusters.length === 0) return { done: false, text: 'No cluster yet' };
    const cluster = clusters.find((c) => c.spec.ready === true) || clusters[0];
    const machines = cluster.spec.machines || {};
    const healthy = machines.healthy || 0;
    const total = machines.total || 0;
    const ready = cluster.spec.ready === true;
    const done = ready && total >= MACHINES && healthy === total;
    const summary = `Cluster ${cluster.metadata.id}: ${healthy} of ${total} machines healthy, ${ready ? 'ready' : 'not ready yet'}`;
    if (done) return { done, text: summary };
    const errors = await machineConfigErrors(cluster.metadata.id);
    return { done, text: [summary, ...errors].join('. ') };
  },

  async nodes() {
    if (!hasKubeconfig()) return { done: false, text: 'Run connect first' };
    const nodes = await kubectlJson(['get', 'nodes']);
    const ready = nodes.items.filter(isReady).length;
    return { done: ready >= MACHINES, text: `${ready} of ${nodes.items.length} nodes Ready` };
  },

  async coredns() {
    if (!hasKubeconfig()) return { done: false, text: 'Run connect first' };
    const { ready, nodes } = await readyPodNodes('kube-system', 'k8s-app=kube-dns');
    return { done: ready >= 2 && nodes >= 2, text: `${plural(ready, 'CoreDNS pod')} ready on ${plural(nodes, 'node')}` };
  },

  async site() {
    if (!hasKubeconfig()) return { done: false, text: 'Run connect first' };
    const { ready, nodes } = await readyPodNodes('default', 'app=hello');
    return { done: ready >= 2 && nodes >= 2, text: `${plural(ready, 'hello replica')} ready on ${plural(nodes, 'node')}` };
  },

  async balance() {
    if (!hasKubeconfig()) return { done: false, text: 'Run connect first' };
    const { ready } = await readyPodNodes('kube-system', 'app=descheduler');
    return { done: ready >= 1, text: ready >= 1 ? 'The descheduler is running' : 'The descheduler is not running yet' };
  },

  async upgrade(seat) {
    if (!hasKubeconfig()) return { done: false, text: 'Run connect first' };
    const target = seat.upgrade || {};
    const nodes = await kubectlJson(['get', 'nodes']);
    const versions = nodes.items.map((n) => ({
      talos: ((/v([0-9.]+)/.exec(n.status.nodeInfo.osImage) || [])[1]) || 'unknown',
      kubernetes: n.status.nodeInfo.kubeletVersion.replace(/^v/, ''),
      ready: isReady(n),
    }));
    const talos = versions.filter((v) => v.talos === target.talos).length;
    const kubernetes = versions.filter((v) => v.kubernetes === target.kubernetes).length;
    const upgraded = versions.filter((v) => v.talos === target.talos && v.kubernetes === target.kubernetes && v.ready).length;
    return {
      done: versions.length >= MACHINES && upgraded === versions.length,
      text: `${talos} of ${versions.length} nodes on Talos ${target.talos}, ${kubernetes} of ${versions.length} on Kubernetes ${target.kubernetes}`,
    };
  },

  async publish(seat) {
    if (!hasKubeconfig()) return { done: false, text: 'Run connect first' };
    const { ready } = await readyPodNodes('default', 'app=cloudflared');
    if (ready < 2) return { done: false, text: `${plural(ready, 'tunnel connector')} ready` };
    const code = await fetchStatus(`${seat.links.site}/whoami`);
    return {
      done: code === 200,
      text: code === 200 ? `Your site answers at ${seat.links.site}` : `Connectors ready, ${seat.links.site} answered ${code || 'nothing'} so far`,
    };
  },
};

async function runChecks(seat, ids) {
  const results = {};
  await Promise.all(
    ids.map(async (id) => {
      try {
        results[id] = await CHECKS[id](seat);
      } catch (error) {
        results[id] = { done: false, text: error.plain ? error.message : `Not reachable yet: ${error.message}` };
      }
    }),
  );
  return results;
}

module.exports = { CHECKS, runChecks, splitJson };

if (require.main === module) {
  const seat = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.config', 'talos-lab', 'seat.json'), 'utf8'));
  runChecks(seat, Object.keys(CHECKS)).then((results) => process.stdout.write(`${JSON.stringify(results)}\n`));
}
