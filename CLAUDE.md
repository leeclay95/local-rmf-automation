# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Not an application — an **operations lab**. It stands up STIG Manager + Keycloak
on two emulated EKS clusters inside a local AWS emulator (**Floci**, the `floci`
container), so there is no build, no lint and no unit-test suite. `terraform
validate`, `bash -n` and `scripts/08-verify.sh` are the only checks that exist.

There is **no git repository here**. Edits are live against a running lab; there
is no commit to fall back to, so prefer reversible changes and keep a `.bak`
copy of any file you rewrite in place.

Docs are split in two, and both are kept deliberately current:

- **`README.md`** — public-facing: what the project is, prerequisites, the
  architecture diagram, quickstart, repo layout. Keep it short; it is the front
  page.
- **`TROUBLESHOOTING.md`** (~1200 lines) — the operational manual: a thorough
  Troubleshooting table, the 13-step verification walkthrough, per-symptom
  sections, and the MySQL/Keycloak inspection commands.

**Read the relevant `TROUBLESHOOTING.md` section before diagnosing anything** —
most failure modes here are already written up with their root cause. When you
fix something new, add it to the Troubleshooting table and that file's Contents
list. Cross-links from README use `TROUBLESHOOTING.md#anchor`, so check them after
renaming a heading.

## Commands

Everything begins with `source env.sh`. It repoints `AWS_CONFIG_FILE`,
`AWS_SHARED_CREDENTIALS_FILE` and `KUBECONFIG` at lab-local files so the lab can
never read `~/.aws` or `~/.kube`, and sets `AWS_ENDPOINT_URL=http://localhost:4566`.
Every script sources it itself; an interactive shell must do it by hand.

**Prefer `make`.** Every target sources `env.sh` itself, so a bare `make up`
works from a clean shell. `make help` lists all of them; the wrapper never
reimplements a step, it shells out to the script that already does it.

```bash
make preflight                          # required tools present?
make up                                 # full bring-up / after a reboot; idempotent
make verify                             # the test suite: 13 checks, exit 0 = healthy
make down                               # stop, keep state
make destroy                            # terraform destroy, then stop
make purge                              # also delete Floci state, k3s volumes, certs
make validate                           # terraform validate + bash -n on every script
make db Q="SELECT name FROM collection;"
make keycloak-config                    # clients, users, scopes in the stigman realm
```

Add `AUTO=1` to skip terraform approval prompts (`make infra AUTO=1`).

Working by hand instead still requires `source env.sh` first:

```bash
source env.sh
./scripts/00-up.sh
./scripts/08-verify.sh
```

Individual steps, in the order `00-up.sh` runs them (each has a `make` target
of the same name — `make iam`, `make infra`, `make eviction`, …):

```bash
./scripts/01-bootstrap-iam.sh           # mint the emulated IAM user (no-op if the key works)
./scripts/02-apply-infra.sh [-auto-approve]   # stage 1: VPC, IAM, EKS, ACM, ALB, Route53
python3 ./scripts/eviction_patch.py     # relax kubelet disk eviction (recreates k3s containers)
./scripts/03-kubeconfig.sh              # rewrite ./kubeconfig for both clusters
./scripts/04-apply-workloads.sh [-auto-approve]  # stage 2: Keycloak, MySQL, stigman-api, CoreDNS
./scripts/05-hosts.sh [--remove]        # /etc/hosts -> 127.0.0.1 (the only sudo in the lab)
./scripts/06-patch-eviction.sh          # eviction_patch.py + wait for both API servers
./scripts/07-keycloak-client.sh         # narrow the Keycloak client's redirect URIs
```

**Never run `terraform apply` directly in `terraform/01-infra`.** It requires
`-var floci_network_ip=…`, which `scripts/02-apply-infra.sh` discovers with
`docker inspect floci`. Use the script. Stage 2 takes no such variable, but
`04-apply-workloads.sh` is still the right entry point because it sources
`env.sh` for the exec-credential plugin.

