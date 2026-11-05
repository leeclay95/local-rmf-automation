#!/usr/bin/env python3
"""Rewrite the kubelet eviction thresholds on Floci's k3s containers.

Why this exists
---------------
Floci hardcodes the node's kubelet flags when it creates a cluster container:

    --kubelet-arg=eviction-hard=memory.available<NNNNMi,nodefs.available<10%,nodefs.inodesFree<5%

`nodefs.available<10%` is 10% of the *host* filesystem, because the k3s data
volume lives on /var/lib/docker. On a large, fairly full disk that threshold is
several GB, so kubelet reports DiskPressure, taints the node and evicts pods
while there is still plenty of usable space.

`eviction-hard` is on Floci's managed-flag list, so the documented
`floci:kubelet-arg:...` tag passthrough refuses to override it, and a
/etc/rancher/k3s/config.yaml entry loses because Floci's command-line copy is
merged last. The flag lives in the container's immutable Cmd, so the only way to
change it is to recreate the container with the Cmd rewritten.

That is what this does, via the Docker Engine API, preserving:
  * the container name, image, entrypoint, env and all Floci labels (Floci
    re-adopts the container on restart by name and label, and compares its
    io.floci.eks.node-capacity label, so these must not drift),
  * the named k3s data volume and the anonymous /var/log, /var/lib/cni and
    /var/lib/kubelet volumes,
  * the published API server host port, so existing kubeconfigs keep working,
  * every network attachment *and its IP address*, because the ALB target
    groups in terraform/01-infra register the node by address.

Idempotent: a container already carrying the wanted threshold is left alone.
Re-run it after anything that makes Floci rebuild a cluster container.
"""

import json
import socket
import sys
import time
import urllib.parse

SOCK = "/var/run/docker.sock"
API = "http://localhost/v1.44"

# Floci copies these into the container's writable layer after creating it, so a
# recreated container starts without them and the API server dies on
# "failed to parse service-account-issuer-key-file". They are carried across
# from the old container before the new one is started.
#   /etc/sa-signing-key.pem, /etc/sa-public-key.pem  IRSA signing keypair
#   /etc/token-webhook.yaml                          IAM auth webhook kubeconfig
#   /etc/rancher/k3s/registries.yaml                 ECR registry mirror
INJECTED_PATHS = [
    "/etc/sa-signing-key.pem",
    "/etc/sa-public-key.pem",
    "/etc/token-webhook.yaml",
    "/etc/rancher",
]

# Keep the memory.available term Floci calculated; only relax the disk terms.
NODEFS_AVAIL = "nodefs.available<1Gi"
NODEFS_INODES = "nodefs.inodesFree<2%"


