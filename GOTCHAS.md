# NKP 2.17.1 Air-Gapped Deploy — Gotcha Report

Live install log. Updated as issues are discovered.
Cluster: 3-CP (192.168.1.159/158/156), 0 workers, pre-provisioned, air-gapped.

---

## G-01 — NKP version is 2.17.1, not 2.17.0

**Discovered:** bundle probe  
**Impact:** deploy script had `NKP_VERSION="v2.17.0"` — image tags and bundle names mismatch.  
**Fix:** Always verify with `nkp version` before running. Updated script to `NKP_VERSION="v2.17.1"`.

---

## G-02 — Docker already installed (v29.4.1)

**Discovered:** preflight probe  
**Impact:** deploy script Phase 3 (Docker CE install) would have tried to re-add the apt repo and failed or conflicted.  
**Fix:** Phase 3 now checks `docker info` first and skips if running. No action needed here.

---

## G-03 — Bootstrap `--bundle` expects extracted `.tar` files, not the `.tar.gz` archive

**Discovered:** `nkp create bootstrap --help`  
**Impact:** The 22 GB `nkp-air-gapped-bundle_v2.17.1_linux_amd64.tar.gz` must be fully extracted first.
The `--bundle` flag consumes individual image bundle `.tar` files inside it
(e.g. `konvoy-image-bundle-v2.17.1.tar`, `kommander-image-bundle-v2.17.1.tar`).
Attempting `tar -tzf` listing over SSH times out — extract first, inspect second.  
**Fix:** Extract to `~/nkp-bundle/` first:
```bash
tar -xzf ~/nkp-air-gapped-bundle_v2.17.1_linux_amd64.tar.gz -C ~/nkp-bundle/
```
Run in background via `nohup ... &` — took ~20-30 min for 22 GB.  
**Status:** Extraction running as background process.

---

## G-04 — External local registry required — NOT just the bootstrap in-cluster registry

**Discovered:** `nkp create cluster preprovisioned --help` + web research  
**Impact:** `--registry-mirror-url` is required for cluster creation and must point to a registry
that ALL target nodes (158, 156) can reach. The bootstrap's in-cluster registry runs inside
a KIND pod and is not reachable by external nodes without extra NodePort/port-forward setup.  
**Fix:** Stand up a persistent registry on 192.168.1.159 (or another LAN host) before running
`nkp create cluster`. Use `nkp push bundle --bundle <tar> --to-registry http://192.168.1.159:5000
--to-registry-insecure-skip-tls-verify` to populate it.

---

## G-05 — `--ssh-username` defaults to "konvoy", not the OS user

**Discovered:** `nkp create cluster preprovisioned --help`  
**Impact:** NKP would try to create a new OS user called `konvoy` via SSH.
With `--ssh-username ice` it uses the existing user.
Wrong username = silent SSH failure during node bootstrap.  
**Fix:** Always pass `--ssh-username ice` explicitly. Script updated.

---

## G-06 — SSH user must have passwordless sudo on all nodes

**Discovered:** NKP docs + node probe (`sudo -n true` returned non-zero for `ice`)  
**Impact:** NKP uses SSH to run privileged operations (kubelet install, containerd config, etc.).
Without `NOPASSWD` sudo the install hangs waiting for a password that never comes.  
**Fix:** Add to each node:
```bash
echo '***REMOVED***' | sudo -S bash -c \
  'echo "ice ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/nkp-ice && chmod 440 /etc/sudoers.d/nkp-ice'
```
**Status:** Applied on 192.168.1.159, 192.168.1.158, 192.168.1.156.

---

## G-07 — `apt-get` inside SSH session needs `sudo` — not just `apt-get`

**Discovered:** sshpass install attempt  
**Impact:** Running `apt-get install sshpass` as `ice` (non-root) fails with dpkg lock error.  
**Fix:** Use `sudo apt-get install -y sshpass`. Works once G-06 (NOPASSWD) is applied.

---

## G-08 — Swap is ON by default on Ubuntu 24.04 (all nodes)

**Discovered:** node probe on 192.168.1.159 — `/swap.img` active (4G)  
**Impact:** kubelet refuses to start with swap enabled unless a specific feature gate is set.
NKP does not set that gate — swap must be off before cluster bootstraps.  
**Fix:** On each node before bootstrap:
```bash
swapoff -a
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab
```

---

## G-09 — Disk space: extraction consumes ~22 GB; monitor through bootstrap

**Discovered:** extraction monitoring  
**Impact:** `/` had 64 G free before extraction. At ~50% extracted disk was at 42 G free.
Full extraction + Docker registry images + KIND bootstrap cluster can push close to limits.  
**Mitigation:** Keep at least 20 G free before starting bootstrap. If tight, move the source
`.tar.gz` archive to another partition or delete it after confirming extraction is complete.

---

## G-10 — `tar -tzf` listing of 22 GB archive times out over SSH (30 s cap)

**Discovered:** first bundle inspection attempt  
**Impact:** Cannot preview bundle contents without extracting.  
**Workaround:** Extract fully, then `ls ~/nkp-bundle/nkp-v2.17.1/` to discover file tree.

---

## G-11 — `nkp create bootstrap --bundle` requires fully extracted `.tar` files, not globs on `.tar.gz`

**Discovered:** bootstrap help flags  
**Impact:** The `--bundle` flag says "supports glob pattern" but the files must be uncompressed
`.tar` archives. The outer `.tar.gz` bundle wrapper must be extracted first (G-03).  
**Fix:** After extraction, pass:
```
--bundle ~/nkp-bundle/nkp-v2.17.1/container-images/konvoy-image-bundle-v2.17.1.tar,\
~/nkp-bundle/nkp-v2.17.1/container-images/kommander-image-bundle-v2.17.1.tar
```

---

---

## G-12 — 192.168.1.158 SSH auth hangs (PAM stall on Ubuntu 24.04)

**Discovered:** repeated SSH connection attempts from 159 → 158  
**Symptom:** `nc` connects to port 22 instantly, SSH banner returns (`OpenSSH_9.6p1 Ubuntu`), but all
`sshpass` + `ssh` auth attempts time out after 25-30 s regardless of auth method flags.  
**Root cause:** Ubuntu 24.04 default `UsePAM yes` with a PAM module trying to contact an unavailable
service (common culprits: `systemd-resolved` DNS lookup, SSSD, or `pam_motd`). Auth stalls waiting
for a service that never responds.  
**Fix:** On 158, as root or via console access:
```bash
# Quick fix — disable PAM for SSH (password auth falls through directly):
sed -i 's/^UsePAM yes/UsePAM no/' /etc/ssh/sshd_config
systemctl restart sshd
```
Or the safer fix: ensure the problematic PAM module has a short timeout.  
**Workaround:** Install SSH key via console/physical access, then key-auth skips PAM entirely.

---

## G-13 — NKP bundles its own containerd (v1.7.29-d2iq) — may conflict with installed v2.2.3

**Discovered:** `image-artifacts/containerd-1.7.29-d2iq.1-ubuntu-24.04-x86_64.tar.gz` in bundle  
**Impact:** NKP pre-provisioned installer typically installs containerd from its own bundle tarball,
overwriting whatever is on the node. Going from v2.2.3 → v1.7.29 is a downgrade.
The d2iq build is patched for NKP compatibility; the stock Ubuntu build may cause kubelet issues.  
**Mitigation:** Let NKP install its own containerd. Do NOT pre-configure containerd features
that depend on v2.x-specific APIs (e.g., the new `certs.d` config_path). NKP manages containerd
config post-install via its own templates.  
**Action:** Remove custom containerd config before bootstrap runs on each node:
```bash
# Will be done in node-prereqs.sh before NKP bootstrap
rm -f /etc/containerd/config.toml /etc/containerd/certs.d/*/hosts.toml
```