Running one verify check in isolation: there is no flag for it: `08-verify.sh`
is a linear script of numbered `step` blocks. Copy the block you want, or read
the matching `### N.` subsection of the README, which gives each check as a
standalone command.

```bash
kubectl --context keycloak -n keycloak get pods     # contexts are 'keycloak' and 'stigman'
kubectl --context stigman  -n stigman  logs -l app=stigman-api --tail=50 | jq .
curl --cacert certs/lab-ca.crt https://stigman.mil/api/op/configuration
```

## Architecture

Two Terraform root modules, deliberately split:

- **`terraform/01-infra`** — the AWS layer. Every service endpoint is pinned to
  `var.floci_endpoint` in `provider.tf`, because `AWS_ENDPOINT_URL` alone is not
  honoured by all of the provider's service clients.
- **`terraform/02-workloads`** — the Kubernetes layer. It reads stage 1's state
  through `data.terraform_remote_state.infra` (local backend, path to stage 1's
  `terraform.tfstate`). The split is not stylistic: the `kubernetes` provider is
  configured from the cluster endpoint and CA, which do not exist at plan time
  on a clean checkout.

Shared values flow **one way only**, stage 1 outputs → stage 2 `local.infra`
(cluster endpoints/CAs, `oidc_issuer`, `keycloak_node_port`, `stigman_node_port`,
`floci_network_ip`). Add a new cross-stage value as a stage 1 output; never
duplicate a literal.

### The OIDC triangle — the part that breaks

Keycloak must issue tokens whose `iss` is *exactly* what the STIG Manager API
expects, and the browser must be sent to that same URL. So `https://keycloak.mil`
has to resolve **both from the host and from inside the stigman cluster**:

| Resolver | Mechanism | File |
|---|---|---|
| Host browser / curl | `/etc/hosts` → `127.0.0.1` | `scripts/05-hosts.sh` |
| k3s containers | Route53 private zone → `floci_network_ip` | `01-infra/06-dns.tf` |
| Pods | `coredns-custom` ConfigMap, `mil:53` forward | `02-workloads/03-coredns.tf` |

Both paths arrive at Floci's `:443`. Four settings hold it together, and
changing any one silently breaks login *after* a successful-looking auth:
`KC_HOSTNAME` / `KC_HOSTNAME_ADMIN` pinned to `https://keycloak.mil`
(`01-keycloak.tf`), `preserve_host_header = true` on both ALBs (`05-alb.tf`),
and `STIGMAN_OIDC_PROVIDER` + `STIGMAN_CLIENT_OIDC_PROVIDER` both set from
`local.infra.oidc_issuer` (`02-stigman.tf`). The API will not report Ready until
OIDC discovery through the ALB succeeds — a stuck `stigman-api` is usually a
Keycloak or ALB problem, not a stigman problem.

### Floci's three emulation seams

These shape most of the design, and most of the bugs:

1. **One k3s container per cluster is the control plane *and* the only node.**
   `aws_eks_node_group` is metadata that sets labels, taints and the container's
   CPU/memory ceiling (`node_instance_type` is a real constraint on this host) —
   it does not add machines.
2. **Cluster addons are recorded, never installed.** `aws-ebs-csi-driver` creates
   no CSI pods, so a `gp2` PVC sits Pending forever. `storage_class` must stay
   `local-path` (k3s's provisioner, enabled by
   `FLOCI_SERVICES_EKS_DEFAULT_STORAGE_CLASS`).
3. **ALB target groups must use `target_type = "ip"`.** Floci's data plane hands
   an instance-id target straight to DNS, so `"instance"` does not work. The
   addresses come from `data "aws_instances"` filtered on the
   `eks:cluster-name` tag (`03-eks.tf`).

The AWS Load Balancer Controller is replaced by Terraform creating the ALBs
directly, which is why the Services are **NodePort** (pinned 30080 / 30540) and
not ClusterIP + Ingress.

### SNI: both ALBs share one `:443` socket

