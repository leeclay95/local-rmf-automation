# Local RMF Automation

**A complete STIG compliance pipeline — scanner to dashboard — running entirely on one laptop, with no AWS account, no cost, and no network egress.**

<p align="center">
  <img alt="RMF Automation" src="https://img.shields.io/badge/RMF-Automation-0A3161?style=for-the-badge&labelColor=0A3161">
  <img alt="DISA STIG" src="https://img.shields.io/badge/DISA-STIG-B31942?style=for-the-badge&labelColor=B31942">
  <img alt="Compliance as Code" src="https://img.shields.io/badge/Compliance-as%20Code-1F6FEB?style=for-the-badge">
  <img alt="Infrastructure as Code" src="https://img.shields.io/badge/Infrastructure-as%20Code-5C4EE5?style=for-the-badge">
</p>

<p align="center">
  <img alt="Terraform" src="https://img.shields.io/badge/Terraform-7B42BC?style=flat-square&logo=terraform&logoColor=white">
  <img alt="AWS" src="https://img.shields.io/badge/AWS%20(emulated)-232F3E?style=flat-square&logo=amazonwebservices&logoColor=FF9900">
  <img alt="EKS" src="https://img.shields.io/badge/EKS-FF9900?style=flat-square&logo=amazonwebservices&logoColor=white">
  <img alt="Kubernetes" src="https://img.shields.io/badge/Kubernetes-326CE5?style=flat-square&logo=kubernetes&logoColor=white">
  <img alt="Docker" src="https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker&logoColor=white">
  <img alt="Keycloak" src="https://img.shields.io/badge/Keycloak-4D4D4D?style=flat-square&logo=keycloak&logoColor=white">
  <img alt="OIDC" src="https://img.shields.io/badge/OAuth2%20%2F%20OIDC-EB5424?style=flat-square&logo=auth0&logoColor=white">
  <img alt="MySQL" src="https://img.shields.io/badge/MySQL-4479A1?style=flat-square&logo=mysql&logoColor=white">
  <img alt="PowerShell" src="https://img.shields.io/badge/PowerShell-5391FE?style=flat-square&logo=powershell&logoColor=white">
  <img alt="Bash" src="https://img.shields.io/badge/Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white">
  <img alt="Linux" src="https://img.shields.io/badge/Linux-FCC624?style=flat-square&logo=linux&logoColor=black">
</p>

---

## What this is

Standing up an RMF toolchain to *practise* with is normally the hard part. STIG
Manager wants a database, an OIDC provider, a load balancer and TLS; doing it the
way it is really deployed means an AWS account, an ALB, two EKS clusters and a
bill. So most people learn the scanner and never see the pipeline.