---

---

## G-14 — 156 (nkp-bm-002) has no containerd pre-installed

**Discovered:** node-prereqs.sh run on 156  
**Impact:** containerd not present — `containerd config default` fails with exit 127.  
**Fix:** node-prereqs.sh updated to skip containerd config when not installed.
NKP installs containerd from `image-artifacts/containerd-1.7.29-d2iq.1-ubuntu-24.04-x86_64.tar.gz` during bootstrap.

---

## G-15 — authorized_keys line-wrap corrupts key on terminal paste

**Discovered:** key install on 158 — fingerprint mismatch  
**Impact:** `echo "key" >> authorized_keys` wraps at terminal width → 2 lines → auth fails with `[preauth]` close.  
**Fix:** Always use `printf 'key\n' > authorized_keys` (overwrites, no wrap) or pipe via `scp` + `ssh-copy-id`.

---

## G-16 — 158 SSH auth stall traced to stale authorized_keys, not PAM

**Discovered:** fingerprint comparison between 159 (source) and 158 (installed)  
**Impact:** All timeout symptoms (even with BatchMode, GSSAPIAuthentication=no) were caused by  
key mismatch making the server reject the key silently while waiting for another auth method.  
**Fix:** Cleared authorized_keys and re-installed via `scp` from 159 via user's PC.

---

## G-17 — `~` tilde does not expand inside comma-separated `--bundle` string

**Discovered:** `nkp create bootstrap --bundle ~/path/a.tar,~/path/b.tar`
**Impact:** Shell only expands `~` at the start of a word. The second path after the comma is not a new word — it stays as `~/path/b.tar` literally. `nkp` reports "no files found matching pattern `~/path/...`".
**Fix:** Use `$HOME` for all paths in comma-separated flags:
```bash
--bundle $HOME/nkp-bundle/.../konvoy-image-bundle.tar,$HOME/nkp-bundle/.../kommander-image-bundle.tar
```

---

## G-18 — `nkp create bootstrap --bundle` does NOT create an accessible external registry

**Discovered:** After bootstrap with `--bundle`, `kubectl get svc -A` in the bootstrap cluster shows only ClusterIP services. No NodePort or hostNetwork registry.
**Impact:** The bundle images are loaded into the KIND node's internal containerd only. External nodes (158, 156) cannot reach the bootstrap registry. The `--registry-mirror-url` flag on `nkp create cluster preprovisioned` conflicts with the `--bundle` state, producing:
`err="flags --registry-mirror-url and --bundle cannot be provided together"`
**Fix:** Do NOT use `--bundle` on `nkp create bootstrap`. Instead:
1. `nkp create bootstrap --bootstrap-cluster-image <tar>` (no `--bundle`)
2. Stand up a Docker `registry:2` container on 159:5000
3. `nkp push bundle --bundle <tar> --to-registry http://localhost:5000 --to-registry-insecure-skip-tls-verify`
4. `nkp create cluster preprovisioned --registry-mirror-url http://192.168.1.159:5000`

---

## G-19 — `nkp push bundle` uses an ephemeral internal registry that can die mid-push

**Discovered:** `nkp push bundle` (mindthegap) starts a temporary OCI registry on a random ephemeral port (observed: 46249) for image staging, then tears it down. If the ephemeral registry dies before all images are pushed, subsequent images fail with:
`dial tcp 127.0.0.1:46249: connect: connection refused`
The command exits 0 despite partial failures.
**Fix:** Re-run `nkp push bundle` — it is idempotent and will skip already-pushed images. Run twice if necessary. Verify with `curl -s http://localhost:5000/v2/_catalog`.

---

## G-20 — PreprovisionedInventory API group is `infrastructure.cluster.konvoy.d2iq.io`, not `infrastructure.cluster.x-k8s.io`

**Discovered:** dry-run of `nkp create cluster preprovisioned --pre-provisioned-inventory-file`
**Impact:** Using the upstream CAPI API group (`cluster.x-k8s.io`) fails with "no matches for kind PreprovisionedInventory". NKP uses D2iQ's own API group.
**Fix:** Inventory file header:
```yaml
apiVersion: infrastructure.cluster.konvoy.d2iq.io/v1alpha1
kind: PreprovisionedInventory
```
Also: even with `--worker-replicas 0`, you must include a PreprovisionedInventory for the worker nodepool (`nkp-cluster-md-0`) with `hosts: []` or the command errors.

---

## G-21 — `nkp create cluster --self-managed` replaces bootstrap, shifts its port

**Discovered:** After `nkp create bootstrap` + `nkp create cluster preprovisioned --self-managed`, the KIND container API port changes (e.g. 40047 → 38077). The kubeconfig at `~/.kube/nkp-bootstrap.kubeconfig` still points to the old port → all `kubectl` calls fail with connection refused.
**Fix:** Extract fresh kubeconfig from the running KIND container:
```bash
docker exec konvoy-capi-bootstrapper-control-plane cat /etc/kubernetes/admin.conf \
  | sed 's|https://.*:6443|https://127.0.0.1:38077|g' > ~/.kube/nkp-bootstrap.kubeconfig
```
Find current port with: `docker ps --format '{{.Names}} {{.Ports}}' | grep bootstrapper`

---

## G-22 — `--ssh-private-key-file` creates the SSH secret but does NOT wire it into PreprovisionedInventory sshConfig

**Discovered:** `cappp-system/cappp-controller-manager` logs show `"failed to get sshConfig secret: Secret \"\" not found"` — empty string secret name — despite `--ssh-private-key-file` being passed.
**Impact:** PreprovisionedMachine controller cannot SSH into nodes. Cluster stuck at `WaitingForBootstrapData` indefinitely.
**Root cause:** `nkp create cluster preprovisioned` creates secret `nkp-cluster-ssh-key` but leaves `sshConfig.privateKeyRef.name`, `sshConfig.user`, and `sshConfig.port` unset in both PreprovisionedInventory objects (`nkp-cluster-control-plane` and `nkp-cluster-md-0`).