Floci's ELBv2 is a real TLS-terminating proxy and picks the load balancer from
the SNI name. Consequences worth remembering before chasing a "fault":

- `https://<ip>` → **502**. Always use the hostname.
- `http://<host>:8080` → **502**, permanently. Plain HTTP carries no SNI and two
  ALBs share port 80. Expected, not a bug.
- Host `:80` is taken by `apache2`, hence the `8080:80` mapping in `docker-compose.yml`.
- Keycloak answers `/` with a 302, so the health matcher is `200,301,302`.

### Why a restart needs more than `docker compose up -d`

Floci reassigns two things when containers are recreated, and the lab's state
outlives both:

1. **k3s API server host ports** (6500–6599, order not stable) — an existing
   kubeconfig points at the wrong port.
2. **Node container IPs** — the ALB target groups registered the old address.

A single stale target returns **503 on both hostnames**, because stigman-api
reaches Keycloak through the ALB. Pods look perfectly healthy. Fix:
`./scripts/02-apply-infra.sh -auto-approve` (expect a plan of exactly
`2 to add, 0 to change, 2 to destroy`). `08-verify.sh` step 8 compares the
registration against the live address and says so explicitly.

This is also why ordering in `00-up.sh` is load-bearing: `eviction_patch.py`
**recreates the k3s containers**, so it must run *before* the final stage 1
reconcile and before the kubeconfig is written. Stage 1 is applied twice on
purpose.

`scripts/eviction_patch.py` rewrites the immutable `Cmd` of each k3s container
(Floci pins `nodefs.available<10%`, several GB on a large disk → spurious
DiskPressure). `eviction-hard` is on Floci's managed-flag list, so the
documented `floci:kubelet-arg:` tag passthrough refuses to override it. The
script talks to the Docker Engine API and carefully preserves the container
name, Floci labels, volumes, published port, **network IP**, and four files Floci
injects after creation (`/etc/sa-signing-key.pem`, `/etc/sa-public-key.pem`,
`/etc/token-webhook.yaml`, `/etc/rancher`). Read its docstring before touching it.

### Authentication is genuinely real

`aws eks get-token` produces a SigV4-presigned STS `GetCallerIdentity` request
that Floci's token webhook verifies against a key in its own IAM store. The
throwaway `test`/`test` key Floci accepts on its REST surface is **not** in that
store, hence `scripts/01-bootstrap-iam.sh`. `03-kubeconfig.sh` pins the lab's
credential files into each context's `exec-env` so the plugin cannot inherit an
unrelated `AWS_PROFILE` and sign with the wrong key.

## Staying clone-portable

This is a public repo others clone, so nothing may depend on the checkout path or
the directory name:

- **The Docker network name is pinned, not derived.** Compose defaults the project
  name to the containing folder, which would rename the network on any clone into
  a differently-named directory and break Floci's
  `FLOCI_SERVICES_DOCKER_NETWORK`, the ALB target lookups and the teardown.
  `docker-compose.yml` sets `name: stig-cloud-lab` and `env.sh` exports a matching
  `LAB_PROJECT`/`LAB_NETWORK`. **Change both together or neither**, and read the
  network name from `$LAB_NETWORK` in scripts — never inline it.
- Scripts derive their own root with
  `LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`. Keep that pattern;
  no absolute paths, and no assumption about the working directory.
- Docs use repo-relative paths and example host addresses, never a real one.
- A fresh clone has no `aws/credentials` (gitignored — it holds a minted key);
  `scripts/01-bootstrap-iam.sh` seeds it from `aws/credentials.example`. Anything
  else generated needs the same treatment, plus a `.gitkeep` if a directory must
  pre-exist.
- `scripts/10-fetch-stigs.sh` resolves the current DISA compilation by walking
  back month names from today, because the filename changes quarterly and there
  is no `latest` alias. Do not pin a version into it.

## Working in this repo

- **Comments explain *why*, not *what*.** Every `.tf` file and script opens with
  a block explaining the constraint that forced its shape, often naming the
  failure it prevents. Match that register; a change without its rationale is
  incomplete here.
