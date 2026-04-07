# Tailbox Server — Mullvad VPN Gateway

![Tailbox Architecture](images/header.png)

> **Work in progress.** This project is functional and running in production, but is still being refined. Contributions and feedback welcome.

The server side of [Tailbox](https://github.com/tdwgm/tailbox-client): a Docker Compose stack that runs a Mullvad WireGuard tunnel (via Gluetun) with a Tailscale node and a SOCKS5 proxy (microsocks) sharing the tunnel's network namespace. Clients connect over Tailscale and forward traffic through the proxy, which exits via Mullvad.

All sidecar containers — Tailscale, microsocks, and the optional DNS sidecar — live inside Gluetun's network namespace. They have no direct host network access; all outbound traffic transits the VPN tunnel.

## Architecture

```
CLIENT (Linux, Podman, rootless or root)
─────────────────────────────────────────────────────────────────────
  Application (curl, browser, proxychains)
       │
       │  SOCKS5  localhost:1055
       ▼
  ┌──────────────────────────────────────────────────────────┐
  │  tailbox container  (tailscale-local:latest)             │
  │                                                          │
  │  ┌────────────────┐   ┌──────────────────────────────┐  │
  │  │ socat           │   │ Tailscale daemon              │  │
  │  │ LISTEN:1081    │──▶│ (kernel tun or userspace)    │  │
  │  │ EXEC:tailscale │   │                              │  │
  │  │   nc <endpoint>│   │  tailscale0 / tun0           │  │
  │  │   <port>       │   └──────────┬───────────────────┘  │
  │  └────────────────┘              │                       │
  │                                  │ WireGuard / DERP      │
  │  kill switch (iptables):         │ UDP 41641             │
  │  eth0 → DROP (except TS traffic) │                       │
  └──────────────────────────────────┼───────────────────────┘
       │ podman port map 1055→1081   │
       │                             │ Tailscale control plane (tcp/443)
       ▼                             │ STUN (udp/3478)
  localhost:1055                     │
                              ───────┼──── Internet ────────────────
                                     │
                                     ▼ WireGuard encrypted tunnel

SERVER (Linux / Docker)
─────────────────────────────────────────────────────────────────────
  ┌────────────────────────────────────────────────────────────────┐
  │  mullvad-gateway  (qmcgaw/gluetun)                             │
  │  Network namespace shared by all sidecar containers            │
  │                                                                │
  │  Interfaces:  eth0 (docker bridge)                             │
  │               tun0 (Mullvad WireGuard)                         │
  │               tailscale0 (Tailscale)                           │
  │                                                                │
  │  ┌──────────────────────┐   ┌─────────────────────────────┐   │
  │  │ tailscale-endpoint   │   │ tailbox-socks (microsocks)  │   │
  │  │ network_mode:        │   │ network_mode:               │   │
  │  │   container:mullvad  │   │   container:mullvad         │   │
  │  │ Tailscale daemon     │   │ Listens :1080               │   │
  │  │ tailscale0           │   │ Proxies to tun0             │   │
  │  └──────────────────────┘   └─────────────────────────────┘   │
  │                                                                │
  │  ┌──────────────────────┐                                      │
  │  │ tailbox-dns (dnsmasq)│  [DNS_MODE=split only]               │
  │  │ network_mode:        │                                      │
  │  │   container:mullvad  │                                      │
  │  │ Listens :5353        │                                      │
  │  └──────────────────────┘                                      │
  │                                                                │
  │  iptables (gluetun kill switch):                               │
  │    INPUT/OUTPUT default DROP                                   │
  │    ACCEPT tun0, lo, ESTABLISHED                                │
  │    ACCEPT FIREWALL_INPUT_PORTS (1080, ...)                     │
  │                                                                │
  │  ip routing rules (applied by gluetun-watcher):               │
  │    prio 100: to 100.64.0.0/10 lookup 52  (Tailscale CGNAT)    │
  │    table 51820: 100.64.0.0/10 dev tailscale0  (WireGuard table)│
  └──────────────────────────────────┬─────────────────────────────┘
                                     │
                                     │ tun0
                                     ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  Mullvad VPN  (WireGuard)                                       │
  │  Endpoint: <server>.mullvad.net:51820 (or :443)                 │
  └─────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼ Internet

  Management containers (on host network / socket-proxy-net)
  ─────────────────────────────────────────────────────────
  ┌─────────────────────┐    ┌──────────────────────────────────┐
  │ docker-socket-proxy  │    │ mullvad-autoheal (autoheal)       │
  │ tecnativa/docker-    │◀───│ Watches label autoheal=true       │
  │ socket-proxy         │    │ Calls Docker API via socket-proxy  │
  │ CONTAINERS, EVENTS,  │    │ to restart unhealthy containers   │
  │ POST only            │    └──────────────────────────────────┘
  └─────────────────────┘

  ┌──────────────────────────────────────────────────────────────┐
  │ gluetun-watcher.sh (systemd service)                         │
  │ Watches: docker events --filter container=mullvad-gateway    │
  │ On gluetun start: force-recreate dependent stacks,           │
  │ apply routing fix via nsenter                                │
  └──────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **Mullvad account** — a WireGuard private key and assigned address from [mullvad.net/account/wireguard-config](https://mullvad.net/en/account/wireguard-config)
- **Tailscale account** — the server node will advertise itself as an exit node; approve it in the admin console
- **Docker Engine** + **Docker Compose v2** (`docker compose version`)
- **jq** (`apt install jq` / `dnf install jq`)

## Quick Start

```bash
git clone https://github.com/tdwgm/tailbox-server.git
cd tailbox-server/scripts
./install-server.sh
```

The installer:
1. Checks prerequisites
2. Creates the `tailbox-net` Docker network
3. Copies `.env.example` to `.env` and prompts you to fill it in
4. Collects the Mullvad WireGuard key and optional Tailscale auth key (hidden input, not logged)
5. Generates the dnsmasq config based on `DNS_MODE`
6. Installs `gluetun-watcher.sh` and `mullvad-exitnode-init.sh` to `/usr/local/bin`
7. Creates and enables a systemd service for the watcher
8. Starts all stacks in the correct order
9. Verifies VPN connectivity via `am.i.mullvad.net`

To start the Tailscale node on first run without a pre-configured auth key, watch its logs for the login URL:

```bash
docker logs tailscale-endpoint 2>&1 | grep login
```

## DNS Configuration

Tailbox needs to answer two competing requirements: all public DNS queries must resolve via the VPN to avoid leaking browsing intent, and local domain names (e.g. `ha.lan.example.com`) must resolve to their real LAN IP addresses so that traffic stays on the local network. These requirements are in direct conflict with a single upstream DNS server.

### The Problem

**Using Mullvad DNS only (`10.64.0.1`)**

Mullvad's DNS server knows nothing about your LAN. A domain like `ha.lan.example.com` may be configured as a CNAME to a public hostname in your external DNS, which resolves to a public IP. When you connect via SOCKS5 and that domain resolves to a public IP, your reverse proxy receives a request from the Docker network (e.g. `172.18.x.x`) rather than from a trusted LAN address. If the reverse proxy enforces an IP allowlist (`sourceRange: ["192.168.1.0/24"]`), the request is rejected.

Even if the allowlist is relaxed, traffic now hairpins through the internet (your home IP to Mullvad exit to public IP to your home again) and is subject to latency and potential double-NAT issues.

**Using local DNS only (e.g. Pi-hole at `192.168.1.x`)**

If gluetun forwards all DNS to a local server, that server resolves everything — including `google.com`, `amazon.com`, and every other public domain — via your ISP's DNS. Every hostname you look up leaks outside the VPN tunnel. This defeats a significant portion of the privacy protection the VPN provides.

### The Solution: Split DNS

Tailbox solves this with a dnsmasq sidecar that performs domain-based DNS routing:

```
Application
    |
    |  DNS query (via SOCKS5 or system resolver)
    v
gluetun built-in DNS proxy  (:53)
    |
    |  All queries forwarded to 127.0.0.1:5353
    |  (DNS_UPSTREAM_PLAIN_ADDRESSES=127.0.0.1:5353)
    v
dnsmasq sidecar (tailbox-dns, :5353)
    |
    |-- *.lan.example.com  -->  192.168.1.x (Pi-hole / local DNS)
    |                           via eth0 (LAN, FIREWALL_OUTBOUND_SUBNETS)
    |
    +-- everything else    -->  10.64.0.1 (Mullvad DNS)
                                via tun0 (WireGuard tunnel)
```

The dnsmasq container runs inside gluetun's network namespace (`network_mode: "container:mullvad-gateway"`), so it has access to both `tun0` (for Mullvad DNS) and `eth0` (for LAN DNS, allowed by `FIREWALL_OUTBOUND_SUBNETS`). It listens on port 5353 because gluetun's own DNS proxy already owns port 53.

gluetun is configured to forward all queries to dnsmasq:

```yaml
DNS_UPSTREAM_PLAIN_ADDRESSES=127.0.0.1:5353
```

dnsmasq splits by domain using a generated `dnsmasq.conf`:

```
# Local domain -> LAN DNS server (via eth0)
server=/<DNS_LOCAL_DOMAIN>/<DNS_LOCAL_SERVER>

# Reverse DNS for private subnets -> LAN DNS server
server=/168.192.in-addr.arpa/<DNS_LOCAL_SERVER>
server=/10.in-addr.arpa/<DNS_LOCAL_SERVER>
server=/16.172.in-addr.arpa/<DNS_LOCAL_SERVER>
# ... (all 172.16-31.x subnets)

# Everything else -> Mullvad DNS (via tun0)
server=10.64.0.1
```

### Three DNS Modes

| Mode | DNS_UPSTREAM (gluetun) | dnsmasq | Behaviour | DNS Leak |
|------|------------------------|---------|-----------|----------|
| `split` (default) | `127.0.0.1:5353` | Running | Local domains to LAN DNS. All other queries to Mullvad DNS via tun0. | No |
| `mullvad` | `10.64.0.1` | Not started | All queries go directly to Mullvad DNS via tun0. Local domains resolve to public IPs or fail. | No |
| `custom` | Your server (e.g. `192.168.1.x`) | Not started | All queries go to a custom server. If that server is on the LAN, ALL DNS leaks outside the tunnel. | **Yes** |

`custom` mode is provided for advanced use cases where the operator explicitly accepts DNS leakage (for example, a Pi-hole with its own upstream DoH/DoT that routes queries privately). The default is `split`.

### DNS Environment Variables

All DNS settings live in `gluetun-mullvad/.env`:

| Variable | Description | Example |
|----------|-------------|---------|
| `DNS_MODE` | DNS mode: `split`, `mullvad`, or `custom` | `split` |
| `DNS_LOCAL_DOMAIN` | Domain suffix routed to LAN DNS (split mode) | `lan.example.com` |
| `DNS_LOCAL_SERVER` | IP of your LAN DNS server (split mode) | `192.168.1.x` |
| `DNS_CUSTOM_SERVER` | DNS server for custom mode | `192.168.1.x` |
| `DNS_UPSTREAM` | Set automatically by install-server.sh — do not edit manually | `10.64.0.1` or `127.0.0.1:5353` |

When `DNS_MODE=split`, the install script runs `dns/generate-config.sh` to produce `dnsmasq.conf` by substituting `DNS_LOCAL_DOMAIN` and `DNS_LOCAL_SERVER` into the template, then sets `DNS_UPSTREAM=127.0.0.1:5353` in the environment passed to gluetun.

When `DNS_MODE=mullvad`, `DNS_UPSTREAM=10.64.0.1` and the dnsmasq stack is not started.

When `DNS_MODE=custom`, `DNS_UPSTREAM` is set to `DNS_CUSTOM_SERVER` and the dnsmasq stack is not started.

### How to Verify DNS

**Check that DNS queries go through Mullvad:**

```bash
docker exec mullvad-gateway wget -qO- https://am.i.mullvad.net/dns
```

Expected output: `{"mullvad_dns_leak_protection":true,...}` with `"dns_leak":false`.

**Test local domain resolution (split mode):**

```bash
# Query dnsmasq directly on port 5353
docker exec mullvad-gateway nslookup yourhost.lan.example.com 127.0.0.1 -port=5353

# Expected: local IP (e.g. 192.168.1.x), NOT a public IP
```

**Test public domain resolution:**

```bash
docker exec mullvad-gateway nslookup example.com 127.0.0.1 -port=5353
```

Expected: resolves via Mullvad DNS. You can cross-reference the result against `dig @10.64.0.1 example.com` to confirm the same answer.

**Check which DNS server gluetun is using:**

```bash
docker exec mullvad-gateway cat /etc/resolv.conf
```

In split mode this should show `nameserver 127.0.0.1` (gluetun's own proxy, which forwards to dnsmasq on 5353).

**Check dnsmasq is running:**

```bash
docker logs tailbox-dns
docker exec mullvad-gateway nslookup example.com 127.0.0.1 -port=5353
```

### Why gluetun Cannot Do This Natively

gluetun has built-in DNS proxy support and can be configured with multiple upstream DNS servers. However, when multiple upstreams are configured, gluetun load-balances between them — it does not route by domain. Every query can be sent to any of the configured upstream servers, so there is no way to pin local domain queries to a LAN server and public queries to Mullvad.

This is a known limitation. Feature requests for domain-based DNS routing exist in the gluetun issue tracker (GitHub issues #3233 and #1839) but are not implemented as of the time of writing. The dnsmasq sidecar is the community-recommended pattern for split DNS with gluetun.

## Adding Sidecar Containers

Any container that should route its traffic through Mullvad can share the `mullvad-gateway` network namespace. Three steps:

1. **Add the service** to `tailscale-endpoint/docker-compose.yaml` (or a new compose file) with:
   ```yaml
   network_mode: "container:mullvad-gateway"
   ```
2. **Expose its port** on the `gluetun` service in `gluetun-mullvad/docker-compose.yaml` (not on the sidecar itself — it has no independent network):
   ```yaml
   ports:
     - "8080:8080"
   ```
3. **Allow the port inbound** in Gluetun's firewall by adding it to `FIREWALL_INPUT_PORTS` in `.env`:
   ```dotenv
   FIREWALL_INPUT_PORTS=1080,8080
   ```

Then add the container name to `DEPENDENT_CONTAINERS` in `gluetun-watcher.sh` so it is automatically recreated when the VPN restarts.

## Security Hardening

All containers in this stack apply the following hardening by default:

- **Image digest pinning** — every image is referenced by `@sha256:...` digest, not a mutable tag. The pinned digest is committed to the repository; updates require an intentional digest change.
- **`no-new-privileges`** — `security_opt: no-new-privileges:true` prevents privilege escalation via setuid binaries.
- **`cap_drop: ALL`** — all Linux capabilities are dropped; only the minimum required (e.g. `NET_ADMIN` for Gluetun and Tailscale, `NET_BIND_SERVICE` for dnsmasq) are added back explicitly.
- **Read-only root filesystem** — `read_only: true` on Tailscale-endpoint, microsocks, and dnsmasq; writable tmpfs mounts cover only `/tmp` and `/run`.
- **Docker socket proxy** — `autoheal` connects to Docker via `tecnativa/docker-socket-proxy` (scoped to containers + events + POST for restart), not the raw socket. POST is required for autoheal to restart unhealthy containers.
- **Resource limits** — all services set `deploy.resources.limits` (memory and CPU) to bound resource consumption.
- **Secrets via files** — WireGuard private key and Tailscale auth key are passed via Docker secrets (files mounted at `/run/secrets/`), never as environment variables.
- **IPv6 disabled** — `net.ipv6.conf.all.disable_ipv6=1` on Gluetun prevents IPv6 leaks through the tunnel.

## How It Works

### Network Namespace Sharing

All sidecar containers on the server run with `network_mode: "container:mullvad-gateway"`. This means they do not get their own network stack — they share the exact same stack as the gluetun container, including:

- **eth0** — the Docker bridge interface (host connectivity)
- **tun0** — the Mullvad WireGuard tunnel
- **tailscale0** — the Tailscale virtual interface (kernel mode) or a userspace equivalent

Because all three services (tailscale-endpoint, tailbox-socks, tailbox-dns) live in the same namespace, microsocks can bind to `:1080` and Tailscale will see `tailscale0` as if it were on the same host. There is no inter-container routing; everything is loopback-equivalent from a networking perspective.

A consequence of this design is that when gluetun restarts, its network namespace is destroyed and recreated. Any container sharing that namespace loses its network stack and must be force-recreated. This is handled by `gluetun-watcher.sh`.

Ports exposed by sidecars must be declared on the `gluetun` service itself (not on the sidecar) and listed in `FIREWALL_INPUT_PORTS`. The sidecar has no independent port mapping capability.

### socat Forwarding Chain

The client-side SOCKS5 proxy works via a five-hop forwarding chain:

```
1. Application
   SOCKS5 connect to localhost:1055

2. Podman port mapping
   Host localhost:1055 to container port 1081
   (-p 127.0.0.1:1055:1081)

3. socat (inside tailbox container)
   TCP4-LISTEN:1081,fork,reuseaddr
   EXEC:tailscale nc <exit-node-hostname> 1080

4. tailscale nc
   Opens a TCP-over-Tailscale stream to the named peer.
   Works in both kernel mode (tailscale0 tun device) and
   userspace mode (TS_USERSPACE=true), because tailscale nc
   uses the Tailscale daemon's own TCP proxy, not raw tun.
   Traversal via DERP relay or direct WireGuard UDP.

5. Server: microsocks
   Receives the proxied stream on :1080 inside mullvad-gateway's
   namespace. Forwards to the destination via tun0 (Mullvad).
```

**Why socat instead of a Tailscale exit node?**

A Tailscale exit node requires the server to NAT all forwarded traffic: `FORWARD` chain rules, `MASQUERADE` (or `SNAT`), and correct `rp_filter` settings. Inside gluetun's network namespace, gluetun's own nftables kill switch already owns the forwarding policy — it has a default DROP on `FORWARD`, and injecting `MASQUERADE` rules into that namespace is fragile and brittle across gluetun restarts. Gluetun rebuilds its nftables rules from scratch on every start, wiping any injected rules.

socat sidesteps all of this: it terminates the TCP connection locally inside the namespace and opens a new outbound connection to microsocks on the same loopback. No `FORWARD` chain involvement, no NAT, no `rp_filter` interaction.

### Routing Fix (`mullvad-exitnode-init.sh`)

When Tailscale runs inside gluetun's network namespace, a policy routing conflict prevents the SOCKS5 proxy from working even though `tailscale ping` succeeds.

**The conflict:**

Gluetun installs a high-priority policy routing rule:

```
101: not from all fwmark 0xca6c lookup main
     -> default dev tun0 (table 51820)
```

This rule catches all traffic not marked by gluetun's own fwmark and redirects it to tun0 (Mullvad). Its priority (101) is higher than Tailscale's own rule:

```
5270: fwmark 0x80000/0xff0000 lookup 52  (Tailscale's table)
```

When microsocks receives a connection from a Tailscale client (source IP in `100.64.0.0/10` CGNAT space) and tries to send return traffic, the packet matches gluetun's rule 101 before it reaches Tailscale's rule 5270. The packet is routed to tun0 and sent to Mullvad instead of back through tailscale0. The TCP session never completes.

`tailscale ping` still works because it uses ICMP via the DERP relay, which does not require correct return routing through the namespace.

**The fix (applied by `mullvad-exitnode-init.sh` via `nsenter`):**

```bash
# Rule at priority 100 — evaluated BEFORE gluetun's rule 101
ip rule add to 100.64.0.0/10 lookup 52 priority 100

# Also fix WireGuard's own routing table (table 51820)
# so that traffic destined for CGNAT space exits via tailscale0
ip route add 100.64.0.0/10 dev tailscale0 table 51820
```

Both rules are idempotent: the script checks with `ip rule show` and `ip route show table 51820` before adding. They must be applied:

1. **At boot** — gluetun-watcher runs `mullvad-exitnode-init.sh` in `main()` before entering the event loop, covering the case where the system boots without triggering a gluetun restart event.
2. **After every gluetun restart** — gluetun's namespace is recreated, wiping all injected rules. gluetun-watcher detects the `start` event and re-applies the fix after a 15-second delay to allow tailscale0 to come up.

### Watcher (`gluetun-watcher.sh`)

The watcher runs as a systemd service and listens for `start` events on `mullvad-gateway` via `docker events`. When the VPN container restarts (e.g. after a WireGuard reconnect or host reboot):

1. Waits 10 seconds for Gluetun to stabilise.
2. Runs `docker compose up -d --force-recreate` for each dependent stack (Tailscale + microsocks share one compose file; dnsmasq has its own).
3. Waits 15 seconds for `tailscale0` to come up, then runs `mullvad-exitnode-init.sh`.

The watcher also runs the routing fix **at startup** (before the event loop), covering the case where the system boots without triggering a Gluetun restart event.

A lock directory (`/tmp/gluetun-watcher-restart.lock`) prevents duplicate handling of rapid successive events.

### Auto-Healing

`willfarrell/autoheal` polls the Docker API for containers with `autoheal=true` labels and restarts any that fail their healthcheck. It talks to Docker exclusively through `tecnativa/docker-socket-proxy`, which is restricted to `CONTAINERS`, `EVENTS`, and `POST` endpoints only — no image pull, no exec, no volume access.

Both autoheal and socket-proxy are on an isolated `socket-proxy-net` bridge with `internal: true`, meaning they have no direct external network access.

Containers monitored by autoheal:

- `mullvad-gateway` (gluetun) — healthcheck via internal HTTP on port 9999
- `tailscale-endpoint` — healthcheck via `tailscale status --json`
- `tailbox-socks` (microsocks) — healthcheck via `nc -z 127.0.0.1 1080`
- `tailbox-dns` (dnsmasq) — healthcheck via `nslookup example.com 127.0.0.1 -port=5353`

### Kill Switch (Server)

Gluetun manages its own iptables/nftables kill switch in the shared network namespace. The default policy is:

- `INPUT` / `OUTPUT` / `FORWARD` — DROP
- Exceptions: tun0 traffic, lo, ESTABLISHED/RELATED, and explicitly listed `FIREWALL_INPUT_PORTS`

If the WireGuard tunnel drops, no traffic can leave through eth0. DNS and other outbound traffic is also blocked until the tunnel is restored.

LAN access is an explicit exception via `FIREWALL_OUTBOUND_SUBNETS` (e.g. `192.168.1.0/24`), which gluetun adds as a bypass route via eth0.

## Troubleshooting

### TCP via SOCKS5 times out but `tailscale ping` works

**Symptom:** `curl --socks5-hostname localhost:1055 https://ifconfig.me` hangs or times out. `tailscale ping tailbox-endpoint` succeeds (reporting a DERP relay hop). microsocks is running, gluetun has a VPN connection, Tailscale reports connected.

**Cause:** The routing fix is not applied. Gluetun's policy routing rule at priority 101 captures return traffic destined for Tailscale's CGNAT range (`100.64.0.0/10`) and sends it through Mullvad's `tun0` instead of back through `tailscale0`. TCP sessions never complete; ICMP (used by `tailscale ping`) still works via the DERP relay.

**Fix:**

Apply the routing rules manually:

```bash
sudo /usr/local/bin/mullvad-exitnode-init.sh
```

Or restart gluetun-watcher, which applies the fix automatically at startup and after each gluetun restart:

```bash
sudo systemctl restart gluetun-watcher
```

To confirm the rules are in place inside the gluetun namespace:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' mullvad-gateway)
sudo nsenter -t "$PID" -n -- ip rule show | grep 100.64
sudo nsenter -t "$PID" -n -- ip route show table 51820 | grep 100.64
```

Expected output includes:
```
100: to 100.64.0.0/10 lookup 52
100.64.0.0/10 dev tailscale0
```

---

### WireGuard handshake "i/o timeout"

**Symptom:** gluetun logs show repeated handshake failures or `i/o timeout`. The VPN never connects.

**Checks and fixes:**

1. **Verify `MULLVAD_COUNTRY`** — The country code must match a Mullvad server region. Check available options at `https://mullvad.net/en/servers/`. Use the full country name as it appears in Mullvad's API (e.g. `Sweden`, not `SE`).

2. **Try userspace WireGuard** — The default in tailbox-server is `WIREGUARD_IMPLEMENTATION=userspace`. If your host kernel WireGuard module is broken or missing, add this explicitly:

   ```
   WIREGUARD_IMPLEMENTATION=userspace
   ```

   Set in `gluetun-mullvad/.env` (gluetun reads it as an environment variable).

3. **Try port 443** — Some networks block UDP 51820. Mullvad supports WireGuard over TCP-wrapped UDP on port 443:

   ```
   VPN_ENDPOINT_PORT=443
   ```

   Add this to `gluetun-mullvad/.env`. Note that not all Mullvad servers support all ports; you may also need to change `MULLVAD_COUNTRY` to a different region.

4. **Check the WireGuard private key** — The key must be set via `WIREGUARD_PRIVATE_KEY_SECRETFILE`. See [gluetun "private key is not set"](#gluetun-private-key-is-not-set) below.

---

### DNS resolution fails

**Symptom:** Connections via SOCKS5 fail with DNS errors. `nslookup` from inside the container returns SERVFAIL or times out.

**Checks:**

1. **Check `DNS_MODE`** in `gluetun-mullvad/.env`. If it is not set, it defaults to `split`.

2. **Verify dnsmasq is running (split mode only):**

   ```bash
   docker ps | grep tailbox-dns
   docker logs tailbox-dns
   ```

   If tailbox-dns is not running but `DNS_MODE=split`, the dnsmasq stack was not started. Run:

   ```bash
   cd dns && docker compose up -d
   ```

3. **Test resolution from inside the container:**

   ```bash
   # Test via dnsmasq (split mode)
   docker exec mullvad-gateway nslookup example.com 127.0.0.1 -port=5353

   # Test via Mullvad DNS directly
   docker exec mullvad-gateway nslookup example.com 10.64.0.1
   ```

4. **Check gluetun's upstream setting:**

   ```bash
   docker inspect mullvad-gateway | grep DNS_UPSTREAM
   ```

   In split mode this must be `127.0.0.1:5353`. In mullvad mode it must be `10.64.0.1`.

---

### Local domains don't resolve

**Symptom:** Public domains resolve correctly via SOCKS5, but `ha.lan.example.com` (or your equivalent) resolves to a public IP or fails to resolve at all.

**Requirements for split DNS to work:**

- `DNS_MODE=split` in `gluetun-mullvad/.env`
- `DNS_LOCAL_DOMAIN` set to your LAN domain suffix (e.g. `lan.example.com`)
- `DNS_LOCAL_SERVER` set to your LAN DNS server IP (e.g. `192.168.1.x`)
- `dns/dnsmasq.conf` generated from the template (run `dns/generate-config.sh`)
- `tailbox-dns` container running

**Verify dnsmasq is splitting correctly:**

```bash
docker exec mullvad-gateway nslookup yourhost.lan.example.com 127.0.0.1 -port=5353
```

Expected: returns your local LAN IP (e.g. `192.168.1.x`).

If it returns a public IP or NXDOMAIN, check `dnsmasq.conf`:

```bash
cat dns/dnsmasq.conf
```

The file should contain a line like:

```
server=/lan.example.com/192.168.1.x
```

If `dnsmasq.conf` is missing or has placeholder values, regenerate it:

```bash
cd dns && ./generate-config.sh
docker compose restart  # restart tailbox-dns to pick up the new config
```

Also confirm the LAN DNS server is reachable from inside the gluetun namespace:

```bash
docker exec mullvad-gateway nslookup yourhost.lan.example.com 192.168.1.x
```

If this fails, `192.168.1.x` is not in `FIREWALL_OUTBOUND_SUBNETS`. Check your `.env`.

---

### Sidecar can't reach published ports

**Symptom:** A sidecar container (e.g. a custom service added to gluetun's namespace) cannot be reached on its published port from outside the VPN namespace.

**Cause:** Gluetun's kill switch blocks all inbound traffic except ports explicitly listed in `FIREWALL_INPUT_PORTS`.

**Fix:** Add the port to `FIREWALL_INPUT_PORTS` in `gluetun-mullvad/.env`:

```
FIREWALL_INPUT_PORTS=1080,<your-port>
```

Then recreate the gluetun container:

```bash
cd gluetun-mullvad && docker compose up -d --force-recreate
```

Note: gluetun-watcher will detect the restart and recreate dependent containers automatically.

---

### Autoheal not restarting unhealthy containers

**Symptom:** A container with `autoheal=true` fails its healthcheck but is not restarted by autoheal.

**Checks:**

1. **Check autoheal logs:**

   ```bash
   docker logs mullvad-autoheal
   ```

   Look for connection errors to `docker-socket-proxy:2375`.

2. **Check socket-proxy logs:**

   ```bash
   docker logs docker-socket-proxy
   ```

   Look for permission errors on specific Docker API endpoints.

3. **Verify both containers are on `socket-proxy-net`:**

   ```bash
   docker network inspect socket-proxy-net
   ```

   Both `mullvad-autoheal` and `docker-socket-proxy` must be listed as connected containers. If either is missing, recreate the affected stack.

4. **Verify socket-proxy permissions** — autoheal needs `CONTAINERS=1`, `EVENTS=1`, and `POST=1` on the socket-proxy. Check the `docker-socket-proxy` service environment in `gluetun-mullvad/docker-compose.yaml`.

---

### Tailscale auth key rotation

**Symptom:** Tailscale refuses to connect after an auth key expires, or you want to move the endpoint to a different tailnet.

**Procedure:**

1. Stop all containers:

   ```bash
   cd tailscale-endpoint && docker compose down
   ```

2. Wipe Tailscale state:

   ```bash
   sudo rm -rf tailscale-endpoint/tailscale-state/*
   ```

3. Update the auth key secret:

   ```bash
   # Generate a new reusable key at https://login.tailscale.com/admin/settings/keys
   echo "tskey-auth-..." > tailscale-endpoint/secrets/ts_authkey.txt
   chmod 600 tailscale-endpoint/secrets/ts_authkey.txt
   ```

4. Start the stack:

   ```bash
   cd tailscale-endpoint && docker compose up -d
   ```

Tailscale will register as a new node. If you have ACL rules or exit node approvals tied to the old node name, re-approve the new node in the Tailscale admin console.

---

### gluetun "private key is not set"

**Symptom:** gluetun logs: `wireguard: private key is not set`.

**Cause:** gluetun uses a non-standard naming convention for Docker secrets. The environment variable must end with `_SECRETFILE`, not `_FILE`.

**Correct configuration:**

```yaml
environment:
  - WIREGUARD_PRIVATE_KEY_SECRETFILE=/run/secrets/mullvad_wg_key
secrets:
  - mullvad_wg_key
```

The corresponding secrets block:

```yaml
secrets:
  mullvad_wg_key:
    file: ./secrets/mullvad_wg_key.txt
```

`mullvad_wg_key.txt` must contain only the WireGuard private key (the `PrivateKey` field from a Mullvad WireGuard configuration file), with no trailing whitespace or newlines beyond a single terminating newline.

To verify the file is correct:

```bash
wc -c gluetun-mullvad/secrets/mullvad_wg_key.txt
# A 44-character base64 key + newline = 45 bytes
```

---

### Can't reach microsocks on port 1080

**Symptom:** Connections to port 1080 are refused or time out.

**Fix:** Confirm `1080` is in `FIREWALL_INPUT_PORTS` in `.env` and that Gluetun has picked it up:

```bash
docker exec mullvad-gateway iptables -L INPUT -n
```

## Client

The client side of Tailbox is a separate repository: [tailbox-client](https://github.com/tdwgm/tailbox-client).

## License

MIT — see [LICENSE](LICENSE).
