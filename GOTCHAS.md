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

## G-22 — `--ssh-private-key-file` creates the SSH secret but does NOT wire it into PreprovisionedCluster/Template sshConfig

**Discovered:** CAREN logs show `"failed to get sshConfig secret: Secret \"\" not found"` — empty string secret name — despite `--ssh-private-key-file ~/.ssh/nkp_rsa` being passed.
**Impact:** PreprovisionedMachine controller cannot SSH into nodes. Cluster stuck at `WaitingForBootstrapData` indefinitely.
**Root cause:** `nkp create cluster preprovisioned` creates secret `nkp-cluster-ssh-key` (with `ssh-privatekey` + `ssh-publickey` data keys) but leaves `sshConfig.secretName` empty in the PreprovisionedCluster, PreprovisionedMachineTemplate, and PreprovisionedMachine objects.
**Fix:** After cluster create, patch all three objects:
```bash
KC="$HOME/nkp-bundle/nkp-v2.17.1/kubectl"
KCF="--kubeconfig=$HOME/.kube/nkp-bootstrap.kubeconfig"
for obj in \
  "preprovisionedmachine/nkp-cluster-control-plane-md7lg" \
  "preprovisionedmachinetemplate/nkp-cluster-control-plane" \
  "preprovisionedmachinetemplate/nkp-cluster-md-0"; do
  "$KC" $KCF patch "$obj" -n default --type=merge \
    -p '{"spec":{"sshConfig":{"secretName":"nkp-cluster-ssh-key"}}}'
done
"$KC" $KCF patch preprovisionedcluster nkp-cluster -n default --type=merge \
  -p '{"spec":{"sshConfig":{"secretName":"nkp-cluster-ssh-key"}}}'
```
**Note:** PreprovisionedMachine spec sshConfig path may differ — verify with `kubectl get preprovisionedmachine -o yaml` before patching.

---

## SESSION CHECKPOINT — 2026-04-29 session 2

**Completed this session:**
- All 3 nodes prereqs done (158 confirmed healthy post-reboot)
- Bundle extracted: `~/nkp-bundle/nkp-v2.17.1/` on 159
- Bootstrap created (no --bundle): KIND cluster on 159, kubeconfig `~/.kube/nkp-bootstrap.kubeconfig` → port 38077
- External registry: `registry:2` container on 159:5000 with 100 images (konvoy + kommander pushed via `nkp push bundle`)
- `nkp create cluster preprovisioned --self-managed` launched in tmux session `cluster-create` on 159
- Cluster stuck: PreprovisionedMachine can't get SSH secret (G-22 above)
- Patches applied to PreprovisionedMachineTemplate + PreprovisionedCluster; PreprovisionedMachine direct patch pending verification

**Current state:**
- tmux: `cluster-create` running `nkp create cluster` → `~/cluster-create.log` (39 lines, stuck at "Waiting for cluster infrastructure to be ready...")
- Bootstrap kubeconfig: `~/.kube/nkp-bootstrap.kubeconfig` → `https://127.0.0.1:38077`
- CAREN pod: `nkp-system/caren-controller-manager-5d46f9979d-w2h6n`
- SSH secret: `nkp-cluster-ssh-key` in `default` ns, has `ssh-privatekey` + `ssh-publickey`
- Script ready: `/tmp/full-spec.sh` on 159 — run to get PreprovisionedMachine full yaml + CAREN logs

**Next on resume:**
1. Run `bash /tmp/full-spec.sh` on 159 to verify patch took effect + check if CAREN SSH errors cleared
2. If sshConfig still empty after patch: check exact spec field path from the yaml, re-patch correctly
3. Once SSH secret wired: CAREN will SSH into 159 → install containerd from bundle → run kubeadm init
4. Monitor machines joining (158, 156 next)
5. Wait for `EXIT:0` in `~/cluster-create.log` + cluster kubeconfig written
6. Untaint CP nodes, set up MetalLB IPAddressPool, install trimmed Kommander
7. commit-and-log

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