This repository builds the whole thing locally. Terraform provisions a VPC, IAM
roles, **two EKS clusters**, ACM certificates, **two Application Load Balancers**
and a Route53 private zone — against [Floci](https://github.com/floci-io/floci),
a local cloud emulator — then deploys Keycloak, MySQL and the STIG Manager API
onto the clusters and wires up the full OIDC flow.

One command brings it up:

```bash
make up
```

You end up at **https://stigman.mil** and **https://keycloak.mil** in your
browser, log in through a real OIDC authorization-code flow, and import scan
results from [Evaluate-STIG](https://github.com/cd-public/Evaluate-STIG) running
on any host that can reach the box.

### Why it is worth building this way

The emulation is not a set of stubs. The two clusters are **real Kubernetes** —
Floci backs each with a k3s container and a live API server, so Deployments,
Services, PVCs and CoreDNS all behave normally. The load balancers are a **real
proxy** — Floci's ELBv2 terminates TLS with the ACM certificate, selects the load
balancer by SNI and forwards to registered targets. EKS authentication is
**genuinely real**: `aws eks get-token` produces a SigV4-presigned STS
`GetCallerIdentity` request that Floci's webhook verifies against a key in its own
IAM store.

So the failures are real failures. A stale ALB target still returns 503, an
issuer mismatch still breaks login after a successful authentication, and a
missing CA in the system trust store still makes a scanner report success while
uploading nothing. Those are the lessons that transfer.

## What you can do with it

- **Run the full RMF loop** — scan a host with Evaluate-STIG, upload to STIG
  Manager over OIDC, review findings in the UI, query them in SQL.
- **Write and debug STIG answer files**, including PowerShell `<ValidationCode>`.
  A [Claude Code skill](.claude/skills/stig-answerfile-validation/) with a test
  harness ships in `.claude/skills/`.
- **Break it on purpose.** Every failure mode is documented with its symptom,
  root cause and fix in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
- **Read the Terraform** as a worked example of EKS + ALB + ACM + IRSA wiring,
  with the reasoning for each decision in the comments.

## Skills this exercises

| Area | Specifically |
|---|---|
| **RMF / compliance automation** | STIG Manager, Evaluate-STIG, DISA STIG benchmarks, answer files, CKL/CKLB/XCCDF, CAT I–III risk scoring |
| **Infrastructure as Code** | Terraform two-stage root modules, `terraform_remote_state`, provider endpoint overrides, generated TLS with the `tls` provider |
| **AWS architecture** | VPC and subnets, IAM roles and IRSA, EKS access entries, ACM, ALB target groups and listeners, Route53 private zones |
| **Kubernetes** | Deployments, NodePort Services, PVCs and StorageClasses, CoreDNS custom zones, readiness probes, kubelet eviction thresholds |
| **Identity** | Keycloak realms and clients, OAuth2 / OIDC authorization-code and password flows, `private_key_jwt` client assertions, scopes and JWT claims, issuer pinning |
| **PKI / TLS** | A private CA, leaf certificates, SNI-based routing, system trust stores across .NET, Java, Python and Node |
| **Containers** | Docker Compose, the Docker Engine API, bind mounts and named volumes, container recreation while preserving network identity |
| **Scripting** | Idempotent Bash bring-up, PowerShell validation code, Python against the Docker API |

## Architecture

```
                      your browser / curl
                              │
                  https://stigman.mil:443
                  https://keycloak.mil:443      (/etc/hosts -> 127.0.0.1)
                              │
                     Docker publishes :443
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ floci container — the emulated AWS                                       │
│                                                                          │
│   ELBv2 data plane, one shared :443 socket, load balancer chosen by SNI   │
│     ├── keycloak-alb  cert CN=keycloak.mil ──► keycloak-tg ──┐           │
│     └── stigman-alb   cert CN=stigman.mil  ──► stigman-tg  ──┼──┐        │
│                                                              │  │        │
│   ACM (real key material)   IAM / STS   Route53 "mil" zone   │  │        │
│   EKS control plane         EC2 (VPC 10.100.0.0/16)          │  │        │
│   embedded DNS :53  ── keycloak.mil / stigman.mil -> floci   │  │        │
└──────────────────────────────────────────────────────────────┼──┼────────┘
                                                               │  │
        ┌──────────────────────────────────────────────────────┘  │
        │ node:30080                                   node:30540 │
        ▼                                                         ▼
┌───────────────────────────────┐          ┌──────────────────────────────────┐
│ keycloak-eks  (k3s container) │          │ stigman-eks  (k3s container)     │
│ API server on localhost:65xx  │          │ API server on localhost:65xx     │
│                               │          │                                  │
│ ns keycloak                   │          │ ns stigman                       │
│  Deployment keycloak          │          │  Deployment stigman-api  :54000  │
│   stig-manager-auth           │◄─────────│   OIDC -> https://keycloak.mil   │
│   KC_PROXY=edge               │  OIDC    │  Deployment mysql        :3306   │
│  Service NodePort 30080       │          │  PVC mysql-pvc 20Gi (local-path) │
│                               │          │  Service NodePort 30540          │
│ coredns-custom: mil -> floci  │          │  coredns-custom: mil -> floci    │
└───────────────────────────────┘          └──────────────────────────────────┘
```

**The OIDC loop is the part worth understanding.** Keycloak must issue tokens
whose `iss` claim is exactly what the STIG Manager API expects, and the browser
must be sent to that same URL. So **both the host and the pods resolve
`keycloak.mil`** — the host through `/etc/hosts`, the pods through the Route53
private zone plus a CoreDNS override. Both arrive at Floci's `:443`, which picks
the Keycloak load balancer from the TLS SNI name.

That is also why the API will not report Ready until OIDC discovery succeeds
through the load balancer: a stuck `stigman-api` is usually a Keycloak or ALB
problem, not a STIG Manager one.

## Prerequisites

| Tool | Minimum | Notes |
|---|---|---|
| **Docker** | 24+ | The emulator and every cluster is a container. Daemon must be reachable by your user. |
| **Floci** | 2.4.0 server | The local cloud emulator. Pulled automatically as `floci/floci:latest`. |
| **Terraform** | 1.5+ | Two root modules under `terraform/`. |
| **kubectl** | 1.28+ | Two contexts, `keycloak` and `stigman`. |
| `jq`, `curl`, `python3` | — | Used by the scripts. |
| `sudo` | — | Only to add two lines to `/etc/hosts`. |
| **k9s** | any | Optional, cluster TUI. |
| **tfsec** | any | Optional, `make tfsec`. |

Check your box before starting:

```bash
make preflight
```

**Resources:** roughly **4 GB free RAM** and **6 GB free disk** beyond whatever
else is running. Two k3s containers plus MySQL is the bulk of it. Linux host, or
a Linux VM — the scripts assume a Linux userland and a Docker socket at
`/var/run/docker.sock`.

> **Disk space matters more than you would expect.** The bring-up relaxes
> kubelet's disk-eviction threshold to an absolute 1 GiB because Floci pins it to
> 10% of the host filesystem, which on a large disk is several gigabytes and
> evicts pods while there is plenty of room. If you genuinely fill the disk,
> both clusters go down.

## Quickstart

```bash
git clone https://github.com/leeclay95/local-rmf-automation.git
cd local-rmf-automation

make preflight          # are the tools there?
make up                 # the whole lab, ~10 min cold (Keycloak alone takes ~6)
```

`make up` is idempotent — re-run it any time, including after a reboot. It ends
by running the verifier, so a clean run finishes with `all 13 checks passed` and
prints where to log in:

```
STIG Manager  https://stigman.mil   (admin / password)
Keycloak      https://keycloak.mil  (admin / Pa55w0rd)
```

Your browser will warn about the certificate until you trust the generated CA at
`certs/lab-ca.crt` — see
[Trusting the certificate](TROUBLESHOOTING.md#trusting-the-certificate).

### Everyday commands

```bash
make verify             # 13-step end-to-end check; non-zero exit on failure
make urls               # URLs and credentials
make pods               # pods in both clusters
make logs               # tail the STIG Manager API log
make db-shell           # MySQL shell in the stigman cluster
make db Q="SELECT name FROM collection;"
make keycloak-config    # clients, users and scopes in the stigman realm
make token              # mint an OIDC access token for the API
make down               # stop, keep all state
```

`make help` lists everything. `make purge` is the full reset — it deletes Floci's
state, the k3s volumes, the certificates and the kubeconfig.

### Getting STIG content

DISA content is not redistributed here. Fetch the current compilation yourself:

```bash
make stig-library       # ~375 MB; resolves the current filename automatically
```

Then import through the STIG Manager UI, or extract a single product's XCCDF —
the script prints the two `unzip` commands that do it without unpacking ~1.5 GB.

## Repository layout

```
Makefile                     lifecycle wrapper; `make help` lists every target
docker-compose.yml           the Floci emulator, its ports and persistence
env.sh                       points this shell at Floci ONLY (see the note below)
scripts/
  00-up.sh                   the whole bring-up, in order — the order matters
  01-bootstrap-iam.sh        mints the emulated IAM user that signs EKS tokens
  02-apply-infra.sh          stage 1, with Floci's network address discovered
  03-kubeconfig.sh           writes ./kubeconfig for both clusters
  04-apply-workloads.sh      stage 2
  05-hosts.sh                /etc/hosts entries (the only sudo in the project)
  06-patch-eviction.sh       relaxes kubelet's disk-eviction threshold
  07-keycloak-client.sh      narrows the Keycloak client's redirect URIs
  08-verify.sh               13 checks, bottom layer first
  10-fetch-stigs.sh          downloads the current DISA compilation
  99-down.sh                 stop / destroy / purge
  eviction_patch.py          rewrites the k3s containers' kubelet flags
terraform/
  01-infra/                  VPC, IAM, EKS, ACM, ALBs, Route53
  02-workloads/              Keycloak, MySQL, stigman-api, CoreDNS overrides
.claude/skills/              STIG answer-file validation skill + test harness
TROUBLESHOOTING.md           every failure mode, and the verification walkthrough
```

### Your real credentials are never touched

`env.sh` redirects `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` and
`KUBECONFIG` at repo-local files, so nothing here can read `~/.aws/credentials`
or write `~/.kube/config`. It also sets `AWS_EC2_METADATA_DISABLED=true` so no
real instance-credential source can answer. Every credential in the lab is minted
by Floci's own IAM emulator and is valid nowhere else.

Every `make` target sources `env.sh` itself. If you work by hand, `source env.sh`
first.

## What is emulated, and what that costs you

Worth knowing before you trust a behaviour you see here:

| | |
|---|---|
| **Real** | Kubernetes API and objects, kubelet, CoreDNS, local-path volumes, TLS termination and SNI selection at the ALB, ACM key material, SigV4 EKS authentication, the full OIDC flow |
| **Metadata only** | `aws_eks_node_group` — one container is the control plane *and* the only node, so this sets labels, taints and the container's CPU/memory ceiling rather than adding machines |
| **Recorded but not installed** | Cluster addons. `aws-ebs-csi-driver` creates no CSI pods, so a `gp2` claim sits Pending forever and volumes use k3s's `local-path` instead |
| **Replaced** | The AWS Load Balancer Controller. Terraform creates the ALBs directly, so Services are NodePort rather than ClusterIP + Ingress. The resulting AWS objects are the same shape |
| **Not durable** | Keycloak runs in dev mode on in-memory H2. Realm changes made through the admin console or `kcadm` do not survive a pod restart — that is why `scripts/07-keycloak-client.sh` exists |

## Troubleshooting

Start with `make verify`. The step that fails names the section to read in
**[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**, which covers, among others:

- [Both web UIs say "unavailable" / `503` after a restart](TROUBLESHOOTING.md#both-web-uis-say-unavailable--503-after-a-restart) — almost always a stale ALB target IP, and one stale target 503s *both* hostnames
- [A client "succeeds" but nothing arrives](TROUBLESHOOTING.md#a-client-succeeds-but-nothing-arrives--the-lab-ca-is-not-in-the-system-trust-store) — the lab CA is not in the system trust store, so the scanner's first TLS call fails and the error is swallowed
- [Inside the containers — MySQL and Keycloak](TROUBLESHOOTING.md#inside-the-containers--mysql-and-keycloak) — where results are actually stored, and how to query them
- [Reaching the lab from another machine](TROUBLESHOOTING.md#reaching-the-lab-from-another-machine) — scanning a Windows host against this stack

## Notes

This is a learning and development environment. It is **not** a hardened or
accredited deployment: the lab CA's private key sits in Terraform state, Keycloak
runs in dev mode, the STIG Manager API has TLS verification disabled for its
server-to-server call, and credentials are the well-known defaults. `make tfsec`
reports roughly 40 findings against the Terraform and most of them are correct —
they are deliberate trade-offs for a disposable local lab, not a to-do list.

DISA STIG content is published by the Defense Information Systems Agency and is
not included in this repository. STIG Manager and Evaluate-STIG are the work of
their respective authors; this project only automates deploying and wiring them.