- **The disk is tight** (~93% used, ~5 GB free) and kubelet's eviction threshold
  is `nodefs.available<1Gi`, so filling the disk re-breaks both clusters. Stream
  out of `stigs/library/*.zip` rather than extracting it (a full recursive
  extract is ~1.5–2 GB); `docker system df -v | grep floci-aws-eks` shows the
  per-cluster image stores.
- **Do not inject faults into the running lab** to prove a diagnostic works. Use
  read-only verification and say plainly when a code path is unexercised.
- **Key material lives in the working tree** — `aws/credentials`, `kubeconfig`,
  `evaluatestig.pem`, `es.cert.pem`, `keystore.p12`, and the CA private key in
  stage 1's `terraform.tfstate`. Never print their contents; `grep -E
  '^-----(BEGIN|END)'` and `openssl x509 -noout -subject` are enough to verify a
  file. `certs/lab-ca.crt` is public and safe to read.
- **The lab CA is not in the system trust store.** `curl --cacert
  certs/lab-ca.crt` works, but .NET/PowerShell, Python, Java and Node validate
  against the OpenSSL store, so clients fail TLS and often swallow the error —
  reporting success while nothing lands. Installing it is a system-wide change
  (`sudo cp certs/lab-ca.crt /usr/local/share/ca-certificates/stig-lab-ca.crt &&
  sudo update-ca-certificates`, `.crt` extension required) and needs explicit
  confirmation. `99-down.sh --purge` does **not** remove it again.
- `stigs/` holds DISA content the user imports themselves: `library/` the full
  compilation, `selected/` extracted product ZIPs, `xccdf/` the benchmark XML.
  Don't import on their behalf.

## Evaluate-STIG answer files

A `stig-answerfile-validation` skill holds the full rules for writing
`<ValidationCode>` with a test harness, but it lives outside the repository
(`.claude/` is gitignored), so do not assume it is present. One distinction is
worth stating here because it is the first thing to check when an answer file
"does not work", and because it looks identical to a broken validation script:

**`ExpectedStatus` must equal the status the scan actually produced for that
check on that host.** It is a hard gate at weight 0 — on a mismatch the
`<Answer>` is discarded before anything else is evaluated, the validation code
never runs, and nothing is logged. It also takes a **single value**; unlike
`Hostname`, `Instance`, `Database`, `Site` and `ResultHash`, it is not
comma-separated, so one `<Answer>` covers exactly one status.

Read the log to tell the two failures apart. `Answer key '<name>', index 'N'
selected` is written *before* the validation code executes:

| In the log for that Group ID | Meaning |
|---|---|
| No `Answer key ... selected` line | Selection failed — wrong `<Vuln ID>`, `ExpectedStatus` mismatch, or a populated `Hostname`/`ResultHash` that did not match. The code never ran. |
| `selected` then `Invalid ValidationCode object returned` | Code ran and returned the wrong type — stray pipeline output, or not a bool/`Valid`+`Results` hashtable. |
| `selected`, then nothing further | Code returned `$null`; the whole answer is discarded, not just the false branch. |

The trap is that a check's status is not stable across hosts, so neither is the
`ExpectedStatus` that matches it. Chrome V-221584 ("supported version") is the
worked example: its scan module sets `Open` only when *more than one* Chrome is
installed, and otherwise leaves the status at its initialized `Not_Reviewed` —
it never sets `NotAFinding`. So the same answer needs `ExpectedStatus="O"` on a
box with Chrome + Chrome Beta and `"NR"` on a box with one Chrome, and an answer
written for one silently stops applying on the other. Check what the scan module
assigns before setting the attribute, rather than copying a status from another
host or accepting the one `Evaluate-STIG_GUI.ps1` writes during a legacy
migration (it defaults rather than reading the host).

Also: leave `ResultHash` empty unless the answer should apply to one exact
observed output. It hashes the FindingDetails text, so for a version check it
changes on every update and takes the answer with it.
