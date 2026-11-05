# Troubleshooting and operations guide

Everything that can go wrong with this lab, what it looks like when it does, and
the command that fixes it — plus the step-by-step verification the automation runs
for you and the inspection commands worth knowing.

For what this project is, its prerequisites and the architecture, see
**[README.md](README.md)**. Start any diagnosis with:

```bash
make verify
```

Each of the 13 checks maps to a section below. The step that fails names the row
in the [troubleshooting table](#troubleshooting) to read.

> Paths in this guide are relative to the repository root. Where a host address
> appears it is an example — substitute your own (`ip -4 -br addr show`).

---

## Contents

- [Access and credentials](#access-and-credentials)
- [Verify it, step by step](#verify-it-step-by-step)
- [Looking at the clusters — kubectl and k9s](#looking-at-the-clusters--kubectl-and-k9s)
- [Inside the containers — MySQL and Keycloak](#inside-the-containers--mysql-and-keycloak)
- [Reaching the lab from another machine](#reaching-the-lab-from-another-machine)
- [After a reboot, or after Floci restarts](#after-a-reboot-or-after-floci-restarts)
- [Troubleshooting](#troubleshooting)
- [How this differs from the AWS original](#how-this-differs-from-the-aws-original)
- [What each piece does](#what-each-piece-does)
- [Teardown](#teardown)
- [References](#references)

---

## Access and credentials

> Everything below is a **lab default**. Change all of it before this touches any
> real network.

### Web UIs

| What | URL | Username | Password |
|---|---|---|---|
| STIG Manager | <https://stigman.mil> | `admin` | `password` |
| Keycloak admin console | <https://keycloak.mil/admin> | `admin` | `Pa55w0rd` |

The HTTP listeners are published on **port 8080**, not 80, because `apache2`
already holds port 80 on this host: <http://stigman.mil:8080> redirects to HTTPS.
See [Troubleshooting](#troubleshooting) if you would rather have port 80.

### Trusting the certificate

Terraform generates a lab CA and signs both hostnames with it. Trust the CA once
and both sites verify cleanly, with no browser warning:

```bash
# Firefox / Chrome on this host (system trust store)
sudo cp certs/lab-ca.crt /usr/local/share/ca-certificates/stig-cloud-lab.crt
sudo update-ca-certificates

# Firefox keeps its own store: Settings -> Privacy & Security ->
# Certificates -> View Certificates -> Authorities -> Import -> certs/lab-ca.crt

# curl
curl --cacert certs/lab-ca.crt https://stigman.mil/
```

### STIG Manager demo users

These ship inside the `nuwcdivnpt/stig-manager-auth` image's `stigman` realm.
All of them use the password `password`, the credential the
[STIG Manager docs](https://github.com/NUWCDIVNPT/stig-manager) give for the
demonstration Keycloak image.

| Username | Password | Realm roles | Use for |
|---|---|---|---|
| `admin` | `password` | `admin`, `create_collection` | Full application admin |
| `stigmanadmin` | `password` | `admin`, `create_collection` | Full application admin |
| `user02`, `user04` | `password` | `create_collection` | Collection owner |
| `user01`, `user03`, `user05` | `password` | *(none)* | Unprivileged user |

### Infrastructure credentials

| What | Value | Notes |
|---|---|---|
| AWS endpoint | `http://localhost:4566` | Floci; `source env.sh` to point a shell at it |
| AWS account | `000000000000` | Floci's fake account |
| AWS IAM user | `terraform-lab` | Minted by `scripts/01-bootstrap-iam.sh` |
| AWS key | in `aws/credentials`, profile `floci-lab` | Emulated, valid nowhere else |
| MySQL root | `root` / `rootpw` | In-cluster only, no NodePort |
| MySQL app user | `stigman` / `stigman` | Schema `stigman` |
| Keycloak bootstrap admin | `admin` / `Pa55w0rd` | `KC_BOOTSTRAP_ADMIN_*` in the pod |

**Your real AWS credentials are never used.** `env.sh` repoints
`AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` at `aws/config` and
`aws/credentials` inside this directory, so nothing in the lab can read
`~/.aws/credentials`, and it sets `KUBECONFIG` to `./kubeconfig` so
`~/.kube/config` is left alone.

### Reaching things directly, bypassing the ALB

```bash
source env.sh

# Kubernetes API servers (host ports assigned by Floci, see the note below)
terraform -chdir=terraform/01-infra output keycloak_cluster_endpoint
terraform -chdir=terraform/01-infra output stigman_cluster_endpoint

# Straight at a NodePort, skipping the load balancer and TLS
curl http://$(terraform -chdir=terraform/01-infra output -raw stigman_node_ip):30540/
curl http://$(terraform -chdir=terraform/01-infra output -raw keycloak_node_ip):30080/

# Port-forward instead
kubectl --context stigman  port-forward -n stigman  svc/stigman-svc 54000:54000
kubectl --context keycloak port-forward -n keycloak svc/keycloak     8080:8080

# MySQL
kubectl --context stigman exec -it -n stigman deploy/mysql -- \
  mysql -h127.0.0.1 -ustigman -pstigman stigman -e "show tables;"
```

### Getting an API token by hand

```bash
source env.sh
SCOPES="openid stig-manager:stig stig-manager:stig:read stig-manager:collection"
SCOPES="$SCOPES stig-manager:user stig-manager:user:read stig-manager:op stig-manager:op:read"

TOKEN=$(curl -s --cacert certs/lab-ca.crt \
  -d client_id=stig-manager -d username=admin -d password=password \
  -d grant_type=password --data-urlencode "scope=$SCOPES" \
  https://keycloak.mil/realms/stigman/protocol/openid-connect/token | jq -r .access_token)

curl -s --cacert certs/lab-ca.crt -H "Authorization: Bearer $TOKEN" \
  https://stigman.mil/api/user | jq
```

STIG Manager returns `403 {"error":"Required scopes were not found in token."}`
if you ask for a token without those `stig-manager:*` scopes.

---

## Verify it, step by step

```bash
./scripts/08-verify.sh
```

It walks the stack bottom-up and prints PASS/FAIL per check. Each check below is
also the manual command, if you want to look yourself. Always `source env.sh`
first.

### 1. Is the emulator up?

```bash
docker compose ps
curl -s http://localhost:4566/_floci/health | jq '.version, .edition'
floci status
```

Expect `version "2.4.0"` and `Ports: 443->443 4566->4566 5353->53/udp 8080->80`.

### 2. Am I talking to the emulator, not AWS?

```bash
aws sts get-caller-identity
```

Must print account **`000000000000`** and
`arn:aws:iam::000000000000:user/terraform-lab`. Anything else means `env.sh`
was not sourced — stop, because the next commands would hit real AWS.

### 3. Are both clusters ACTIVE?

```bash
aws eks list-clusters
aws eks describe-cluster --name stigman-eks  --query 'cluster.{status:status,endpoint:endpoint,version:version}'
aws eks describe-cluster --name keycloak-eks --query 'cluster.{status:status,endpoint:endpoint,version:version}'
docker ps --filter label=io.floci.service=eks --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
```

### 4. Can I authenticate to the Kubernetes API?

```bash
kubectl config get-contexts            # 'keycloak' and 'stigman'
kubectl --context keycloak get --raw /readyz
kubectl --context stigman  get --raw /readyz
```

Both print `ok`. This exercises the real EKS auth path: `aws eks get-token`
builds a SigV4-presigned STS request, and Floci's webhook verifies the signature.

### 5. Are the nodes healthy?

```bash
kubectl --context stigman  get nodes -o wide
kubectl --context keycloak get nodes -o wide
kubectl --context stigman describe node | grep -A6 Conditions:
```

`Ready=True` and, importantly, **`DiskPressure=False`**. See
[Troubleshooting](#troubleshooting) if it is `True`.

### 6. Are the workloads running?

```bash
kubectl --context keycloak get pods -n keycloak
kubectl --context stigman  get pods,svc,pvc -n stigman
```

Expect `keycloak 1/1`, `mysql 1/1`, `stigman-api 1/1`, and `mysql-pvc Bound`.

### 7. Did MySQL migrate?

```bash
kubectl --context stigman logs -n stigman -l app=stigman-api | \
  grep -oE '"component":"mysql".*' | tail -3
```

Look for `"type":"preflight","data":{"success":true,...}` and
`"MySQL schema is up to date"`.

### 8. Are the ALB targets healthy?

```bash
for tg in keycloak-tg stigman-tg; do
  arn=$(aws elbv2 describe-target-groups --names $tg \
        --query 'TargetGroups[0].TargetGroupArn' --output text)
  echo "$tg:"; aws elbv2 describe-target-health --target-group-arn "$arn" \
    --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output table
done
```

Both `healthy`. `unhealthy` means the ALB cannot reach the NodePort; `unused`
means nothing is registered — re-run `./scripts/02-apply-infra.sh`.

Before assuming the NodePort is at fault, check that the registered address is
still the node's address, because it changes on restart:

```bash
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].{Node:Tags[?Key==`Name`]|[0].Value,IP:PrivateIpAddress}' \
  --output table
```

`keycloak-tg` should point at `keycloak-eks-node` and `stigman-tg` at
`stigman-eks-node`. A mismatch is [this bug](#both-web-uis-say-unavailable--503-after-a-restart);
the verify script makes the same comparison and reports a stale target by name.
Keycloak also needs ~6 minutes to start, during which `unhealthy` is expected.

### 9. Do the hostnames resolve, both outside and inside?

```bash
grep -E 'stigman\.mil|keycloak\.mil' /etc/hosts        # host: -> 127.0.0.1
dig +short @127.0.0.1 -p 5353 keycloak.mil             # Floci DNS: -> 172.22.0.2

POD=$(kubectl --context stigman get pod -n stigman -l app=stigman-api \
      -o jsonpath='{.items[0].metadata.name}')
kubectl --context stigman exec -n stigman $POD -- \
  node -e 'require("dns").resolve4("keycloak.mil",(e,a)=>console.log(e||a))'
```

The last one must print `[ '172.22.0.2' ]`. That is the CoreDNS override working.

### 10. Does HTTPS work through the load balancers?

```bash
curl -s --cacert certs/lab-ca.crt -o /dev/null -w '%{http_code}\n' https://stigman.mil/
curl -s --cacert certs/lab-ca.crt -o /dev/null -w '%{http_code}\n' https://keycloak.mil/realms/stigman

# Which certificate does each SNI name get?
for h in stigman.mil keycloak.mil; do
  echo | openssl s_client -connect 127.0.0.1:443 -servername $h 2>/dev/null \
    | openssl x509 -noout -subject -issuer
done
```

Both `200`, and each hostname gets its own leaf signed by `STIG Cloud Lab Root CA`.

### 11. Is the browser pointed at the right issuer?

```bash
curl -s --cacert certs/lab-ca.crt https://stigman.mil/js/Env.js | grep authority
```

Must be `authority: "https://keycloak.mil/realms/stigman"`. If it is anything
else the login redirect will go somewhere unreachable.

### 12. Does the whole OIDC flow work?

See [Getting an API token by hand](#getting-an-api-token-by-hand). A `200` from
`/api/user` returning `"username": "admin"` means Keycloak issued a token, the
API fetched the JWKS over the ALB, validated the signature, and mapped the user.
That is the full loop.

### 13. Finally, log in with a browser

Open <https://stigman.mil>, click through to Keycloak, sign in as
`admin` / `password`.

---

## Looking at the clusters — kubectl and k9s

Both read `./kubeconfig`, which `env.sh` selects. Two contexts: **`keycloak`**
and **`stigman`**.

### kubectl

```bash
source env.sh

kubectl config get-contexts
kubectl config use-context stigman          # or pass --context every time

# Overview
kubectl --context stigman  get all -n stigman
kubectl --context keycloak get all -n keycloak
kubectl --context stigman  get all -A

# Nodes and capacity. The node is the k3s container; its limits come from the
# node group's instance type (t3.medium -> 2 vCPU).
kubectl --context stigman get nodes -o wide
kubectl --context stigman describe node
kubectl --context stigman top node            # needs metrics-server; k3s ships it

# Logs
kubectl --context stigman  logs -n stigman -l app=stigman-api -f
kubectl --context stigman  logs -n stigman -l app=mysql --tail=50
kubectl --context keycloak logs -n keycloak -l app=keycloak -f

# STIG Manager logs are JSON; jq makes them readable
kubectl --context stigman logs -n stigman -l app=stigman-api --tail=50 | jq -c '{component,type,data}'

# Shells
kubectl --context stigman  exec -it -n stigman deploy/stigman-api -- sh
kubectl --context stigman  exec -it -n stigman deploy/mysql -- mysql -h127.0.0.1 -ustigman -pstigman stigman
kubectl --context keycloak exec -it -n keycloak deploy/keycloak -- bash

# Events, newest last — the first place to look when a pod will not start
kubectl --context stigman get events -n stigman --sort-by=.lastTimestamp

# Restart something
kubectl --context stigman rollout restart deployment/stigman-api -n stigman
kubectl --context stigman rollout status  deployment/stigman-api -n stigman
```

### k9s

```bash
source env.sh      # sets KUBECONFIG; k9s needs nothing else

k9s                                 # starts in the current context
k9s --context stigman
k9s --context keycloak
k9s --context stigman -n stigman    # straight into the namespace
k9s --context stigman -c pods       # straight to a resource view
```

Inside k9s:

| Key | Does |
|---|---|
| `:ctx` | Switch cluster — pick `keycloak` or `stigman` |
| `:ns` | Switch namespace |
| `:pod`, `:svc`, `:deploy`, `:pvc`, `:cm`, `:no` | Jump to a resource |
| `0` | All namespaces |
| `l` | Logs for the selected pod (`s` to toggle autoscroll, `w` to wrap) |
| `d` | Describe |
| `y` | View YAML |
| `s` | Shell into the container |
| `e` | Edit |
| `Ctrl-D` | Delete |
| `:pulse` | Cluster health dashboard |
| `:events` | Event stream |
| `?` | Help |
| `Esc` | Back |

Quick tour: `k9s --context stigman` → `:ns` → `stigman` → `:pod` → select
`stigman-api` → `l` for logs. Then `:ctx` → `keycloak` to hop clusters.

If k9s shows no contexts, `KUBECONFIG` is not set — `source env.sh`. If it shows
them but everything is red, the clusters are down or the kubeconfig is stale; run
`./scripts/03-kubeconfig.sh`.

### Without kubectl, straight at the emulator

```bash
source env.sh
aws eks list-clusters
aws eks describe-nodegroup --cluster-name stigman-eks --nodegroup-name default
aws eks list-addons --cluster-name stigman-eks
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].[Tags[?Key==`eks:cluster-name`]|[0].Value,InstanceId,PrivateIpAddress,State.Name]' \
  --output table
docker logs -f floci                      # the emulator's own log
docker logs -f floci-aws-eks-stigman-eks  # k3s server log
```

---

## Inside the containers — MySQL and Keycloak

Both of these are shells inside a pod, so nothing has to be exposed on the host.

### The STIG Manager database

```bash
source env.sh
POD=$(kubectl --context stigman get pod -n stigman -l app=mysql \
  -o jsonpath='{.items[0].metadata.name}')

# interactive client
kubectl --context stigman exec -it -n stigman "$POD" -- \
  mysql -h127.0.0.1 -ustigman -pstigman stigman

# or one query at a time, which is easier to script
kubectl --context stigman exec -n stigman "$POD" -- \
  mysql -h127.0.0.1 -ustigman -pstigman stigman -e "SELECT name FROM collection;"
```

`-h127.0.0.1` is not optional. Without it the client tries a unix socket at
`/var/run/mysqld/mysqld.sock`, which this image does not place where the client
looks, and you get `ERROR 2002 (HY000): Can't connect to local MySQL server`
even though the server is running fine. Credentials are `stigman`/`stigman` on
schema `stigman`; `root`/`rootpw` also works.

Already inside the container (`kubectl exec -it ... -- bash`), the same flag
still applies: `mysql -h127.0.0.1 -ustigman -pstigman stigman`.

#### Where the results actually live

One row in `review` per asset per rule. That is the table that matters.

| Column | Holds |
|---|---|
| `assetId` → `asset` | which host |
| `ruleId` | the **Rule ID** (`SV-221584r961683_rule`), never the Vuln ID |
| `resultId` → `result` | NR / NA / NF / O |
| `detail` | FindingDetails text, including the `ResultHash` and `~~~~~` bar |
| `comment` | answer-file output: `[ValidTrueComment]` and `[Validation Code Results]` |
| `resultEngine` | JSON — scanner product/version, plus `overrides[]` when an answer file changed the result |
| `statusId` → `status` | 0 saved / 1 submitted / 2 rejected / 3 accepted |
| `version` + `checkDigest` | pins the review to exact check content, so it survives STIG revisions |

`review_history` keeps superseded reviews. `stig_asset_map` records which
benchmarks are attached to which asset.

#### Collections and assets

```sql
SELECT collectionId, name, state, created FROM collection ORDER BY collectionId;

SELECT c.collectionId AS cid, c.name AS collection,
       a.assetId AS aid, a.name AS asset, a.ip, a.state
FROM collection c
  LEFT JOIN asset a ON a.collectionId = c.collectionId
ORDER BY c.collectionId, a.name;
```

Use `LEFT JOIN` so an empty collection still appears, and avoid bare
`SELECT * FROM collection` — `settings` and `metadata` are JSON blobs that wrap
the terminal. Append `\G` instead of `;` for vertical output on wide rows:
`SELECT * FROM asset WHERE assetId=3\G`.

The same hostname can appear as several `assetId`s: assets are scoped to a
collection, so uploading one host into two collections creates two independent
asset records, not one shared one.

#### Status lookups

The API, CKL and CKLB each spell these differently, which is why the join is
needed to read anything:

```sql
SELECT resultId, api, ckl, cklb, abbr FROM result;   -- 3=pass/NotAFinding, 4=fail/Open
SELECT statusId, api, en FROM status;
```

#### What has been scanned

```sql
SELECT c.name AS collection, a.name AS asset, m.benchmarkId
FROM asset a
  JOIN collection c ON c.collectionId = a.collectionId
  LEFT JOIN stig_asset_map m ON m.assetId = a.assetId
ORDER BY c.name, a.name, m.benchmarkId;
```

#### Results for one asset, newest first

```sql
SELECT r.ruleId, res.abbr AS result, r.ts, LEFT(r.detail, 60) AS detail_head
FROM review r
  JOIN result res ON res.resultId = r.resultId
WHERE r.assetId = 3
ORDER BY r.ts DESC
LIMIT 20;
```

#### Open/NotAFinding counts per asset

```sql
SELECT c.name AS collection, a.name AS asset, res.abbr, COUNT(*) AS n
FROM review r
  JOIN asset a ON a.assetId = r.assetId
  JOIN collection c ON c.collectionId = a.collectionId
  JOIN result res ON res.resultId = r.resultId
GROUP BY c.name, a.name, res.abbr
ORDER BY c.name, a.name, res.abbr;
```

Do not add a second `LEFT JOIN` (to `stig_asset_map`, say) and then `COUNT()` in
the same query — the joins multiply and every benchmark row reports the asset's
whole total. Count in one query, list benchmarks in another.

#### Everything an answer file changed

`reAuthority` is a generated column indexing `resultEngine.overrides[0].authority`,
so answer-file overrides are directly queryable — this is the audit trail:

```sql
SELECT a.name AS asset, r.ruleId, r.reAuthority,
       JSON_EXTRACT(r.resultEngine, '$.overrides[0].oldResult') AS was,
       JSON_EXTRACT(r.resultEngine, '$.overrides[0].newResult') AS now
FROM review r JOIN asset a ON a.assetId = r.assetId
WHERE r.reAuthority IS NOT NULL;
```

To read the full comment a validation code produced:

```sql
SELECT comment FROM review
WHERE assetId = 3 AND ruleId = 'SV-221584r961683_rule'\G
```

#### One rule across every asset

```sql
SELECT c.name AS collection, a.name AS asset, res.abbr, r.ts
FROM review r
  JOIN asset a ON a.assetId = r.assetId
  JOIN collection c ON c.collectionId = a.collectionId
  JOIN result res ON res.resultId = r.resultId
WHERE r.ruleId LIKE 'SV-221584%';
```

#### Table sizes, when something looks wrong

```sql
SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'stigman' ORDER BY TABLE_ROWS DESC;
```

A dump, if you want the data outside the cluster:

```bash
kubectl --context stigman exec -n stigman "$POD" -- \
  mysqldump -h127.0.0.1 -ustigman -pstigman stigman > stigman-backup.sql
```

Watch the disk — this host runs at ~93% used, and filling it re-triggers kubelet
eviction on both clusters.

### Keycloak configuration

Keycloak ships `kcadm.sh`, which talks to its own admin API over localhost
inside the pod. That avoids the ALB, the lab CA and the browser entirely.

```bash
source env.sh
KPOD=$(kubectl --context keycloak get pod -n keycloak -l app=keycloak \
  -o jsonpath='{.items[0].metadata.name}')
kubectl --context keycloak exec -it -n keycloak "$KPOD" -- bash
```

Then, inside the container, log in once:

```bash
K=/opt/keycloak/bin/kcadm.sh
$K config credentials --server http://localhost:8080 --realm master \
  --user admin --password Pa55w0rd
```

`http://localhost:8080` is correct — Keycloak speaks plain HTTP in the pod and
TLS is terminated at the ALB. The session is cached in
`~/.keycloak/kcadm.config` inside the container, so every later command skips
the login. That file holds a bearer token; it dies with the pod.

```bash
# realms, and the stigman realm's OIDC-relevant settings
$K get realms --fields realm,enabled
$K get realms/stigman --fields realm,sslRequired,accessTokenLifespan,registrationAllowed

# clients
$K get clients -r stigman --fields clientId,enabled,publicClient,standardFlowEnabled

# the UI's client: redirect URIs and web origins (what scripts/07 narrows)
$K get clients -r stigman --query clientId=stig-manager \
  --fields clientId,redirectUris,webOrigins

# users
$K get users -r stigman --fields username,enabled,email

# the scopes the API checks for
$K get client-scopes -r stigman --fields name

# a client's full config, by its internal UUID
ID=$($K get clients -r stigman --query clientId=evaluatestig --fields id \
  | grep -o '"[0-9a-f-]\{36\}"' | tr -d '"')
$K get clients/$ID -r stigman

# that client's mappers and assigned scopes
$K get clients/$ID/protocol-mappers/models -r stigman --fields name,protocolMapper
$K get clients/$ID/default-client-scopes -r stigman --fields name
```

Most `get` commands take `--fields`, and leaving it off prints the entire
object — useful once, noisy in a loop. `kcadm.sh` writes JSON to stdout, so it
pipes into `python3 -m json.tool` or `jq` if either is present in the image.

To export a whole realm for inspection or version control:

```bash
$K get realms/stigman > /tmp/stigman-realm.json
# then, from the host
kubectl --context keycloak cp keycloak/"$KPOD":/tmp/stigman-realm.json ./stigman-realm.json
```

Changes made this way are **not** persisted across a pod restart. Keycloak here
runs in dev mode on an in-memory H2 database, and the realm is reloaded from the
`nuwcdivnpt/stig-manager-auth` image every time the pod starts. Anything you
need to survive belongs in `terraform/02-workloads` or in a script like
`scripts/07-keycloak-client.sh`, which is why that script exists rather than a
note saying "set this in the admin console".

A read-only alternative that needs no shell, straight from the host:

```bash
curl -s --cacert certs/lab-ca.crt \
  https://keycloak.mil/realms/stigman/.well-known/openid-configuration | jq .
```

That is the exact document the STIG Manager API and Evaluate-STIG fetch, so if
it answers, OIDC discovery works; if it does not, see the `503` section.

---

## Reaching the lab from another machine

Nothing in the lab needs changing for this: Floci already publishes every port
on `0.0.0.0` rather than localhost, and this host runs no firewall
(`ufw` inactive, iptables `INPUT ACCEPT`). All the work is on the client.

```bash
# confirm the published ports really are on all interfaces
ss -tulpn | grep -E ':443|:4566|:8080|:5353'   # expect 0.0.0.0, not 127.0.0.1
```

This host is a VMware guest (`slingshot`, Ubuntu 22.04) on a NAT network:

| | |
|---|---|
| Guest (this lab) | `192.168.1.50` on `eth0` |
| VMware host adapter | `192.168.1.1` |
| NAT gateway | `192.168.1.2` |

The VMware host is on the same subnet as the guest, so it can route to the lab
directly — no port forwarding needed. Re-read the current address with
`ip -4 -br addr show eth0` before trusting the number above (see the DHCP note
at the end).

### 1. Hostnames on the client — required, not optional

Both ALBs share host port 443 and Floci selects between them by **SNI**, so the
client has to present the hostname. Connecting to the bare IP returns `502`.

Add to the client's hosts file — `/etc/hosts` on macOS/Linux,
`C:\Windows\System32\drivers\etc\hosts` on Windows (edit as Administrator):

```
192.168.1.50  stigman.mil keycloak.mil
```

Verify from the client without touching its hosts file first:

```bash
curl -I --cacert lab-ca.crt --resolve stigman.mil:443:192.168.1.50 https://stigman.mil/
```

### 2. Trust the lab CA on the client

Copy `certs/lab-ca.crt` (`CN = STIG Cloud Lab Root CA`) to the client and install
it. Without this you get `UntrustedRoot` / `CERTIFICATE_VERIFY_FAILED` — see
[A client "succeeds" but nothing arrives](#a-client-succeeds-but-nothing-arrives--the-lab-ca-is-not-in-the-system-trust-store)
for why that failure is often silent.

```powershell
# Windows, elevated
certutil -addstore -f Root lab-ca.crt
```

```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain lab-ca.crt

# Linux
sudo cp lab-ca.crt /usr/local/share/ca-certificates/stig-lab-ca.crt
sudo update-ca-certificates
```

Firefox keeps its own trust store on every OS: Settings → Privacy & Security →
Certificates → View Certificates → Authorities → Import.

Then `https://stigman.mil` and `https://keycloak.mil` work from the client's
browser with the usual credentials.

### Optional: drive the emulated AWS API remotely

`:4566` answers over the network too, so the `aws` CLI can run from the client
by pointing `AWS_ENDPOINT_URL` at the guest instead of localhost. Copy
`aws/config`, `aws/credentials` and `env.sh` over and change one line:

```bash
export AWS_ENDPOINT_URL="http://192.168.1.50:4566"
```

`kubectl` is a different story: `kubeconfig` points at `https://localhost:65xx`
because `FLOCI_SERVICES_EKS_ENDPOINT_MODE: host` makes `describe-cluster`
advertise localhost. To use it remotely, rewrite those server URLs to the
guest's address — or just SSH in and run `kubectl` here.

### Caveats

**Use `https://`, never `http://...:8080`.** The HTTP redirect listener returns
`502`, from localhost as much as from the network. Plain HTTP carries no SNI, so
with two ALBs sharing port 80 Floci cannot tell which one is wanted. Only the
HTTPS listeners are usable, because SNI disambiguates them.

**Do not point the client's DNS at this host.** Floci's Route53 on `:5353`
answers `stigman.mil -> 172.22.0.2`, which is Floci's address on the lab's
internal Docker network and is unreachable from anywhere else. That record
exists so pods inside the clusters can reach the ALB. Hosts-file entries are the
right mechanism for external clients.

**The guest address is DHCP** (`dynamic` in `ip addr`), so it can change across
reboots and silently break the client's hosts entries — the symptom is a
connection timeout, not a TLS or application error. Nothing here pins it; if the
address moves, re-read it with `ip -4 -br addr show eth0` and update the client.
A static address or a DHCP reservation in VMware's NAT settings would avoid the
drift, but that is a hypervisor-side change this lab deliberately does not make.

**NAT limits reachability to the VMware host.** Other physical machines on the
LAN cannot reach `192.168.1.50`. Switching the VM's adapter to **Bridged**
gives it an address on the real LAN and the same two client steps apply — but it
also exposes `:4566`, the emulated AWS control plane, to every host on that
network. Floci's IAM is an emulator and this lab's credentials are fixed and
well-known, so treat bridged mode as putting the whole lab on the network, not
just the web UIs.

## After a reboot, or after Floci restarts

**Short version: `./scripts/00-up.sh`.** It handles all of the below.

Two things make a restart more than just `docker compose up`:

1. **The k3s API server host ports move.** Floci assigns them from 6500–6599 in
   whatever order the clusters come back, so a cluster that was on `:6502` may
   come back on `:6500`. Any existing kubeconfig then points at the wrong port.
2. **The node container IPs move.** The ALB target groups register the node by
   IP address, so they must be re-registered. Skipping this is what makes both
   web UIs return `503` with healthy-looking pods — see
   [the walkthrough](#both-web-uis-say-unavailable--503-after-a-restart).
   `docker compose up -d` on its own does **not** do it; stage 1 must be
   re-applied.

Terraform fixes both, which is why the order matters:

```bash
cd /path/to/local-rmf-automation
source env.sh

docker compose up -d                    # 1. emulator back, state loaded from ./data
./scripts/01-bootstrap-iam.sh           # 2. no-op if the key still works
./scripts/06-patch-eviction.sh          # 3. re-apply the eviction threshold
./scripts/02-apply-infra.sh             # 4. re-register ALB targets, refresh endpoints
./scripts/03-kubeconfig.sh              # 5. rewrite the kubeconfig at the new ports
./scripts/05-hosts.sh                   # 6. /etc/hosts does not survive some reboots
./scripts/08-verify.sh                  # 7. confirm
```

Workloads do **not** need redeploying: they live in the k3s data volumes
(`floci-aws-eks-*`), which survive, as does the MySQL PVC and all your STIG
Manager data. `./scripts/04-apply-workloads.sh` is a no-op if nothing changed.

### What survives what

| Action | Floci state | k8s objects | MySQL data |
|---|---|---|---|
| Host reboot | kept | kept | kept |
| `docker compose restart` | kept | kept | kept |
| `docker compose down` / `up -d` | kept (`./data`) | kept (volumes) | kept |
| `scripts/06-patch-eviction.sh` | kept | kept | kept |
| `scripts/99-down.sh` | kept | kept | kept |
| `scripts/99-down.sh --destroy` | kept | **gone** | **gone** |
| `scripts/99-down.sh --purge` | **gone** | **gone** | **gone** |

### Does it come up on its own at boot?

The `floci` container has `restart: unless-stopped`, so Docker starts it, and
Floci re-latches its clusters. But the eviction patch, the ALB target
re-registration and the kubeconfig do not happen by themselves — run
`./scripts/00-up.sh` after logging in. To automate it:

```bash
# crontab -e
@reboot sleep 60 && cd /path/to/local-rmf-automation && make up >> boot.log 2>&1
```

---

## Troubleshooting

Start with `./scripts/08-verify.sh` — the step that fails tells you which row
below to read.

| Symptom | Cause | Fix |
|---|---|---|
| `aws sts get-caller-identity` shows a real account | `env.sh` not sourced | `source env.sh`, then re-check |
| Verify step 2 fails, account is `000000000000` but no user | IAM user missing from Floci state | `./scripts/01-bootstrap-iam.sh` |
| `kubectl`: `the server has asked for the client to provide credentials` | Token signed by a key Floci's webhook does not hold, or the kubeconfig's exec block lost the lab env | `./scripts/01-bootstrap-iam.sh && ./scripts/03-kubeconfig.sh` |
| `kubectl`: connection refused on `localhost:65xx` | API server port moved after a restart | `./scripts/02-apply-infra.sh && ./scripts/03-kubeconfig.sh` |
| `DiskPressure=True`, pods `Evicted` / `ContainerStatusUnknown`, `FailedScheduling ... untolerated taint node.kubernetes.io/disk-pressure` | Floci pins kubelet to `nodefs.available<10%`, which on a large disk is several GB | `./scripts/06-patch-eviction.sh` (sets `nodefs.available<1Gi`), then delete the failed pods: `kubectl --context stigman delete pod -n stigman --field-selector=status.phase=Failed` |
| Pod `Pending` forever, PVC `Pending` | Claim asks for a StorageClass with no provisioner | Must be `local-path`; `aws-ebs-csi-driver` is metadata-only in Floci. Check `kubectl get sc` |
| ALB target `unhealthy` | NodePort not answering, health matcher too strict, or Keycloak still starting (~6 min) | `curl http://<node_ip>:<nodeport>/`; Keycloak answers `/` with a 302, so its matcher is `200,301,302`. Confirm the registered IP is current before digging further |
| ALB target `unused`, or registered to an old IP | Node container IP changed on restart and stage 1 was not re-applied | `./scripts/02-apply-infra.sh -auto-approve` — see [the walkthrough](#both-web-uis-say-unavailable--503-after-a-restart) |
| `https://stigman.mil` or `https://keycloak.mil` → `503 Service unavailable` | ALB has no healthy target — after a restart this is almost always a stale target IP, and one stale target 503s **both** hostnames | [Both web UIs say "unavailable" after a restart](#both-web-uis-say-unavailable--503-after-a-restart) |
| `https://stigman.mil` → connection refused | Floci is not publishing `:443`, or is down | `docker compose ps`; `ss -tulpn \| grep :443` |
| Works on the lab host, times out from another machine | Client hosts file missing, or the guest's DHCP address moved | [Reaching the lab from another machine](#reaching-the-lab-from-another-machine) |
| From another machine: `502`, or the wrong site answers | Connected by IP instead of hostname — the ALBs are selected by SNI | Use `https://stigman.mil`, not `https://<ip>`; see [Reaching the lab](#reaching-the-lab-from-another-machine) |
| `http://<host>:8080` → `502` | Plain HTTP has no SNI and two ALBs share port 80 | Expected; use `https://` only |
| `https://stigman.mil/api` returns `{"error":"not found"}` | Not a fault — `/api` is a base path with no route; endpoints live below it | Try `/api/op/configuration`; see [the red-herring table](#a-client-succeeds-but-nothing-arrives--the-lab-ca-is-not-in-the-system-trust-store) |
| Browser warns about the certificate | Lab CA not trusted | [Trusting the certificate](#trusting-the-certificate) |
| `curl: SSL certificate problem` | Same | `--cacert certs/lab-ca.crt` |
| An API client / scanner / CI job reports success but no data lands in STIG Manager | Lab CA absent from the system trust store, so the client's first TLS call failed and it swallowed the error | [A client "succeeds" but nothing arrives](#a-client-succeeds-but-nothing-arrives--the-lab-ca-is-not-in-the-system-trust-store) |
| `UntrustedRoot`, `unable to get local issuer certificate`, `CERTIFICATE_VERIFY_FAILED`, curl exit `60` | Same — curl's `--cacert` does not help other runtimes | `sudo cp certs/lab-ca.crt /usr/local/share/ca-certificates/stig-lab-ca.crt && sudo update-ca-certificates` |
| Evaluate-STIG prints `Done!` but the collection has 0 assets, and `/tmp/Evaluate-STIG/Evaluate-STIG_STIGManager.log` is missing | OIDC discovery threw before any error could be logged (`STIGManager.psm1:121` has no try/catch) | [Same section](#a-client-succeeds-but-nothing-arrives--the-lab-ca-is-not-in-the-system-trust-store) |
| STIG Manager log: `"type":"discovery","data":{"success":false,...}` with `"Service unavailable" is not valid JSON` | Discovery goes through the ALB, so this means Keycloak is unreachable — still starting, or `keycloak-tg` has a stale target. Not a DNS fault | [Both web UIs say "unavailable"](#both-web-uis-say-unavailable--503-after-a-restart) |
| STIG Manager log: `"type":"discovery","data":{"success":false,...,"message":"fetch failed"}` | Pod cannot resolve or reach `keycloak.mil` | Verify step 9. If DNS fails: `kubectl --context stigman get cm coredns-custom -n kube-system` and `kubectl --context stigman rollout restart deployment/coredns -n kube-system` |
| API returns `403 Required scopes were not found in token` | Token requested without the `stig-manager:*` scopes | [Getting an API token by hand](#getting-an-api-token-by-hand) |
| Login redirects to a URL that will not load | `Env.js` authority wrong, or Keycloak's `KC_HOSTNAME` drifted | Verify step 11; `./scripts/04-apply-workloads.sh` |
| Keycloak: `Invalid parameter: redirect_uri` | Client's redirect URIs do not cover the hostname | `./scripts/07-keycloak-client.sh` |
| `terraform apply`: `Unexpected Identity Change ... report to the provider developer` | Kubernetes provider resource-identity mismatch on state from an interrupted apply | Re-import the named resource, e.g. `cd terraform/02-workloads && terraform state rm kubernetes_deployment.mysql && terraform import kubernetes_deployment.mysql stigman/mysql` |
| `terraform apply`: `Cluster authentication mode must be API or API_AND_CONFIG_MAP` | Cluster missing `access_config` | Already set in `03-eks.tf`; re-run the apply |
| `CreateCluster` refuses a `floci:kubelet-arg:...` tag | That flag is on Floci's managed list (`eviction-hard`, `node-labels`, `system-reserved`, …) | Cannot be overridden by tag — that is why `eviction_patch.py` exists |
| Floci log: `declared CIDR ... is unusable (overlaps an existing Docker network)` | VPC CIDR collides with a Docker network | Harmless — Floci substitutes one. To avoid it, change `vpc_cidr` and check `docker network inspect` |
| Want HTTP on port 80 instead of 8080 | `apache2` holds `:80` | `sudo systemctl stop apache2`, change the mapping in `docker-compose.yml` to `"80:80"`, `docker compose up -d` |
| Everything is slow / OOM | Two k3s containers plus MySQL on one host | `docker stats`; lower `node_instance_type` in `terraform/01-infra/variables.tf` |
| Disk filling up | Host images plus each cluster's own containerd image store | `docker system df`, and `docker system df -v \| grep floci-aws-eks` for the cluster volumes. `docker builder prune` reclaims build cache safely |

### Both web UIs say "unavailable" / `503` after a restart

This is the most likely thing to go wrong, and the symptom points away from the
cause: every check inside the clusters passes, both pods are `Running`, and yet
both hostnames return `503 Service unavailable`.

**Cause.** The target groups register the k3s node by IP (`target_type = "ip"`;
see the header of `terraform/01-infra/05-alb.tf`). Each node container is
attached to three Docker networks, and the address Floci reports as the
instance's `PrivateIpAddress` is its address on the emulated VPC network
(`10.100.0.x`). Those addresses are reassigned whenever the containers are
recreated, so a registration made before a restart can point at an address that
now belongs to a different container — or to nothing at all. Terraform re-reads
the live address on every apply, so a plain `docker compose up -d` *without* a
stage 1 re-apply leaves the registrations stale. That is the whole bug:

```
stale ALB target  ->  keycloak-tg unhealthy  ->  https://keycloak.mil = 503
                                             ->  stigman-api OIDC discovery fails
                                             ->  API never becomes Ready
                                             ->  stigman-tg unhealthy too
                                             ->  https://stigman.mil = 503
```

Note the cascade: **one** stale target takes down **both** front ends, because
the STIG Manager API reaches Keycloak *through the ALB* and will not report
itself Ready until OIDC discovery succeeds. So do not debug `stigman-tg`
first — fix Keycloak's target and the API recovers on its own retry.

**Diagnosis.** Compare what is registered against what is live:

```bash
source env.sh

# what the ALB thinks
for tg in keycloak-tg stigman-tg; do
  arn=$(aws elbv2 describe-target-groups --names $tg \
        --query 'TargetGroups[0].TargetGroupArn' --output text)
  echo -n "$tg -> "
  aws elbv2 describe-target-health --target-group-arn "$arn" \
    --query 'TargetHealthDescriptions[0].[Target.Id,TargetHealth.State]' --output text
done

# what is actually there
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].{Node:Tags[?Key==`Name`]|[0].Value,IP:PrivateIpAddress}' \
  --output table
```

If the two disagree, that is this bug. Verify step 8 now makes the same
comparison and says so directly rather than only reporting `unhealthy`.

**Fix.**

```bash
./scripts/02-apply-infra.sh -auto-approve
```

The plan should be exactly `2 to add, 0 to change, 2 to destroy` — both
`aws_lb_target_group_attachment.app` entries, nothing else. Anything wider than
that means something other than the addresses drifted; read the plan before
approving it. Health checks run every 10s with `healthy_threshold = 2`, so the
targets turn `healthy` within ~20–30s. Then clear any dead pods the restart
left behind:

```bash
for ctx in keycloak stigman; do
  kubectl --context $ctx delete pod -A --field-selector=status.phase=Failed
done
```

**Give Keycloak time before concluding anything is broken.** It is capped at
`500m` CPU and starts in development mode on an H2 database, so on a busy
4-core host Quarkus augmentation alone takes ~200s and the full start takes
**~6 minutes** (`Keycloak 26.0.6 ... started in 351.604s` in this lab). Until
it finishes, `keycloak-tg` is legitimately `unhealthy` and the API logs
`"type":"discovery","data":{"success":false}` on a loop — all of which is
expected and clears itself. Watch it rather than restarting it:

```bash
kubectl --context keycloak logs -n keycloak -l app=keycloak -f | grep -E 'started in|Listening'
kubectl --context keycloak get pod -n keycloak -l app=keycloak -w
```

Only treat it as a fault if the pod is `Running` and `0/1` well past the
10-minute mark, or if the restart count is climbing.

### A client "succeeds" but nothing arrives — the lab CA is not in the system trust store

Every hostname in this lab (`stigman.mil`, `keycloak.mil`) is served with a
certificate signed by the lab's own root CA, `certs/lab-ca.crt`
(`CN = STIG Cloud Lab Root CA`). `curl --cacert` and the browser (once you have
[trusted the certificate](#trusting-the-certificate)) are the only things that
trust it by default. **Anything else that speaks TLS to this lab will fail
certificate validation until that CA is installed system-wide** — and a client
that logs the failure badly will look like it worked.

Observed with Evaluate-STIG 1.2601.3 uploading to STIG Manager, but the cause is
generic to any API client, CI job, scanner or SDK run against this lab.

**Symptom.** The client reports success and exits 0:

```
Uploading to STIG Manager...
Processing 34 Vulnerabilities...
Failed to get full CAT counts for grading.  Scoring will be inaccurate.
Done!
Total Time : 00:01:37.7842047
```

No error, no non-zero exit — but the collection stays empty:

```bash
source env.sh
TOKEN=...   # see "Getting an API token by hand"
curl -s --cacert certs/lab-ca.crt -H "Authorization: Bearer $TOKEN" \
  "https://stigman.mil/api/assets?collectionId=1" | jq length     # -> 0
```

**Cause.** PowerShell/.NET, Python, Java and Node on Linux all validate against
the OpenSSL/system trust store, not curl's `--cacert` flag. With the CA absent,
the first HTTPS call throws:

```
HttpRequestException: The SSL connection could not be established
  inner: The remote certificate is invalid because of errors in the
         certificate chain: UntrustedRoot
```

In Evaluate-STIG that first call is OIDC discovery in `Get-SMAuthToken`
(`Modules/Master_Functions/STIGManager/STIGManager.psm1:121`):

```powershell
$apiauthendpoint = Invoke-RestMethod -Method Get -Uri "$SMImport_AUTHORITY/.well-known/openid-configuration" |
    Select-Object -ExpandProperty token_endpoint
```

That line has **no `Try`/`Catch` and no `Write-Log`**, unlike every other error
path in the same function, so the exception unwinds past the upload and the run
still prints `Done!`. The tell is that
`/tmp/Evaluate-STIG/Evaluate-STIG_STIGManager.log` is never created: each
`Get-SMAuthToken` failure path writes to it, so its absence means the throw
happened before any of them.

**Diagnosis.** Compare system trust against the lab CA — exit 60 is
"unable to get local issuer certificate":

```bash
# want 200 with no --cacert; code 000 / exit 60 means the CA is missing
curl -sS -o /dev/null -w 'system trust: %{http_code}\n' \
  https://keycloak.mil/realms/stigman/.well-known/openid-configuration

# proves the endpoint itself is fine
curl -sS -o /dev/null -w 'lab CA:       %{http_code}\n' --cacert certs/lab-ca.crt \
  https://keycloak.mil/realms/stigman/.well-known/openid-configuration

ls /usr/local/share/ca-certificates/        # empty => never installed
```

Reproduce exactly what .NET sees:

```bash
pwsh -NoProfile -Command '
try { (Invoke-RestMethod https://keycloak.mil/realms/stigman/.well-known/openid-configuration).token_endpoint }
catch { $_.Exception.InnerException.Message }'
```

**Fix.** Install the lab CA into the system trust store. The `.crt` extension is
required — `update-ca-certificates` ignores anything else:

```bash
sudo cp "$PWD/certs/lab-ca.crt" \
        /usr/local/share/ca-certificates/stig-lab-ca.crt
sudo update-ca-certificates
```

Then re-run the client. Java keeps its own store and needs `keytool -importcert`
into its `cacerts` as well; Python's `certifi` bundle is separate again, so use
`REQUESTS_CA_BUNDLE=$PWD/certs/lab-ca.crt` for requests-based
tools rather than editing `certifi`.

> **Scope note.** This makes the host trust a lab CA for *all* TLS, and the CA
> private key sits in `certs/` on this box. Anyone who can read it can mint a
> trusted certificate for any hostname. Fine for a disposable lab; do not do it
> on a machine that matters. `scripts/99-down.sh --purge` deletes the CA but does
> **not** remove it from the system store — `sudo rm
> /usr/local/share/ca-certificates/stig-lab-ca.crt && sudo update-ca-certificates`
> does.

**Three things that look like the bug but are not.**

| Red herring | Reality |
|---|---|
| `https://stigman.mil/api` returns `{"error":"not found"}` | Expected. `/api` is a base path with no route of its own; `/api/collections`, `/api/stigs` and `/api/op/configuration` all return 200. The vendor's own example is the same shape. |
| Guide shows `Attempting upload of N Reviews...`, your run omits it | That string does not exist in Evaluate-STIG 1.2601.3 — it is from 1.2407.0, which the community guide was written against. Not a failure signal. |
| `Failed to get full CAT counts for grading.` | From `Get-RiskScore` (`Evaluate-STIG.ps1:4550`); a scoring-accuracy warning with nothing to do with uploading. |

### Collecting everything at once

```bash
source env.sh
{
  echo "### verify";       ./scripts/08-verify.sh
  echo "### containers";   docker ps -a --filter label=floci=true
  echo "### disk";         df -h /; docker system df
  echo "### clusters";     aws eks list-clusters
  echo "### nodes";        for c in keycloak stigman; do kubectl --context $c get nodes -o wide; done
  echo "### pods";         for c in keycloak stigman; do kubectl --context $c get pods -A; done
  echo "### targets";      aws elbv2 describe-target-health --target-group-arn \
                             $(aws elbv2 describe-target-groups --names stigman-tg \
                               --query 'TargetGroups[0].TargetGroupArn' --output text)
  echo "### floci log";    docker logs --tail 100 floci
} > /tmp/stig-cloud-lab-diag.txt 2>&1
```

---

## How this differs from the AWS original

Everything here was driven by something Floci does differently from AWS. Each one
is commented at the point it appears in the Terraform.

| Original | Here | Why |
|---|---|---|
| `terraform-aws-modules/vpc` + `eks` modules | Plain `aws_vpc` / `aws_eks_cluster` resources | The community modules reach for flow logs, EIP association and AZ lookups the emulator only partly answers. Plain resources are also what the README has to explain. |
| AWS Load Balancer Controller watches `Ingress` and creates ALBs | Terraform creates the ALBs; Services are `NodePort` | Running the controller needs its pod to hold IRSA credentials and call ELBv2. The resulting AWS objects are the same shape. The IRSA roles it would use are still created, in `02-iam.tf`. |
| Target groups `target-type: ip` → pod IPs | `target_type = "ip"` → node IP + NodePort | Floci's ALB data plane hands an `instance` target's ID straight to DNS, so `target_type = "instance"` cannot work. |
| `gp2` PVC via the EBS CSI driver | `local-path` PVC | Floci records cluster addons but installs nothing, so a `gp2` claim stays `Pending` — exactly as on real EKS with no CSI driver. The addon is still declared, for fidelity. |
| 2 nodes on `stigman-eks` | 1 node | Floci runs one k3s container per cluster. The node group's `desired_size` is recorded, not honoured. |
| Internal ALBs reached from a Windows jump box over RDP | Published on `127.0.0.1:443`, reached from the host browser | The jump box existed to get inside the VPC. There is no VPC to be outside of. |
| ALB DNS names (`internal-k8s-...elb.amazonaws.com`) | `stigman.mil` / `keycloak.mil` | Fixed names mean the OIDC issuer is stable and both the browser and the pods can use the same URL. |
| Self-signed certs imported into ACM by hand | Terraform mints a CA and two leaves, imports both | One CA to trust, and the certificate always matches the hostname. |
| Health check success codes fixed in the console | `matcher = "200,301,302"` in the target group | Same fix, declared instead of clicked. |
| `aws-auth` ConfigMap / access entries | `access_config { authentication_mode = "API" }` + access entries | Floci rejects `CreateAccessEntry` unless the cluster is in `API` mode. |
| — | `scripts/06-patch-eviction.sh` | Floci hardcodes `eviction-hard=...nodefs.available<10%` into the k3s command line and refuses to let the documented tag passthrough override it. On a large disk that evicts pods while gigabytes are free. |
| — | `coredns-custom` ConfigMap | k3s will not give CoreDNS a loopback resolver, so it substitutes a public one and pods cannot resolve `.mil`. |
| — | `scripts/01-bootstrap-iam.sh` | Floci's EKS webhook verifies the bearer token's SigV4 signature against a key in its own IAM store, so the lab needs a real (emulated) IAM user before `kubectl` works. |

### Things that are genuinely real here

Worth knowing, because it is more than a mock: the Kubernetes API servers, the
scheduler, kubelet, CoreDNS, the MySQL database and its migrations, the Keycloak
realm and its JWT signing, ALB TLS termination and SNI selection, ACM key
material, the IAM SigV4 signature check on every `kubectl` call, and the full
OIDC authorization-code flow in the browser.

---

## What each piece does

```
stig-cloud-lab/
├── docker-compose.yml          Floci: persistent storage, publishes 4566/443/8080/5353
├── env.sh                      Points a shell at Floci and ONLY at Floci
├── aws/                        Lab-only AWS config + credentials (never ~/.aws)
├── certs/lab-ca.crt            CA to trust; written by Terraform
├── data/                       Floci's persistent state (FLOCI_STORAGE_MODE=persistent)
├── kubeconfig                  Lab-only kubeconfig (never ~/.kube/config)
├── terraform/
│   ├── 01-infra/               Stage 1 — the AWS layer
│   │   ├── provider.tf           per-service endpoint overrides
│   │   ├── 01-network.tf         VPC 10.100.0.0/16, 2 public + 2 private subnets
│   │   ├── 02-iam.tf             cluster/node roles, OIDC providers, IRSA roles
│   │   ├── 03-eks.tf             both clusters, node groups, addon, access entries
│   │   ├── 04-certs.tf           lab CA, two leaves, ACM imports
│   │   ├── 05-alb.tf             ALBs, target groups, HTTPS + redirect listeners
│   │   └── 06-dns.tf             Route53 private "mil" zone
│   └── 02-workloads/           Stage 2 — the Kubernetes layer
│       ├── provider.tf           two kubernetes providers, from stage 1's state
│       ├── 01-keycloak.tf        Keycloak Deployment + NodePort Service
│       ├── 02-stigman.tf         MySQL + PVC, STIG Manager API, NodePort Service
│       └── 03-coredns.tf         coredns-custom ConfigMap on both clusters
└── scripts/
    ├── 00-up.sh                Everything, in order. Idempotent.
    ├── 01-bootstrap-iam.sh     Mint the emulated IAM user
    ├── 02-apply-infra.sh       Stage 1 apply (discovers Floci's network IP)
    ├── 03-kubeconfig.sh        Write the kubeconfig, pinning the lab's AWS env
    ├── 04-apply-workloads.sh   Stage 2 apply
    ├── 05-hosts.sh             /etc/hosts entries (--remove to undo)
    ├── 06-patch-eviction.sh    Relax kubelet's disk-eviction threshold
    ├── eviction_patch.py       The mechanics, and why it must recreate containers
    ├── 07-keycloak-client.sh   Narrow the Keycloak client to stigman.mil
    ├── 08-verify.sh            13 checks, bottom-up
    └── 99-down.sh              stop | --destroy | --purge
```

**Why two Terraform stages.** The `kubernetes` provider has to be configured
from each cluster's API endpoint and CA certificate, which do not exist until the
clusters do. A single root module would need those values at plan time and fail
on a clean checkout. Stage 2 reads stage 1's state through
`terraform_remote_state`, so the NodePorts, hostnames and issuer URL are defined
once, in stage 1, and stage 2 cannot drift from them.

---

## Teardown

```bash
# Stop the containers, keep everything (fastest to resume: ./scripts/00-up.sh)
./scripts/99-down.sh

# Destroy the Terraform-managed resources, then stop
./scripts/99-down.sh --destroy

# Destroy, stop, and delete Floci's state, the k3s volumes, certs and kubeconfig
./scripts/99-down.sh --purge
```

None of these touch `~/.aws`, `~/.kube/config`, or anything outside this
directory and Docker's own storage. `--purge` leaves the Terraform state files
alone; remove them too for a completely clean slate:

```bash
rm -f terraform/0*/terraform.tfstate*
```

---

## References

- [STIG Manager](https://github.com/NUWCDIVNPT/stig-manager) · [docs](https://stig-manager.readthedocs.io/)
- [stig-manager-auth (demo Keycloak image)](https://hub.docker.com/r/nuwcdivnpt/stig-manager-auth)
- [Floci](https://github.com/floci-io/floci) · [docs](https://floci.io/floci/) · local copy: `~/floci/docs`
- Floci EKS behaviour: `~/floci/docs/services/eks.md`
- Floci ELBv2 behaviour: `~/floci/docs/services/elb.md`
- [k9s](https://k9scli.io/)
- The AWS original this rebuilds: `../eks-lab-terraform`