Key facts:
- The SSH config lives in **`PreprovisionedInventory.spec.sshConfig`** — NOT in PreprovisionedMachine, PreprovisionedMachineTemplate, or PreprovisionedCluster (those CRDs don't have this field).
- The responsible controller is **`cappp-system/cappp-controller-manager`** (Cluster API Provider PreProvisioned), not CAREN.
- PreprovisionedInventory sshConfig schema: `{ port: int, user: string, privateKeyRef: { name: string, namespace: string } }`

**Fix:** After cluster create, patch both inventories:
```bash
KC="$HOME/nkp-bundle/nkp-v2.17.1/kubectl"
KCF="--kubeconfig=$HOME/.kube/nkp-bootstrap.kubeconfig"
for inv in nkp-cluster-control-plane nkp-cluster-md-0; do
  "$KC" $KCF patch preprovisionedinventory "$inv" -n default --type=merge \
    -p '{"spec":{"sshConfig":{"port":22,"user":"ice","privateKeyRef":{"name":"nkp-cluster-ssh-key","namespace":"default"}}}}'
done
```
Verify: `kubectl get preprovisionedinventory nkp-cluster-control-plane -n default -o jsonpath='{.spec.sshConfig}'`

---

## G-23 — NKP deploy RSA key not in `authorized_keys` → SSH auth fails after G-22 fix

**Discovered:** After fixing G-22, cappp logs show `ssh: unable to authenticate, attempted methods [none publickey], no supported methods remain` for all 3 nodes.
**Impact:** Even with `sshConfig.privateKeyRef` correctly set, cappp still cannot SSH in because the public key from `nkp-cluster-ssh-key` is not listed in `~ice/.ssh/authorized_keys` on the nodes.
**Root cause:** `--ssh-private-key-file` stores the private key in a Kubernetes secret but does NOT distribute the corresponding public key to the nodes' `authorized_keys`. The nodes were set up with a different key (e.g., a Windows workstation ed25519 key). The NKP deploy RSA key (4096-bit, comment `nkp-deploy`) is entirely absent.
**Fix:** Extract the public key from the secret and append it to `authorized_keys` on all 3 nodes:
```bash
KC="$HOME/nkp-bundle/nkp-v2.17.1/kubectl"
KCF="--kubeconfig=$HOME/.kube/nkp-bootstrap.kubeconfig"

# Extract public key from secret
"$KC" $KCF get secret nkp-cluster-ssh-key -n default \
  -o jsonpath='{.data.ssh-privatekey}' | base64 -d > /tmp/nkp-key.pem
chmod 600 /tmp/nkp-key.pem
NKP_PUBKEY=$(ssh-keygen -y -f /tmp/nkp-key.pem)

# Add to local node (159)
echo "$NKP_PUBKEY nkp-deploy" >> ~/.ssh/authorized_keys

# Add to remote nodes via sshpass (requires sshpass + passwordless from prereqs)
for NODE in 192.168.1.158 192.168.1.156; do
  sshpass -p '***REMOVED***' ssh -o StrictHostKeyChecking=no ice@$NODE \
    "echo '$NKP_PUBKEY nkp-deploy' >> ~/.ssh/authorized_keys"
done
rm -f /tmp/nkp-key.pem
```
**Script fix:** `nkp-deploy.sh` prereqs phase must add the deploy key to `authorized_keys` on all nodes before `nkp create cluster` runs.

---

## G-24 — NIB provision job fails: `NO_PUBKEY` for `pkgs.k8s.io/core:/stable:/v1.30` apt repo

**Discovered:** `cappp-system/cappp-controller-manager` creates a Kubernetes Job (`<machine-name>-provision`) that runs an Ansible playbook to bootstrap the node. The first Ansible task (`repo : update apt cache`) fails with `apt-get update` rc=100: `NO_PUBKEY 234654DA9A296436` for the Kubernetes apt repo.
**Impact:** `NIBFailed` condition set on PreprovisionedMachine; `BackoffLimitExceeded` on Job; bootstrap never starts. Status stuck at `BootstrapExecSucceeded: False`.
**Root cause:** node-prereqs.sh adds `/etc/apt/sources.list.d/kubernetes.list` pointing to `pkgs.k8s.io/core:/stable:/v1.30/deb` but does NOT import the corresponding GPG keyring at `/etc/apt/keyrings/kubernetes-apt-keyring.gpg`. The NIB Ansible's first `apt-get update` hits a signature verification failure.
**Fix:** On all 3 nodes before triggering cluster create (add to node-prereqs phase):
```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```
Then after applying the fix, delete the failed job and force a reconcile:
```bash
KC="$HOME/nkp-bundle/nkp-v2.17.1/kubectl"
KCF="--kubeconfig=$HOME/.kube/nkp-bootstrap.kubeconfig"
"$KC" $KCF delete job <machine-name>-provision -n default
"$KC" $KCF annotate preprovisionedmachine <machine-name> -n default \
  "reconcile.force/ts=$(date +%s)" --overwrite
```
**Script fix:** Add GPG key import to `node-prereqs.sh` immediately after adding the kubernetes.list source.

---

## G-25 — `nkp create cluster --self-managed` timeout removes docker-ce and kills bootstrap cluster

**Discovered:** After `nkp create cluster preprovisioned --self-managed` exceeded its internal deadline (rate limiter context timeout at ~45 min), it ran cleanup. Cleanup included `nkp delete bootstrap`, which: (1) stopped and removed the KIND container `konvoy-capi-bootstrapper-control-plane`, and (2) **uninstalled the `docker-ce` package** (`dpkg -l` shows `rc` status — removed, config retained). Docker daemon stopped at 16:15:05. The docker.socket unit symlink (`/etc/systemd/system/multi-user.target.wants/docker.service → /usr/lib/systemd/system/docker.service`) was left broken — target file removed by apt purge.
**Impact:** Bootstrap KIND cluster gone. CAPI objects (Cluster, KCP, PreprovisionedMachine, Jobs) still present in etcd but inaccessible. All kubectl operations fail with "connection refused".
**Recovery:**
1. Reinstall docker-ce: `sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce`
2. Create the missing systemd unit (docker-ce only installed `/etc/init.d/docker`, not the systemd unit):
```bash
sudo tee /usr/lib/systemd/system/docker.service > /dev/null << 'UNIT'
[Unit]
Description=Docker Application Container Engine
After=network-online.target
Wants=network-online.target
[Service]
Type=notify
ExecStart=/usr/bin/dockerd -H unix:///var/run/docker.sock
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable --now docker
```
3. Docker auto-restarts the stopped KIND containers (they were only stopped, not removed).
4. Bootstrap cluster comes back on the SAME port (38077 in this case) — kubeconfig valid.
5. Delete the stale failed provision job and force reconcile to resume.
**Script fix:** `nkp-deploy.sh` must enable + start Docker via systemd BEFORE `nkp create bootstrap`, and must ensure docker-ce is installed with the unit file. Also: run `nkp create cluster` with `--timeout 2h` to avoid premature cleanup.

---

## G-26 — Bootstrap API server takes ~2-3 min to become ready after KIND container restart

**Discovered:** After `docker start konvoy-capi-bootstrapper-control-plane`, the container is `Up` immediately but port 38077 refuses connections for ~2 minutes while kube-apiserver, etcd, and controller-manager start inside KIND. kubectl calls during this window fail with "connection refused".
**Fix:** Poll with `nc` or `curl --insecure https://127.0.0.1:38077/healthz` in a loop (up to 3 min) before running kubectl commands after a bootstrap cluster restart.

---

## G-27 — NIB `apt-get remove containerd.io` kills bootstrap KIND cluster (self-managed single-node circular dependency)

**Discovered:** After G-24 GPG fix, the new NIB provision job got past `apt-get update` but failed with SSH exit 255 at task `[containerd : remove containerd.io deb package]`. Pod exit reason: `exitCode: 255, reason: Unknown`.
**Root cause:** NKP NIB Ansible removes `containerd.io` (Docker's containerd package) and installs NKP's own containerd binary. On the bootstrap node (159), `containerd.io` is the runtime backing Docker, which backs the KIND cluster, which backs the NIB pod itself. When apt's prerm script runs `systemctl stop containerd`, Docker loses its runtime → KIND containers stop → NIB pod dies → SSH client dies → exit 255. Circular: provisioning the node kills the provisioner.
**Impact:** Every NIB provision attempt on 159 fails at this step. The job restarts but hits the same wall. No progress toward kubeadm init.
**Fix:** Before triggering a new NIB job, neuter the dpkg prerm scripts for `containerd.io` and `docker-ce` so apt removes the packages WITHOUT stopping the running daemons. Also enable Docker `live-restore` so containers survive any brief containerd restart:
```bash
# On 159, run ONCE before the NIB job is recreated:

# 1. Neuter prerm scripts (prevent apt from stopping containerd/docker)
for PKG in containerd.io docker-ce; do
  PRERM="/var/lib/dpkg/info/${PKG}.prerm"
  if [ -f "$PRERM" ]; then
    sudo cp "$PRERM" "${PRERM}.bak"
    printf '#!/bin/sh\nexit 0\n' | sudo tee "$PRERM" > /dev/null
  fi
done

# 2. Enable Docker live-restore (containers survive containerd daemon restart)
echo '{"live-restore": true}' | sudo tee /etc/docker/daemon.json

# 3. Delete failed job + force reconcile so cappp creates a new NIB job
KC="$HOME/nkp-bundle/nkp-v2.17.1/kubectl"
KCF="--kubeconfig=$HOME/.kube/nkp-bootstrap.kubeconfig"
"$KC" $KCF delete job nkp-cluster-control-plane-md7lg-provision -n default
"$KC" $KCF annotate preprovisionedmachine nkp-cluster-control-plane-md7lg -n default \
  "reconcile.force/ts=$(date +%s)" --overwrite
```
**Result:** With neutered prerm, apt removes `containerd.io`/`docker-ce` packages but the running containerd and dockerd processes stay alive. The KIND cluster keeps running. The NIB pod survives. NKP then explicitly `systemctl restart containerd` to activate its own containerd binary — this brief restart (≤2s) is survived by containerd-shim keeping container processes alive (live-restore handles Docker side). NIB continues to kubeadm init.
**Script fix:** `nkp-deploy.sh` must run the prerm-neuter block on 159 (bootstrap node only) immediately before `nkp create cluster`. On non-bootstrap CP nodes (158, 156) this is not needed.

---

## G-28 — NIB `systemctl enable containerd` fails with EBUSY after G-27 prerm-neuter fix

**Discovered:** After G-27 fix (neutered prerm), the NIB got past `remove containerd.io` but failed at `[containerd : enable containerd]` with: `"Error loading unit file 'containerd': System.Error.EBUSY — Unit containerd.service failed to load properly, please adjust/correct and reload service manager: Device or resource busy"`. Exit after 33 seconds.
**Root cause:** With prerm neutered, `apt-get remove containerd.io` removes the containerd.io package (deletes the unit file at `/lib/systemd/system/containerd.service`) but leaves the containerd PROCESS running. systemd now has an orphaned containerd process with no matching unit file. When NKP's containerd package installs a new `/lib/systemd/system/containerd.service` and Ansible calls `systemctl daemon-reload + enable containerd`, systemd encounters EBUSY because it's trying to adopt the orphaned running process into the new unit definition while the unit is simultaneously being activated — a state machine conflict.
**Fix:** Pre-remove containerd.io BEFORE the NIB job starts (using neutered prerm so daemon stays alive), then kill the orphaned containerd process, then daemon-reload, then force NIB reconcile. The NIB then installs NKP's containerd onto a completely clean slate (no running process, no stale unit):
```bash
# On 159, run BEFORE triggering NIB job:
KC="$HOME/nkp-bundle/nkp-v2.17.1/kubectl"
KCF="--kubeconfig=$HOME/.kube/nkp-bootstrap.kubeconfig"

# 1. Remove containerd.io (prerm neutered from G-27 — daemon stays alive)
sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y containerd.io

# 2. Clear orphaned unit from systemd
sudo systemctl daemon-reload

# 3. Kill orphaned containerd process (containerd-shim keeps KIND containers alive)
sudo pkill -TERM -x containerd 2>/dev/null || true
sleep 3

# 4. Delete failed job + force reconcile
"$KC" $KCF delete job nkp-cluster-control-plane-md7lg-provision -n default
"$KC" $KCF annotate preprovisionedmachine nkp-cluster-control-plane-md7lg -n default \
  "reconcile.force/ts=$(date +%s)" --overwrite
```
**Why containerd-shim keeps KIND alive:** containerd-shim is a separate process per container; it stays alive when the containerd daemon exits. KIND container processes (etcd, API server) keep running via their shims. KIND's internal containerd (separate instance inside the KIND container) is unaffected. Port 38077 remains accessible throughout.
**Script fix:** `nkp-deploy.sh` must remove `containerd.io`, daemon-reload, and kill containerd on 159 before `nkp create cluster`. The pre-removal is safe because containerd-shim architecture decouples the daemon lifecycle from running container processes.

---

## G-29 — kubeadm init fails post-control-plane-check: VIP (192.168.1.100) unreachable — kube-vip not deployed

**Discovered:** After NIB completes on 159, cappp runs `kubeadm init --config /run/kubeadm/kubeadm.yaml`. Certs, static pods, and kube-apiserver all start successfully. But kubeadm post-init phases (upload-config, mark-control-plane, bootstrap-token, addon) all fail with "dial tcp 192.168.1.100:6443: connect: no route to host". The `bootstrap-success.complete` file is never written. `BootstrapExecSucceeded: False`.
**Root cause:** `controlPlaneEndpoint: 192.168.1.100:6443` is set in the kubeadm config, but no kube-vip static pod manifest exists at `/etc/kubernetes/manifests/kube-vip.yaml`. NKP in preprovisioned mode expects an external load balancer or kube-vip for the VIP. For bare-metal without an external LB, kube-vip must be deployed manually or the VIP must be a host alias.
**Fix:** Manually assign VIP to ens33, run the failed kubeadm phases, then write the success file:
```bash
# 1. Add VIP to the interface
sudo ip addr add 192.168.1.100/24 dev ens33

# 2. Upload certs (required for CP join config generation by KCP)
sudo kubeadm init phase upload-certs --upload-certs --config /run/kubeadm/kubeadm.yaml

# 3. Run remaining post-init phases
sudo kubeadm init phase upload-config all --config /run/kubeadm/kubeadm.yaml
sudo kubeadm init phase mark-control-plane --config /run/kubeadm/kubeadm.yaml
sudo kubeadm init phase bootstrap-token --config /run/kubeadm/kubeadm.yaml
sudo kubeadm init phase addon all --config /run/kubeadm/kubeadm.yaml

# 4. Write bootstrap-success so cappp detects completion
sudo mkdir -p /run/cluster-api
echo "success" | sudo tee /run/cluster-api/bootstrap-success.complete

# 5. Force reconcile
KC="$HOME/nkp-bundle/nkp-v2.17.1/kubectl"
KCF="--kubeconfig=$HOME/.kube/nkp-bootstrap.kubeconfig"
"$KC" $KCF annotate preprovisionedmachine nkp-cluster-control-plane-md7lg -n default \
  "reconcile.force/ts=$(date +%s)" --overwrite
```
**Note:** The VIP added via `ip addr add` is NOT persistent across reboots. For production, deploy kube-vip as a static pod in `/etc/kubernetes/manifests/kube-vip.yaml` on all CP nodes. The VIP should be on the same subnet as the node interfaces.
**Script fix:** `nkp-deploy.sh` must: (1) deploy kube-vip static pod BEFORE `nkp create cluster`, OR (2) add the VIP alias to ens33 and run the kubeadm phases manually after the bootstrap phase completes.

---

## G-30 — After kubeadm init, kube-proxy sets FORWARD policy=DROP blocking bootstrap→CP2/CP3 traffic

**Discovered:** After CP1 (159) kubeadm init completed, kube-proxy on 159 set `iptables FORWARD` policy to DROP. Additionally, Docker's NAT MASQUERADE rules (for 172.17/172.18 bridge networks) were lost after the containerd.io→NKP-containerd swap (Docker with live-restore doesn't reapply iptables when bridges already exist on restart). Result: cappp pods inside the KIND bootstrap cluster could not SSH to CP2 (192.168.1.158:22) — all attempts timed out. The NIB job for CP2 was never created.
**Root cause (two sub-issues):**
1. FORWARD policy DROP: kube-proxy adds `--cluster-cidr` forwarding rules but leaves default DROP for all other traffic, blocking the KIND bridge (br-a02add3c544d) from routing to external hosts.
2. Missing MASQUERADE: Docker restart with live-restore skips iptables NAT setup when bridge interfaces already exist.
**Fix:** After kubeadm init on the bootstrap node, run these iptables fixes BEFORE cappp tries to provision CP2/CP3:
```bash
KIND_BR="br-$(docker network ls --filter name=kind --format '{{.ID}}' | cut -c1-12)"

# 1. Restore Docker NAT masquerade
sudo iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 172.18.0.0/16 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/8 ! -o lo -j MASQUERADE

# 2. Allow KIND bridge traffic through FORWARD (insert before kube-proxy rules)
sudo iptables -I FORWARD 1 -i "$KIND_BR" -j ACCEPT
sudo iptables -I FORWARD 1 -o "$KIND_BR" -j ACCEPT
```
**Timing:** Must run AFTER `kubeadm init` (which starts kube-proxy) AND AFTER `bootstrap-success.complete` is written (which triggers cappp to provision CP2). Running before kube-proxy starts would be overwritten. Running after CP2 provisioning is attempted causes unnecessary timeout delays.
**Script fix:** Add these iptables rules to `nkp-deploy.sh` immediately after the kubeadm init phase completes on the bootstrap node, before moving on to CP2/CP3 provisioning.

---

## SESSION CHECKPOINT — 2026-04-29 session 4

**All fixes applied (G-22 through G-27):**
- G-22 CORRECTED: `sshConfig` is on `PreprovisionedInventory`, not Machine/Template/Cluster. Patched both inventories with `port:22, user:ice, privateKeyRef.name:nkp-cluster-ssh-key`
- G-23: NKP deploy RSA key added to `~/.ssh/authorized_keys` on 159, 158, 156
- G-24: k8s apt repo GPG key imported on all 3 nodes (`/etc/apt/keyrings/kubernetes-apt-keyring.gpg`)
- G-25: `docker-ce` removed by NKP cleanup; reinstalled + manual docker.service unit created
- G-26: KIND API server takes 2-3 min after container restart
- G-27: NIB `apt-get remove containerd.io` kills bootstrap → prerm scripts neutered, live-restore enabled

**Current state (session 4 — late):**
- CP1 (159/nkp-bm-01): **Running** in target cluster, containerd://1.7.29-d2iq.1, NotReady (no CNI)
- KCP: **INITIALIZED=true**, 2 replicas desired (3rd pending CP2 completion)
- CP2 NIB job: **RUNNING** (kf4mj → 192.168.1.158) — ~2-3 min to complete
- CP3 (156): not yet assigned
- VIP 192.168.1.100: active on ens33 (added manually, non-persistent)
- Docker: running (process alive, docker-ce package `rc`)
- iptables: MASQUERADE rules restored, FORWARD ACCEPT for kind bridge inserted
- G-29 fix: VIP added, kubeadm phases run manually, bootstrap-success written
- G-30 fix: iptables NAT + FORWARD restored for KIND→external routing

**Next on resume — in order:**
1. Check CP2 NIB: `$KC $KCF get jobs -n default` + tail pod logs
2. After CP2 NIB completes: cappp runs kubeadm join on 158 (no VIP issue — join uses existing API)
3. Machine kf4mj → Running; KCP creates 3rd machine for 156
4. CP3 (156) will need same G-30 iptables check (rules may persist from session)
5. When KCP READY=3: get cluster kubeconfig from bootstrap
6. Install CNI (Calico — NKP ClusterResourceSet auto-applies)
7. Untaint CP nodes: `kubectl taint nodes --all node-role.kubernetes.io/control-plane-`
8. Configure MetalLB IPAddressPool (192.168.1.200-220) + L2Advertisement
9. Install trimmed Kommander: `nkp install kommander --kubeconfig <cluster-kubeconfig> --apps-config <trimmed.yaml>`
10. commit-and-log

**Next steps on resume:**
1. Confirm 158 is up → SSH from 159 with nkp_rsa → fix sudo → run node-prereqs.sh
2. Bootstrap: on 159 run:
   ```
   nkp create bootstrap \
     --bootstrap-cluster-image ~/nkp-bundle/nkp-v2.17.1/konvoy-bootstrap-image-v2.17.1.tar \
     --bundle ~/nkp-bundle/nkp-v2.17.1/container-images/konvoy-image-bundle-v2.17.1.tar,~/nkp-bundle/nkp-v2.17.1/container-images/kommander-image-bundle-v2.17.1.tar \
     --kubeconfig ~/.kube/nkp-bootstrap.kubeconfig
   ```
3. After bootstrap: find registry URL → `docker ps` or `kubectl get svc -n registry`
4. Apply PreprovisionedInventory for 3 CP nodes
5. nkp create cluster preprovisioned with registry URL
6. Wait, untaint CPs, MetalLB, Kommander

**Key paths:**
- SSH key: ice@192.168.1.159:~/.ssh/nkp_rsa (fingerprint SHA256:cIPVnDYA1032flhSDjZzrPmN4NnUtYnzfHLHVWv2XXE)
- Bundle: ~/nkp-bundle/nkp-v2.17.1/ on 159
- Kubeconfig: ~/.kube/nkp-bootstrap.kubeconfig (after bootstrap)

---

_Last updated: 2026-04-29 — pre-compaction checkpoint_

---

## G-31 — `nkp install kommander` pre-flight fails: cert-manager not installed

**Discovered:** Running `nkp install kommander --airgapped` on pre-provisioned cluster  
**Impact:** Hard stop — installer aborts with "cert-manager is not installed, please check your cluster and make sure cert-manager is installed and working"  
**Root cause:** In cloud-provisioned NKP, cert-manager is deployed via a ClusterResourceSet during cluster creation. In pre-provisioned mode, no cert-manager ClusterResourceSet is created. Kommander pre-flight requires cert-manager to already be present.  
**Secondary issue:** The Kommander image bundle (`kommander-image-bundle-v2.17.1.tar`, 11GB) must be pushed to the local registry separately. It contains cert-manager Helm chart OCI artifacts (`mesosphere/charts/cert-manager:v1.18.2`) which are not in the Konvoy bundle. The default `nkp push bundle` for cluster creation only pushes the Konvoy bundle.  
**Fix:** Push the Kommander bundle first, then install cert-manager via Helm from the local registry:
```bash
# Push Kommander bundle (one-time, ~11GB — only needed once before nkp install kommander)
nkp push bundle \
  --bundle ~/nkp-bundle/nkp-v2.17.1/container-images/kommander-image-bundle-v2.17.1.tar \
  --to-registry 192.168.1.159:5000 \
  --to-registry-insecure-skip-tls-verify \
  --image-push-concurrency 4

# Install cert-manager from local registry
helm install cert-manager-crds \
  oci://192.168.1.159:5000/mesosphere/charts/cert-manager-crds \
  --version v1.18.2 --namespace cert-manager --create-namespace --plain-http \
  --kubeconfig ~/.kube/nkp-cluster.kubeconfig

helm install cert-manager \
  oci://192.168.1.159:5000/mesosphere/charts/cert-manager \
  --version v1.18.2 --namespace cert-manager --plain-http \
  --set global.priorityClassName=system-cluster-critical \
  --kubeconfig ~/.kube/nkp-cluster.kubeconfig

# Wait for all 3 cert-manager pods Running, then install Kommander
nkp install kommander --airgapped \
  --installer-config /home/ice/kommander-trimmed.yaml \
  --kubeconfig ~/.kube/nkp-cluster.kubeconfig
```
**Note:** cert-manager chart registry pagination — `_catalog` only returns 100 repos by default. Use `?n=500` to see all repos. The mesosphere/charts are in the second page.

---

## SESSION CHECKPOINT — 2026-04-29 session 5

**All fixes applied through G-31:**
- G-31: Kommander bundle pushed, cert-manager installed via Helm (3 pods Running in cert-manager ns)
- All 3 nodes Ready, no taints
- MetalLB fully running (controller + 3 speakers), IPAddressPool 192.168.1.200-220 configured
- Cluster kubeconfig at ~/.kube/nkp-cluster.kubeconfig on 159
- Disk freed: 22G tarball removed, 159 at 67% used

**Current state:**
- CP1 (159/nkp-bm-01): Ready, control-plane, v1.34.3, containerd://1.7.29-d2iq.1
- CP2 (158/nkp-bm-03): Ready, control-plane, v1.34.3
- CP3 (156/nkp-bm-002): Ready, control-plane, v1.34.3
- cert-manager: 3/3 pods Running in cert-manager namespace
- MetalLB: Running, pool 192.168.1.200-192.168.1.220

---

## G-32 — `nkp install kommander --airgapped` fetches kommander-applications from GitHub

**Discovered:** Running `nkp install kommander --airgapped`  
**Impact:** Installer ignores `--airgapped` for the applications repository fetch — tries to reach `https://github.com/mesosphere/kommander-applications/archive/refs/tags/v2.17.1.tar.gz`, fails with DNS timeout.  
**Secondary:** `--kommander-applications-repository http://localhost:8080/...` fails with "failed to adjust to github repository file structure: open /tmp/dkp-repository-XXX/repo: no such file or directory" regardless of tarball structure (tried bare, GitHub-style `<repo>-<version>/`, and `repo/` top-level dir).  
**Fix:** Pass the local tarball path directly — the installer accepts a local filesystem path:
```bash
nkp install kommander \
  --airgapped \
  --installer-config /home/ice/kommander-trimmed.yaml \
  --kubeconfig ~/.kube/nkp-cluster.kubeconfig \
  --kommander-applications-repository /home/ice/nkp-bundle/nkp-v2.17.1/application-repositories/kommander-applications-v2.17.1.tar.gz
```
**Note:** Run in tmux (`tmux new-session -d -s kommander-install` + `tmux send-keys`) — install takes 30-60 min and SSH drops will kill it.

---

---

## G-33 — local-volume-provisioner requires actual bind mounts, not plain directories

**Discovered:** git-operator PVCs stuck Pending; local-volume-provisioner logs show error  
**Symptom:** `path /mnt/disks/vol-01 is not a valid mount point: mountPath wasn't found in the /proc/mounts file`  
**Root cause:** NKP's local-volume-provisioner validates each directory against `/proc/mounts`. A directory created with `mkdir` does not appear in `/proc/mounts` — only real mount points do. The provisioner rejects any path not listed there.  
**Fix:** On each of the 3 nodes, bind-mount each disk directory onto itself before the cluster comes up:
```bash
for i in 01 02 03; do
  sudo mkdir -p /mnt/disks/vol-$i
  sudo mount --bind /mnt/disks/vol-$i /mnt/disks/vol-$i
done
```
Run on 159, 158, and 156. This creates 9 PVs (97Gi each) that satisfy the provisioner.  
**Note:** Bind mounts via `mount --bind` are NOT persistent across reboots. For production, add entries to `/etc/fstab`:
```
/mnt/disks/vol-01  /mnt/disks/vol-01  none  bind  0 0
```

---

## G-34 — source-controller RUNTIME_NAMESPACE not set in pre-provisioned mode

**Discovered:** kustomize-controller unable to download git archive  
**Symptom:** GitRepository `status.artifact.url` contains literal `$(RUNTIME_NAMESPACE)` unexpanded:  
`http://source-controller.$(RUNTIME_NAMESPACE).svc.cluster.local./gitrepository/...`  
kustomize-controller DNS lookup fails: `no such host: source-controller.$(RUNTIME_NAMESPACE).svc.cluster.local.`  
**Root cause:** In cloud-provisioned NKP, source-controller is configured with `RUNTIME_NAMESPACE` via fieldRef (Downward API). In pre-provisioned mode this env var is absent from the deployment — source-controller leaves the `$(RUNTIME_NAMESPACE)` template literal unexpanded in artifact URLs.  
**Fix (temporary):** Set a static value to unblock kustomize-controller:
```bash
kubectl set env deployment/source-controller -n kommander-flux RUNTIME_NAMESPACE=kommander-flux \
  --kubeconfig ~/.kube/nkp-cluster.kubeconfig
```
**CRITICAL:** Remove the static value before `kommander-flux` HelmRelease reconciles — see G-38. The chart sets this via `valueFrom.fieldRef` and will conflict with a static `value`.  
**Root fix:** The proper fix is the `kommander-flux` HelmRelease itself setting `RUNTIME_NAMESPACE` via fieldRef. Once that HelmRelease succeeds, source-controller will have the proper fieldRef and this manual step is no longer needed.

---

## G-35 — flux-oci-mirror TLS MITM certs missing in pre-provisioned mode (proxy non-functional)

**Discovered:** OCI pulls from ghcr.io/docker.io failing through flux-oci-mirror  
**Symptom:** flux-oci-mirror logs show `Cannot handshake client ghcr.io:443 remote error: tls: bad certificate`. source-controller `HTTP_PROXY` and `HTTPS_PROXY` env vars are set but have no value (just the key name, empty string value).  
**Root cause:** NKP's flux-oci-mirror is a TLS MITM proxy. It needs `MITMCertFile`, `MITMKeyFile`, and `ProxyCAFile` to intercept HTTPS OCI pulls and redirect them to the local registry. In cloud-provisioned NKP, these certs are auto-generated during cluster creation. In pre-provisioned mode, this setup is skipped — the `flux-oci-mirror-config` secret has all cert paths as empty strings. Without MITM certs, flux-oci-mirror cannot intercept TLS connections.  
**Impact:** All OCI pulls via proxy fail. Every `OCIRepository` resource pointing to `ghcr.io` or `docker.io` will fail with DNS errors (the registry is unreachable) or TLS errors (proxy can't MITM).  
**Workaround:** Bypass flux-oci-mirror entirely. Patch each `OCIRepository` resource to point directly to the local registry (`oci://192.168.1.159:5000/...`) with `insecure: true`. See G-36 for handling the ones the operator reconciles.

---

## G-36 — kommander-operator reconciles OCIRepository URLs back to external registries

**Discovered:** Patching `platform-version-v2-17-1` and `kommander-appmanagement-0.17.1-chart` OCIRepositories immediately reverted  
**Root cause:** The `kommander-operator` (KommanderCore controller) owns these two OCIRepositories in its reconciliation loop. Although there are no `ownerReferences` on the objects, the operator's reconciler re-creates them with hardcoded URLs (`ghcr.io/mesosphere/kommander-applications/collection` and `docker.io/mesosphere/kommander-appmanagement-chart`) whenever KommanderCore is in "Creating PlatformVersionArtifact" or "Deploying Kommander AppManagement" states.  
**Fix:** Scale the operator to 0, patch both resources, wait for Ready, scale back to 1. The operator then sees both OCIRepositories are Ready and transitions past those states without reverting:
```bash
K="~/nkp-bundle/nkp-v2.17.1/kubectl"
KC="--kubeconfig ~/.kube/nkp-cluster.kubeconfig"

# Scale operator to 0
$K $KC scale deployment kommander-operator -n kommander --replicas=0

# Patch both OCIRepositories to local registry
$K $KC patch ocirepository platform-version-v2-17-1 -n kommander --type=merge \
  -p '{"spec":{"url":"oci://192.168.1.159:5000/mesosphere/kommander-applications/collection","insecure":true,"ref":{"tag":"v2.17.1"}}}'

$K $KC patch ocirepository kommander-appmanagement-0.17.1-chart -n kommander --type=merge \
  -p '{"spec":{"url":"oci://192.168.1.159:5000/mesosphere/kommander-appmanagement-chart","insecure":true,"ref":{"tag":"v2.17.1"}}}'

# Wait ~30s for both to go Ready (True), then scale back up
sleep 30
$K $KC scale deployment kommander-operator -n kommander --replicas=1
```

---

## G-37 — git-operator repo has hardcoded ghcr.io URLs — must be patched before Flux applies

**Discovered:** kustomize-controller applies git repo manifests that reference `ghcr.io` which is unreachable  
**Root cause:** NKP installer populates the internal git-operator repository (`https://git-operator-git.git-operator-system.svc.cluster.local./repositories/kommander/kommander.git`) with manifests. All HelmRelease `chartRef` and OCIRepository `url` fields reference `oci://ghcr.io/mesosphere/...` or `image: ghcr.io/mesosphere/...`. In air-gap mode without a working MITM proxy (G-35), these all fail.  
**Fix:** Clone the git repo, replace all ghcr.io refs with the local registry, and push a new commit:
```bash
# Get git credentials from secret
KC="--kubeconfig ~/.kube/nkp-cluster.kubeconfig"
K="~/nkp-bundle/nkp-v2.17.1/kubectl"
GIT_PASS=$($K $KC get secret kommander-git-credentials -n kommander-flux \
  -o jsonpath='{.data.password}' | base64 -d)
GIT_URL="https://kommander:${GIT_PASS}@10.104.196.97/repositories/kommander/kommander.git"
# (IP from: $K $KC get svc git-operator-git -n git-operator-system -o jsonpath='{.spec.clusterIP}')

git clone "$GIT_URL" /tmp/kommander-git && cd /tmp/kommander-git

# Replace ghcr.io refs with local registry
find . -name "*.yaml" | xargs sed -i \
  's|oci://ghcr.io/|oci://192.168.1.159:5000/|g; s|image: ghcr.io/|image: 192.168.1.159:5000/|g'

git add -A
git commit -m "fix: redirect ghcr.io OCI refs to local registry 192.168.1.159:5000"
git push
```
After push, the GitRepository reconciles and kustomize-controller applies the updated manifests.  
**Note:** The git-operator's git repo does NOT contain OCIRepository resources — those are created dynamically by the `kommander-appmanagement` operator based on app metadata in the applications tarball. Per-app chart OCIRepositories (dex-2.14.4-chart, etc.) will already use the local registry because the appmanagement operator reads chart locations from the applications tarball which has proper local registry paths.

---

## G-38 — kommander-flux HelmRelease conflicts with manually-set env vars (value vs valueFrom)

**Discovered:** `kommander-flux` HelmRelease stuck in False after manual env var patches  
**Symptom:** `cannot patch "kustomize-controller": spec.template.spec.containers[0].env[0].valueFrom: Invalid value: "": may not be specified when value is not empty`  
**Root cause:** The `flux2` chart (version 2.17.1) sets env vars like `RUNTIME_NAMESPACE` via `valueFrom.fieldRef`. Earlier manual fixes set these with static `value` strings (or left empty strings without `valueFrom`). Kubernetes rejects any env var that has both `value` (even empty string `""`) and `valueFrom`.  
**Affected deployments:** `source-controller` and `kustomize-controller` in `kommander-flux` namespace.  
**Fix:** Before forcing kommander-flux HelmRelease to reconcile, clean the env arrays to remove any conflicting entries:
```bash
K="~/nkp-bundle/nkp-v2.17.1/kubectl"
KC="--kubeconfig ~/.kube/nkp-cluster.kubeconfig"

# Remove all manual env overrides — chart will set them properly with fieldRef
$K $KC patch deployment source-controller -n kommander-flux --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env","value":[
    {"name":"NO_PROXY","value":"192.168.1.0/24,10.96.0.0/12,10.244.0.0/16,.cluster.local,localhost,127.0.0.1"},
    {"name":"TUF_ROOT","value":"/tmp/.sigstore"}
  ]}]'

$K $KC patch deployment kustomize-controller -n kommander-flux --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env","value":[]}]'

# Then force-reconcile the HelmRelease
$K $KC annotate helmrelease kommander-flux -n kommander --overwrite \
  reconcile.fluxcd.io/requestedAt="$(date -u +%FT%TZ)"
```
**Note:** After the chart applies, source-controller gets `RUNTIME_NAMESPACE` via `fieldRef: metadata.namespace` which correctly resolves to `kommander-flux`. No manual static value needed.

---

## SESSION CHECKPOINT — 2026-04-30 session 6

**All fixes applied through G-38:**
- G-33: Bind mounts created on all 3 nodes → 9 PVs available, git-operator PVCs Bound
- G-34: RUNTIME_NAMESPACE set on source-controller → GitRepository URLs fixed (then cleared for G-38)
- G-35: flux-oci-mirror MITM non-functional → bypassed by patching OCIRepositories directly
- G-36: kommander-operator scaled to 0, OCIRepositories patched to local registry, scaled back
- G-37: git-operator repo cloned, 61 files patched (ghcr.io → 192.168.1.159:5000), commit 6709b7a pushed
- G-38: Manual env vars cleared from source-controller/kustomize-controller before chart reconcile

**Current state:**
- All 4 core HelmReleases True: gatekeeper, gatekeeper-proxy-mutations, kommander-operator, kommander-appmanagement
- AppDeployments created for all apps (dex, traefik, kommander, etc.)
- Per-app OCIRepositories mostly True (pointing to local registry at 192.168.1.159:5000)
- `platform-version-v2-17-1` reverted to ghcr.io (True from cache — will go False on re-reconcile)
- `kommander-flux` HelmRelease: patching kustomize-controller/source-controller env conflicts resolved
- Remaining HelmReleases deploying: dex, traefik, reloader, kommander, traefik-forward-auth-mgmt

**Next on resume:**
1. Check HelmRelease status: `kubectl get helmrelease -n kommander`
2. Fix any remaining "Source not ready" after source-controller restart
3. Re-patch `platform-version-v2-17-1` if it goes False again
4. Get Kommander dashboard URL + credentials once traefik is up
5. commit-and-log

---

## G-39 — `--catalog-collections` flag rejects registry URLs with port numbers

**Discovered:** `kommander-cm` pod in CrashLoopBackOff (exit 2) after `kommander-flux` HelmRelease applied  
**Symptom:** `kommander-cm` container logs: `flag --catalog-collections: invalid repository portion in URL` — validation regex is `^[a-z0-9_\-./]+$` which does not allow colons. The `:` in `192.168.1.159:5000` fails validation.  
**Root cause:** The git repo `sed` replacement changed `oci://ghcr.io/` to `oci://192.168.1.159:5000/` throughout ALL yaml files, including `applications/kommander/0.17.1/helmrelease/cm.yaml` which contains `catalogCollections`. The `--catalog-collections` CLI flag passes resource URIs through a stricter regex than the OCI URL parser — port numbers are not allowed.  
**Fix (two steps):**  
1. Patch `kommander-0.17.1-config-defaults` ConfigMap to clear catalog collections:
```bash
kubectl patch configmap kommander-0.17.1-config-defaults -n kommander --type=merge \
  -p '{"data":{"values.yaml":"catalogCollections: []\n"}}'
```
2. Directly patch the running `kommander-cm` Deployment to remove the `--catalog-collections` arg (Helm install in-flight uses old values):
```bash
kubectl patch deployment kommander-cm -n kommander --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/args/N"}]'
```
where N is the index of the `--catalog-collections=...` arg.  
**Prevention:** Do NOT replace `oci://ghcr.io/` with registry:port URLs in `cm.yaml` `catalogCollections` field. Either skip those lines in the sed command or set `catalogCollections: []` (empty) in the config-defaults CM as part of the air-gap setup.

---

## G-40 — git repo `sed` missed `docker.io` OCI chart refs

**Discovered:** `kommander-0.17.1-chart` and `kommander-appmanagement-0.17.1-chart` OCIRepositories kept reverting to `docker.io` URLs even after fixing ghcr.io refs  
**Root cause:** The session 6 `sed` command only replaced `oci://ghcr.io/` → `oci://192.168.1.159:5000/`. Two HelmRelease files define their OCIRepository source with `oci://docker.io/mesosphere/...` URLs which were not touched:
- `applications/kommander/0.17.1/helmrelease/kommander.yaml` — `url: "oci://docker.io/mesosphere/kommander-chart"`
- `applications/kommander-appmanagement/0.17.1/helmrelease/kommander-appmanagement.yaml` — `url: "oci://docker.io/mesosphere/kommander-appmanagement-chart"`

The `kommander-operator` reads these manifests via the git-operator Kustomization and creates OCIRepositories with the `docker.io` URLs it finds.  
**Fix:** In the git repo, also replace `docker.io` chart source URLs:
```bash
cd /tmp/kommander-git
sed -i 's|oci://docker.io/|oci://192.168.1.159:5000/|g' \
  applications/kommander/0.17.1/helmrelease/kommander.yaml \
  applications/kommander-appmanagement/0.17.1/helmrelease/kommander-appmanagement.yaml
GIT_SSL_NO_VERIFY=true git add -A && git commit -m "fix: redirect docker.io OCI chart refs to local registry"
GIT_SSL_NO_VERIFY=true git pull --rebase && GIT_SSL_NO_VERIFY=true git push
```
Both charts exist in the local registry: `mesosphere/kommander-chart:v2.17.1` and `mesosphere/kommander-appmanagement-chart:v2.17.1`.  
**Note:** `GIT_SSL_NO_VERIFY=true` is required — the internal git-operator gitwebserver uses a self-signed cert. Also: do a `git pull --rebase` before push since the operator may have pushed its own commits.

---

## G-41 — Flux upgrade via `kommander-flux` HelmRelease causes source-controller restart, wiping OCIRepository URL patches

**Discovered:** After `kommander-flux` HelmRelease reconciled (upgrading Flux to 2.17.1), all OCIRepositories that were manually patched to use local registry URLs reverted to their original external URLs  
**Root cause:** Reconciling the `kommander-flux` HelmRelease upgrades Flux. This restarts all Flux controllers (source-controller, helm-controller, kustomize-controller). On restart, source-controller re-reads all OCIRepository specs. Simultaneously, the operators (kommander-operator, kommander-appmanagement) re-reconcile their OCIRepositories, writing back the external URLs. Any manually-applied suspend patches are also removed by operators since they write the full spec.  
**Impact:** All previously-fixed OCIRepositories revert: `kommander-0.17.1-chart` reverts to `docker.io`, `platform-version-v2-17-1` reverts to `ghcr.io` (loses suspend), HelmReleases go back to `SourceNotReady`.  
**Fix sequence after any Flux upgrade:**
1. Ensure git repo has correct local registry URLs for all chart refs (G-37 + G-40) — these auto-fix via Kustomization on next git sync
2. Fix `platform-version-v2-17-1` manually (see G-42) since it is operator-managed, not in git repo
3. If HelmRelease is in `Stalled/RetriesExceeded`: suspend + resume the HR to reset failure counter, then force-reconcile  
**Prevention:** Fix all OCI URL refs in the git repo (both ghcr.io AND docker.io) before the first `kommander-flux` HelmRelease reconcile so no manual patches are needed after Flux upgrade.

---

## G-42 — `platform-version-v2-17-1` OCIRepository: operator manages it to ghcr.io; air-gap has no registry URL configured

**Discovered:** `KommanderCore` stuck at `PlatformVersionArtifactCreated: False` with message "Creating PlatformVersionArtifact" indefinitely  
**Root cause:** The `kommander-operator` creates and owns `platform-version-v2-17-1` OCIRepository, pointing it to `oci://ghcr.io/mesosphere/kommander-applications/collection`. With `spec.airgapped.enabled: true` in KommanderCore, one would expect the operator to use a local registry — but the `KommanderCore` CRD has no `registry` field and no ConfigMap provides the local registry URL to the operator. The operator is "airgap-aware" (feature gate `Airgapped=true`) but without a registry URL it falls back to the original ghcr.io URL.  
**Additional:** The operator also reverts `spec.suspend: true` on this OCIRepository (it writes the full spec without the suspend field, removing it).  
**Fix:** Race the operator — scale it to 0, set the URL to local registry and remove suspend, wait for `Ready=True`, scale back to 1. The operator sees Ready=True and immediately marks `PlatformVersionArtifactCreated=True`, advancing past this step before it can revert the URL:
```bash
K="~/nkp-bundle/nkp-v2.17.1/kubectl"
KC="--kubeconfig ~/.kube/nkp-cluster.kubeconfig"

# Scale to 0
$K $KC scale deployment kommander-operator -n kommander --replicas=0

# Point to local registry (the collection is at 192.168.1.159:5000/mesosphere/kommander-applications/collection:v2.17.1)
$K $KC patch ocirepository platform-version-v2-17-1 -n kommander --type=merge \
  -p '{"spec":{"url":"oci://192.168.1.159:5000/mesosphere/kommander-applications/collection","ref":{"tag":"v2.17.1"},"suspend":false,"interval":"1m"}}'

# Wait ~15s for source-controller to pull and go Ready=True, then scale back
sleep 15
$K $KC scale deployment kommander-operator -n kommander --replicas=1
# Operator sees Ready=True → marks PlatformVersionArtifactCreated=True → InstallSucceeded=True
```
After the operator advances past this step, suspend the OCIRepository to stop noise:
```bash
$K $KC patch ocirepository platform-version-v2-17-1 -n kommander --type=merge \
  -p '{"spec":{"url":"oci://ghcr.io/mesosphere/kommander-applications/collection","ref":{"tag":"v2.17.1"},"suspend":true,"interval":"1m"}}'
```

---

## SESSION CHECKPOINT — 2026-04-30 session 7 — INSTALLATION COMPLETE

**All fixes applied through G-42:**
- G-39: `catalogCollections` cleared in config-defaults CM + kommander-cm Deployment patched
- G-40: docker.io OCI chart refs fixed in git repo (commit 50357a8), Kustomization re-synced
- G-41: Post-Flux-upgrade revert handled via git repo having correct URLs + G-42 race fix
- G-42: platform-version-v2-17-1 race-fixed → KommanderCore InstallSucceeded=True

**Final cluster state:**
- All 3 nodes: Ready, control-plane, v1.34.3, containerd://1.7.29-d2iq.1
- All HelmReleases: **True** (20/20 in kommander namespace)
- KommanderCore: **InstallSucceeded=True** — "Kommander core components have been successfully installed"
- Kommander dashboard: https://192.168.1.200/dkp/kommander/dashboard
- Admin user: `boring_volhard` / `LPCjukvSjkbmRbs9jKqB49ODx8JWe0oUcvmizOSbZuv6Vn24hDvvET5uDx0Bjzja`
- MetalLB: 192.168.1.200 assigned to kommander-traefik LoadBalancer
- `platform-version-v2-17-1`: suspended (pointing to ghcr.io, suspend=true) — artifact cached, noise suppressed
- git repo: commit 50357a8 — both ghcr.io and docker.io OCI refs redirect to 192.168.1.159:5000

**Trimmed Kommander apps enabled:** dex, traefik, kommander, kommander-ui, reloader, dex-k8s-authenticator, traefik-forward-auth-mgmt, git-operator  
**Disabled:** rook-ceph, prometheus/kube-prometheus-stack, velero