class Docker:
    """Minimal Docker Engine API client over the unix socket."""

    def _request(self, method, path, body=None):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.connect(SOCK)
        payload = b"" if body is None else json.dumps(body).encode()
        head = (
            f"{method} {path} HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Content-Type: application/json\r\n"
            f"Content-Length: {len(payload)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode()
        conn.sendall(head + payload)

        raw = b""
        while chunk := conn.recv(65536):
            raw += chunk
        conn.close()

        header, _, rest = raw.partition(b"\r\n\r\n")
        status = int(header.split(b"\r\n", 1)[0].split()[1])
        if b"transfer-encoding: chunked" in header.lower():
            rest = self._dechunk(rest)
        text = rest.decode(errors="replace")
        if status >= 400:
            raise RuntimeError(f"{method} {path} -> {status}: {text[:400]}")
        return json.loads(text) if text.strip() else None

    @staticmethod
    def _dechunk(body):
        out = b""
        while body:
            size_line, _, body = body.partition(b"\r\n")
            try:
                size = int(size_line.split(b";")[0], 16)
            except ValueError:
                break
            if size == 0:
                break
            out += body[:size]
            body = body[size + 2:]
        return out

    def _request_raw(self, method, path, body=b"", content_type="application/json"):
        """Same as _request but returns the raw body, for tar archives."""
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.connect(SOCK)
        head = (
            f"{method} {path} HTTP/1.1\r\n"
            "Host: localhost\r\n"
            f"Content-Type: {content_type}\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode()
        conn.sendall(head + body)
        raw = b""
        while chunk := conn.recv(262144):
            raw += chunk
        conn.close()
        header, _, rest = raw.partition(b"\r\n\r\n")
        status = int(header.split(b"\r\n", 1)[0].split()[1])
        if b"transfer-encoding: chunked" in header.lower():
            rest = self._dechunk(rest)
        if status >= 400:
            raise RuntimeError(f"{method} {path} -> {status}: {rest[:300]!r}")
        return rest

    def get_archive(self, name, path):
        q = urllib.parse.urlencode({"path": path})
        return self._request_raw(
            "GET", f"{API}/containers/{urllib.parse.quote(name)}/archive?{q}")

    def put_archive(self, name, path, tar_bytes):
        q = urllib.parse.urlencode({"path": path})
        self._request_raw(
            "PUT", f"{API}/containers/{urllib.parse.quote(name)}/archive?{q}",
            tar_bytes, content_type="application/x-tar")

    def inspect(self, name):
        return self._request("GET", f"{API}/containers/{urllib.parse.quote(name)}/json")

    def stop(self, name, timeout=30):
        self._request("POST", f"{API}/containers/{urllib.parse.quote(name)}/stop?t={timeout}")

    def rename(self, name, new):
        self._request("POST", f"{API}/containers/{urllib.parse.quote(name)}/rename?name={new}")

    def remove(self, name):
        self._request("DELETE", f"{API}/containers/{urllib.parse.quote(name)}?v=0&force=1")

    def create(self, name, payload):
        return self._request("POST", f"{API}/containers/create?name={name}", payload)

    def start(self, name):
        self._request("POST", f"{API}/containers/{urllib.parse.quote(name)}/start")

    def connect(self, network, container, payload):
        self._request(
            "POST",
            f"{API}/networks/{urllib.parse.quote(network)}/connect",
            {"Container": container, **payload},
        )

    def list_eks(self):
        filters = urllib.parse.quote(json.dumps({"label": ["io.floci.service=eks"]}))
        return self._request("GET", f"{API}/containers/json?all=1&filters={filters}")


def patch_cmd(cmd):
    """Return (new_cmd, changed). Rewrites only the eviction-hard kubelet arg."""
    out, changed = [], False
    for arg in cmd:
        if "eviction-hard=" not in arg:
            out.append(arg)
            continue
        prefix, _, spec = arg.partition("eviction-hard=")
        terms = []
        for term in spec.split(","):
            key = term.split("<")[0].split(">")[0].strip()
            if key == "nodefs.available":
                terms.append(NODEFS_AVAIL)
            elif key == "nodefs.inodesFree":
                terms.append(NODEFS_INODES)
            else:
                terms.append(term)
        new_arg = prefix + "eviction-hard=" + ",".join(terms)
        changed = changed or new_arg != arg
        out.append(new_arg)
    return out, changed


def recreate(docker, name):
    info = docker.inspect(name)
    cfg, host = info["Config"], info["HostConfig"]

    new_cmd, changed = patch_cmd(cfg.get("Cmd") or [])
    if not changed:
        print(f"    {name}: already patched, leaving alone")
        return False

    current = next(a for a in (cfg.get("Cmd") or []) if "eviction-hard=" in a)
    wanted = next(a for a in new_cmd if "eviction-hard=" in a)
    print(f"    was: {current.split('eviction-hard=')[1]}")
    print(f"    now: {wanted.split('eviction-hard=')[1]}")

    # Image by name, not by sha, so the new container reads the same in `ps`.
    image = info.get("Image")
    mounts = [
        {
            "Type": m["Type"],
            "Source": m.get("Name") or m.get("Source"),
            "Target": m["Destination"],
            "ReadOnly": not m.get("RW", True),
        }
        for m in info.get("Mounts", [])
    ]

    networks = info["NetworkSettings"]["Networks"]
    primary = host.get("NetworkMode", "bridge")

    payload = {
        "Image": image,
        "Cmd": new_cmd,
        "Entrypoint": cfg.get("Entrypoint"),
        "Env": cfg.get("Env"),
        "Labels": cfg.get("Labels"),
        "Volumes": cfg.get("Volumes"),
        "ExposedPorts": cfg.get("ExposedPorts"),
        "Tty": cfg.get("Tty", False),
        "OpenStdin": cfg.get("OpenStdin", False),
        "AttachStdout": False,
        "AttachStderr": False,
        "HostConfig": {
            "Mounts": mounts,
            "Privileged": host.get("Privileged", False),
            "Memory": host.get("Memory", 0),
            "MemorySwap": host.get("MemorySwap", 0),
            "NanoCpus": host.get("NanoCpus", 0),
            "PortBindings": host.get("PortBindings") or {},
            "Dns": host.get("Dns") or [],
            "ExtraHosts": sorted(set(host.get("ExtraHosts") or [])),
            "SecurityOpt": host.get("SecurityOpt") or [],
            "CgroupnsMode": host.get("CgroupnsMode") or "",
            "LogConfig": host.get("LogConfig") or {},
            "ShmSize": host.get("ShmSize", 0),
            "RestartPolicy": host.get("RestartPolicy") or {"Name": "no"},
            "NetworkMode": primary,
        },
        # Only the primary network can be set at create time; the rest are
        # connected afterwards, each pinned to the address it already had.
        "NetworkingConfig": {
            "EndpointsConfig": {
                primary: endpoint_config(primary, networks.get(primary, {}))
            }
        } if primary in networks else {},
    }

    backup = f"{name}-preevict"
    print(f"    stopping {name}")
    docker.stop(name)
    docker.rename(name, backup)

    try:
        docker.create(name, payload)

        # Must happen before start: k3s reads these during bootstrap.
        for path in INJECTED_PATHS:
            try:
                tar = docker.get_archive(backup, path)
            except RuntimeError as exc:
                print(f"    note: {path} not present on the old container ({exc})")
                continue
            docker.put_archive(name, "/etc", tar)
        print(f"    carried over {len(INJECTED_PATHS)} injected path(s)")

        for net, settings in networks.items():
            if net == primary:
                continue
            docker.connect(net, name, endpoint_config(net, settings))
        docker.start(name)
    except Exception:
        print(f"    !! failed; restoring original as {name}", file=sys.stderr)
        try:
            docker.remove(name)
        except Exception:
            pass
        docker.rename(backup, name)
        docker.start(name)
        raise

    docker.remove(backup)
    print(f"    recreated {name}")
    return True


# Docker's predefined networks do not accept a user-specified address.
PREDEFINED_NETWORKS = {"bridge", "host", "none"}


def endpoint_config(network, settings):
    """Preserve the address and aliases an endpoint already holds.

    The address is what matters: terraform/01-infra registers the node in the
    ALB target groups by IP, so a container that comes back on a different
    address would leave the target group pointing at nothing.
    """
    cfg = {}
    ipv4 = settings.get("IPAddress")
    if ipv4 and network not in PREDEFINED_NETWORKS:
        cfg["IPAMConfig"] = {"IPv4Address": ipv4}
    aliases = [a for a in (settings.get("Aliases") or []) if a]
    if aliases:
        cfg["Aliases"] = aliases
    return cfg


def main():
    docker = Docker()
    targets = sys.argv[1:]
    if not targets:
        targets = [
            c["Names"][0].lstrip("/")
            for c in (docker.list_eks() or [])
            if c.get("Names")
        ]
    if not targets:
        print("no Floci EKS cluster containers found", file=sys.stderr)
        return 1

    patched = 0
    for name in sorted(targets):
        print(f"==> {name}")
        if recreate(docker, name):
            patched += 1

    if patched:
        print(f"\n==> recreated {patched} container(s); waiting for API servers")
        time.sleep(5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
