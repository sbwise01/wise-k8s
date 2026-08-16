# Gateway API rollout (kgateway + MetalLB L2)

Replace **ingress-nginx** (public + internal) with **Kubernetes Gateway API** using **[kgateway](https://kgateway.dev/)** as the control plane, keeping **MetalLB layer-2** as the on-LAN VIP advertisement for both public and internal edge traffic.

**Status:** Phase 8 complete (2026-08-16) — frozen listeners `http` + `https-wildcard`; platform cert `gateway-home-tls`. Public HTTPS is **one** listener (no hostname) so Chrome HTTP/2 coalescing cannot pin SNI to apex. Decisions below are **locked**; revise only via PR.

**README:** [To Do #1](../README.md) complete 2026-08-16.

---

## Architecture target

```text
Internet (WAN)
    │
    │  Port-forward / hairpin on home router
    │  (WAN TCP 443 → 192.168.40.217 gateway-public VIP)
    ▼
LAN 192.168.40.0/24
    │
    ├── MetalLB L2Advertisement (home-pool)
    │     VIP on public Gateway LoadBalancer Service
    │         └── kgateway proxy  ──►  HTTPRoute (public apps)
    │
    └── MetalLB L2Advertisement (home-pool-internal)
          VIP on internal Gateway LoadBalancer Service
              └── kgateway proxy  ──►  HTTPRoute (admin / LAN-only apps)

DNS (unchanged model)
  • Apex home.bradandmarsha.com     → WAN IP (route53-ddns)
  • Most public hostnames           → CNAME → apex (external-dns target)
  • Internal hostnames              → A → internal Gateway VIP (external-dns)
```

**What changes**

| Today | Target |
|-------|--------|
| `Ingress` + `ingressClassName: nginx` / `nginx-internal` | `HTTPRoute` + `parentRefs` → public / internal `Gateway` |
| Two ingress-nginx controller Deployments + LB Services | Two kgateway-managed Gateways (each owns a MetalLB LB Service) |
| nginx annotations (affinity, buffers, backend HTTPS) | Gateway API / kgateway policy resources (see [Feature parity](#feature-parity-nginx--gateway)) |

**What stays**

| Piece | Role |
|-------|------|
| MetalLB pools `home-pool` / `home-pool-internal` | L2 VIP allocation |
| cert-manager + `letsencrypt-prod` (**DNS-01**) | TLS secrets; no HTTP-01 / Gateway solver required |
| external-dns + Route53 | Hostname records (sources must gain Gateway awareness) |
| route53-ddns | Apex A record to WAN IP |

---

## Locked decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Control plane | **kgateway** (`GatewayClass` name expected: `kgateway`) |
| 2 | Install model | GitOps in `wise-k8s` — **vendored YAML only** (Gateway API CRDs + `helm template` output of kgateway charts); Flux `Kustomization`, namespace `kgateway-system`. No live `HelmRelease`. |
| 2a | Pinned versions | Gateway API **v1.6.1** (standard channel); kgateway / kgateway-crds charts **2.4.2** (rendered into `iac/kustomize/kgateway/base/2.4.2/source/`) |
| 3 | Edge topology | **Two Gateways** in `kgateway-system`: `gateway-public` (pool `home-pool`) and `gateway-internal` (pool `home-pool-internal`), each with a matching `GatewayParameters` (`externalTrafficPolicy: Local` + MetalLB pool annotation) |
| 4 | MetalLB integration | Gateways create `Service` type `LoadBalancer`; annotate with `metallb.io/address-pool`; prefer `externalTrafficPolicy: Local` (match ingress-nginx) |
| 5 | Dual-run strategy | **Expand → migrate → contract** — kgateway alongside ingress-nginx until all routes cut over (**complete Phase 6**) |
| 6 | Canary app | **flask-hello-world** (simple public Ingress, no nginx-specific annotations) |
| 7 | TLS | **Phase 8 complete:** platform `gateway-home-tls` (`*.home.bradandmarsha.com` + apex SAN). Frozen listener `https-wildcard` (public catch-all + internal `*.home…`). New apps add an `HTTPRoute` only. |
| 8 | DNS cutover | Enable external-dns **`gateway-httproute`** (and RBAC) before deleting Ingresses; keep public CNAME→apex pattern where used today |
| 9 | Public VIP cutover | **Option B (locked 2026-08-16):** leave `gateway-public` on VIP **`192.168.40.217`**. Home-router WAN DNAT is TCP **443 only** (no port 80) → `.217`. Internal apps use `gateway-internal` **`.236`**. |
| 10 | Out of scope (v1) | HTTP-01 challenges, IPv6 dual-stack, replacing MetalLB, EnvoyFilter/advanced mesh, merging public+internal into one Gateway |

---

## MetalLB L2 — constraints for this rollout

Homelab public ingress is **not** cloud LB. Path is:

1. Client hits WAN IP (or LAN VIP).
2. Router / hairpin forwards **80/443** to a MetalLB VIP on `192.168.40.0/24`.
3. MetalLB **speaker** answers ARP for that VIP (**L2Advertisement**).
4. Packets land on a node hosting the Gateway proxy pod; `externalTrafficPolicy: Local` keeps source IP when possible.

**Implications**

- kgateway must expose Gateways as **LoadBalancer** Services (not NodePort-only) so MetalLB assigns VIPs.
- Pool selection must be explicit (`metallb.io/address-pool: home-pool` vs `home-pool-internal`).
- **Do not** run two Services claiming the same VIP. Dual-run used nginx `.216` + Gateway `.217`; nginx is removed in Phase 6.
- L2 means speakers must run on nodes that can ARP on that L2 segment.
- Router WAN 443 DNAT already targets `192.168.40.217` (Phase 5 option B). Remaining `.216` docs (KEYCLOAK.md) are Phase 7.

**Pools (current)**

| Pool | CIDR range | Used by today | Target Gateway |
|------|------------|---------------|----------------|
| `home-pool` | `192.168.40.216–234` | `gateway-public` (`.217`; `.216` reclaimed after nginx removal) | `gateway-public` |
| `home-pool-internal` | `192.168.40.235–253` | `gateway-internal` (`.236`; `.235` reclaimed after nginx removal) | `gateway-internal` |

---

## Inventory — Ingress → HTTPRoute migration order

Migrate **one hostname at a time**. Suggested order (risk ascending):

### Wave A — canary (public)

| Host | App | Notes |
|------|-----|-------|
| `flask-hello-world.home.bradandmarsha.com` | flask-hello-world | No nginx annotations; ideal first cutover |

### Wave B — low-risk public

| Host | App | Notes |
|------|-----|-------|
| `media.home.bradandmarsha.com` | media | Simple |
| `oidc.home.bradandmarsha.com` | aws-iam-oidc-provider | IRSA OIDC discovery — verify after TLS |
| `plex.home.bradandmarsha.com` | plex | Large uploads; watch timeouts |

### Wave C — identity / money path (public + internal)

| Host | Class today | Notes |
|------|-------------|-------|
| `auth.home.bradandmarsha.com` | public | Keycloak — needs larger buffers ([parity](#feature-parity-nginx--gateway)) |
| `acruet.home.bradandmarsha.com` | public | Cookie session affinity |
| `acruet-admin.home.bradandmarsha.com` | **internal** | Affinity + LAN-only VIP |
| `home.bradandmarsha.com` | public | Apex site (wise-home-index); DNS via route53-ddns, not external-dns |

### Wave D — operators (internal)

| Host | Notes |
|------|-------|
| `flux-web.home.bradandmarsha.com` | NetworkPolicy allows `kgateway-system` / `gateway-internal` (nginx peers removed in Phase 6) |
| `ceph-dashboard.home.bradandmarsha.com` | Backend **HTTPS** + SSL verify off |
| `grafana-dashboard.home.bradandmarsha.com` | Helm Ingress patch today |

---

## Feature parity (nginx → Gateway)

Resolve **before** migrating the owning app (spike in Phase 2 / early Wave C–D):

| nginx annotation / behavior | Apps | Gateway / kgateway approach (investigate & lock) |
|-----------------------------|------|--------------------------------------------------|
| `affinity: cookie` + session-cookie-* | acruet user/admin | **Locked:** kgateway `BackendConfigPolicy` Maglev cookie hash (`acruet-user-route` / `acruet-admin-route`) |
| `proxy-buffer-size: 128k` | Keycloak | **Locked:** `ListenerPolicy` `maxRequestHeadersKb: 128` on `gateway-public` |
| `backend-protocol: HTTPS` + `proxy-ssl-verify: off` | Ceph dashboard | **Locked:** `BackendConfigPolicy` skip-verify + `simpleTLS` + SNI (`rook-ceph-mgr-dashboard.rook-ceph.svc`); no ALPN |
| Default body/timeout sizes | plex, others | Confirm defaults; raise if uploads fail |

If a feature has no clean Gateway equivalent, document a temporary exception and keep that Ingress until solved — **do not** block Wave A/B.

---

## Progress

| Phase | Status |
|-------|--------|
| 0 — Decisions & inventory | ✅ Locked in this doc |
| 1 — Deploy kgateway + Gateway API CRDs (no traffic) | ✅ Complete (2026-08-08) — Flux Ready; GatewayClass Accepted; no edge LB |
| 2 — MetalLB-backed public/internal Gateways + smoke test | ✅ Complete (2026-08-08) — public `.217`, internal `.236`; nginx `.216`/`.235` unchanged |
| 3 — Canary: flask-hello-world on Gateway API | ✅ Expand complete; Ingress contracted in Phase 5 |
| 4 — external-dns Gateway sources + dual-publish strategy | ✅ Complete (2026-08-16) — `gateway-httproute`; public CNAME→apex |
| 5 — Convert remaining Ingresses (Waves B–D) | ✅ Contract 2026-08-16 — WAN `.217`; internal DNS → `.236`; Ingresses removed |
| 6 — Contract: remove Ingresses, ingress-nginx, dead deps | ✅ Complete (2026-08-16) — `#26`; nginx pruned; `.216`/`.235` free |
| 7 — Docs / README / KEYCLOAK.md VIP references | ✅ Complete (2026-08-16) |
| 8 — Wildcard TLS + freeze Gateway listeners (SoD) | ✅ Complete (2026-08-16) — `#27`–`#29`; public HTTPS collapsed to one `https-wildcard` listener (Chrome H2 coalescing) |

---

## Phase 1 — Deploy kgateway (no user traffic)

**Goal:** Control plane Ready; no change to existing Ingress behavior.

### Deliverables

1. ✅ `iac/kustomize/kgateway/` + `fluxcd/kustomizations/kgateway.yaml` (`dependsOn: metal-lb`).
2. ✅ Install order (declarative / vendored — no HelmRelease):
   - Kubernetes **Gateway API** standard CRDs **v1.6.1** (`base/gateway-api/`).
   - **kgateway-crds** + **kgateway** chart **2.4.2** rendered with `helm template` into `base/2.4.2/source/`.
   - Re-vendor steps documented in `base/2.4.2/kustomization.yaml`.
3. ✅ `GatewayClass` `kgateway` Accepted (`controller: kgateway.dev/kgateway`); controller pod Ready.
4. ✅ Flux `dependsOn: metal-lb`.

### Verify

```bash
kubectl get gatewayclass
kubectl -n kgateway-system get pods
kubectl get crd | grep -E 'gateway\.networking\.k8s\.io|kgateway'
```

**Verified 2026-08-08:** Flux `kgateway` Ready/Healthy; pod `1/1`; GatewayClass Accepted; kgateway Service is ClusterIP only; ingress-nginx public/internal LBs still on `.216` / `.235`.

### Exit criteria

- ✅ No new LoadBalancer Services from kgateway.
- ✅ ingress-nginx still serves all production hostnames.

---

## Non-impact checks (Ingress stays on nginx)

kgateway implements **Gateway API**, not the Ingress API. The control-plane install (Phase 1) does not create an `IngressClass`, does not register Ingress admission webhooks, and does not claim MetalLB VIPs. Existing traffic stays on ingress-nginx until an app is explicitly moved to an `HTTPRoute` (Phase 3+).

### Baseline after Phase 1 (already true on 2026-08-08)

| Check | Expect |
|-------|--------|
| `kubectl get ingressclass` | Only `nginx` / `nginx-internal` (no kgateway IngressClass) |
| Admission webhooks | No kgateway / Gateway mutating or validating webhooks on `Ingress` |
| `kubectl get ingress -A` | All hosts still `class=nginx` or `nginx-internal`; no kgateway labels/annotations |
| LoadBalancer Services | Only ingress-nginx controllers; kgateway Service is **ClusterIP** |
| MetalLB VIPs | Public nginx **`192.168.40.216`**, internal **`192.168.40.235`** (unchanged) |

Spot-check a few live hosts (LAN or WAN as you normally use them):

```bash
# Should hit nginx VIPs / existing DNS — not kgateway
curl -fsS -o /dev/null -w '%{http_code} %{url_effective}\n' https://flask-hello-world.home.bradandmarsha.com/
curl -fsS -o /dev/null -w '%{http_code}\n' https://auth.home.bradandmarsha.com/
curl -fsS -o /dev/null -w '%{http_code}\n' https://home.bradandmarsha.com/
```

### Before / right after Phase 2 Gateways (critical)

Phase 2 **does** create new MetalLB LoadBalancer Services. That can impact Ingress **only if** a Gateway steals an IP already used by nginx (ARP conflict).

| Check | Expect |
|-------|--------|
| New public Gateway EXTERNAL-IP | In `home-pool` **and ≠ `192.168.40.216`** while nginx public still exists |
| New internal Gateway EXTERNAL-IP | In `home-pool-internal` **and ≠ `192.168.40.235`** while nginx internal still exists |
| `kubectl get ingress -A` ADDRESS / classes | Unchanged vs baseline |
| curl existing hostnames (DNS, not Gateway VIP) | Same status as baseline |
| curl new Gateway VIP with a production `Host` header | May 404 / no route — **must not** replace nginx responses for that hostname until HTTPRoute cutover |

```bash
# After Phase 2 Gateways exist:
kubectl get svc -A -o wide | grep LoadBalancer
# Confirm two nginx LBs + two new gateway LBs, four distinct IPs

# Ingress path still nginx (use real DNS):
curl -fsS -o /dev/null -w '%{http_code}\n' https://flask-hello-world.home.bradandmarsha.com/

# Gateway VIP is a separate listener (no HTTPRoute yet → not your app):
PUB=$(kubectl get gateway gateway-public -n kgateway-system -o jsonpath='{.status.addresses[0].value}')
curl -vk --resolve flask-hello-world.home.bradandmarsha.com:443:$PUB \
  https://flask-hello-world.home.bradandmarsha.com/ 2>&1 | head -40
```

If DNS curls regress or nginx VIPs change unexpectedly → delete the Gateways (or their Services) first; leave ingress-nginx alone.

---

## Phase 2 — Gateways on MetalLB L2

**Goal:** Public and internal Gateways programmed with MetalLB VIPs; prove L2 path without migrating apps.

### Deliverables

1. ✅ Namespace locked: Gateways live in **`kgateway-system`** (same as control plane).
2. ✅ `GatewayParameters` + `Gateway` `gateway-public`:
   - `gatewayClassName: kgateway`
   - Listeners: HTTP `:80` + HTTPS `:443` (Terminate via placeholder `gateway-edge-tls`)
   - `GatewayParameters`: `type: LoadBalancer`, `externalTrafficPolicy: Local`, `metallb.io/address-pool: home-pool`
   - HTTP→HTTPS redirect is **per-HTTPRoute** (`RequestRedirect`); added with app routes in Phase 3+, not as a Gateway-level filter
3. ✅ `Gateway` `gateway-internal` with pool `home-pool-internal` (same listener/TLS pattern).
4. ✅ Placeholder `Issuer`/`Certificate` `gateway-edge-tls` (self-signed) for HTTPS smoke; real LE secrets in Phase 3+.
5. ✅ Document assigned VIPs below.
6. Optional later: pin IPs via Gateway `spec.addresses` or MetalLB annotations **only** after confirming kgateway propagates them to the proxy Service.

**Assigned VIPs (dual-run, 2026-08-08)**

| Gateway | Pool | EXTERNAL-IP |
|---------|------|-------------|
| `gateway-public` | `home-pool` | `192.168.40.217` |
| `gateway-internal` | `home-pool-internal` | `192.168.40.236` |

ingress-nginx still holds `192.168.40.216` (public) and `192.168.40.235` (internal).

### Verify

```bash
kubectl get gateway -A
kubectl get svc -n kgateway-system   # LoadBalancer EXTERNAL-IPs from correct pools
# From a LAN host: ARP / curl -k https://<public-vip>/  (expect no route / 404, not timeout)
```

**Verified 2026-08-08:** Both Gateways Programmed/Accepted; proxy pods Running; LBs use correct pools + `externalTrafficPolicy: Local`; VIP HTTPS/HTTP return 404 (no routes yet); DNS curls still hit nginx (200/302/200).

### Exit criteria

- ✅ Public VIP ∈ `192.168.40.216–234` and **≠** nginx `.216` while dual-running (`.217`).
- ✅ Internal VIP ∈ `192.168.40.235–253` and **≠** nginx-internal `.235` (`.236`).
- ✅ L2Advertisement still only those two pools (no BGP).
- ✅ Existing DNS hostnames still served by ingress-nginx (non-impact checks).

---

## Phase 3 — Canary: flask-hello-world

**Goal:** Prove end-to-end Gateway path for one non-critical public app.

### Expand

1. ✅ `HTTPRoute` `flask-hello-world` → Service `flask-hello-world:5000` (`parentRefs` → `gateway-public` / `https-flask-hello-world`).
2. ✅ `HTTPRoute` `flask-hello-world-https-redirect` on listener `http` (`RequestRedirect` → https).
3. ✅ Hostname-scoped HTTPS listener on `gateway-public` + `ReferenceGrant` in `default` for Secret `certificate-flask-hello-world`.
4. ✅ Keep existing `Ingress` during dual-run (DNS / external-dns still owned by Ingress until Phase 4).
5. ✅ Flux `flask-hello-world` `dependsOn: kgateway`.

### Canary recipe (copy for later apps)

| Piece | Where |
|-------|--------|
| `GatewayParameters` + MetalLB pool / `externalTrafficPolicy: Local` | Already on `gateway-public` / `gateway-internal` (Phase 2) |
| Hostname HTTPS listener + `certificateRefs` (cross-ns Secret) | Per-host listener + app-ns `ReferenceGrant` (**interim**; Phase 8 replaced this with frozen `https-wildcard`) |
| App `HTTPRoute` (HTTPS) + optional HTTP→HTTPS redirect `HTTPRoute` | App kustomize |
| Leave `Ingress` until `--resolve` (and later DNS) verified | Dual-run |

**After Phase 8:** copy flask HTTPRoutes with `sectionName: https-wildcard`. Do not add Gateway listeners, app Certificates, or ReferenceGrants.

### Test plan (expand — before Ingress removal)

- [ ] `kubectl get httproute -n default` Accepted / ResolvedRefs
- [ ] `curl -vk --resolve flask-hello-world.home.bradandmarsha.com:443:192.168.40.217 https://flask-hello-world.home.bradandmarsha.com/`
- [ ] TLS cert is Let’s Encrypt (not the placeholder self-signed edge cert)
- [ ] Body / health matches nginx DNS path
- [x] DNS path still hits nginx (unchanged) — WAN DNAT → `.216` until Phase 5 VIP cutover
- [x] Expand verified 2026-08-08 (`--resolve` → LE + 200; DNS/nginx body match)

### Contract (canary only — **not** during Phase 4 alone)

- Do **not** delete public Ingresses until Phase 5 router/VIP cutover: DNS CNAME→apex still lands on nginx `.216`. Removing Ingress earlier breaks the public path even if external-dns keeps the CNAME.
- When contracting: move index annotations fully to `HTTPRoute`; leave Certificate CR.
- Short soak after public traffic actually hits Gateway (post–Phase 5); ≥1 day optional for flask.

### Exit criteria

- Expand: ✅ Gateway VIP `--resolve` serves canary with correct LE cert; nginx DNS path still healthy.
- Contract / “Gateway-only” for public canary waits on Phase 4 DNS ownership **and** Phase 5 DNAT/VIP cutover.
- Recipe table above stays the template for Wave B+.

---

## Phase 4 — external-dns Gateway awareness

**Goal:** DNS can follow HTTPRoutes without relying on Ingress objects (ownership + publish path). This does **not** by itself move WAN traffic onto kgateway — see [public path note](#public-wan-path-vs-dns-ownership).

**Local prep:** branch `feat/gateway-api-phase-4-external-dns` (uncommitted until Phase 3 soak completes).

### Public WAN path vs DNS ownership

| Layer | Today | After Phase 4 only | After Phase 5 VIP/DNAT cutover |
|-------|--------|--------------------|--------------------------------|
| Route53 public hostnames | CNAME → `home…` (apex A = WAN) | Same (if Gateway `target` = apex) | Same |
| Router :443 | → nginx `.216` | Still → `.216` | → Gateway (`.217` or reclaimed `.216`) |
| Who may own the DNS record | Ingress annotations | Ingress **and/or** HTTPRoute via `gateway-httproute` | HTTPRoute (Ingress gone) |

`--resolve` / LAN → `.217` remains the data-plane test until DNAT moves.

### Deliverables (prepared)

1. ✅ external-dns `--source=gateway-httproute` (overlay patch; keep `ingress` + `service`).
2. ✅ ClusterRole: `gateways` + `httproutes` (+ `namespaces`) get/watch/list.
3. ✅ Annotation strategy (external-dns **v0.20**):
   - **`external-dns.alpha.kubernetes.io/target` on `Gateway` only** (ignored on HTTPRoute in v0.20).
   - `gateway-public` → `target: home.bradandmarsha.com` so public HTTPRoutes publish **CNAME→apex** (not A→`.217`).
   - `gateway-internal` → **no** target annotation (A → MetalLB internal VIP from `status.addresses`).
   - Hostnames from HTTPRoute `spec.hostnames` (no duplicate hostname annotation required).
4. ✅ Dual-publish rule for canary: with matching CNAME targets, Ingress + HTTPRoute may both desire the same record under `--policy=sync`. **Do not** remove Ingress external-dns annotations until HTTPRoute path is confirmed in Route53 / external-dns logs.
5. ✅ Canary HTTPS `HTTPRoute` carries index annotations (prep for later Ingress contract).

### Verify (when merged after soak)

```bash
kubectl -n external-dns get deploy external-dns -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
# expect --source=gateway-httproute

# Route53: flask CNAME still → home.bradandmarsha.com (unchanged vs Ingress-only)
# external-dns logs: no fight / no flip to A 192.168.40.217 for public hosts
```

- [ ] Flask CNAME target unchanged after enabling gateway source
- [ ] TXT ownership (`txt-owner-id`) stable
- [ ] DNS HTTPS still hits nginx (expected until Phase 5)
- [ ] `--resolve` to `.217` still serves canary

### Exit criteria

- New hostnames **can** be published from HTTPRoute alone (no Ingress required for DNS).
- Public CNAME→apex pattern preserved via `gateway-public` target annotation.
- Explicit: Phase 4 exit ≠ public canary traffic on Gateway; that is Phase 5.
---

## Phase 5 — Convert remaining Ingresses (Waves B–D)

**Goal:** Every hostname from the [inventory](#inventory--ingress--httproute-migration-order) is Gateway-only.

**Public apps:** keep Ingress until router/VIP cutover (end of this phase). `--resolve` against `.217` is the Gateway data-plane test; DNS still hits nginx `.216`.

### Wave B expand (2026-08-16)

Same recipe as flask: hostname HTTPS listener on `gateway-public`, app-ns `ReferenceGrant`, HTTPS `HTTPRoute` + HTTP→HTTPS redirect, Flux `dependsOn: kgateway`, Ingress retained.

| Host | Listener | Service |
|------|----------|---------|
| `media.home.bradandmarsha.com` | `https-media` | `media:80` |
| `oidc.home.bradandmarsha.com` | `https-oidc` | `aws-iam-oidc:80` |
| `plex.home.bradandmarsha.com` | `https-plex` | `plex-plex-media-server:32400` |

### Wave C expand (2026-08-16)

Parity locked:

| nginx behavior | kgateway resource |
|----------------|-------------------|
| `proxy-buffer-size: 128k` (Keycloak) | `ListenerPolicy` `gateway-public-http-headers` — `maxRequestHeadersKb: 128` on `gateway-public` |
| cookie affinity (`acruet-user-route` / `acruet-admin-route`, 86400s) | `BackendConfigPolicy` Maglev cookie hash on Services `acruet-user` / `acruet-admin` |

| Host | Gateway | Listener | Service | DNS during dual-run |
|------|---------|----------|---------|---------------------|
| `auth.home.bradandmarsha.com` | public | `https-auth` | `keycloak-service:8080` | CNAME→apex (Ingress + HTTPRoute agree) |
| `acruet.home.bradandmarsha.com` | public | `https-acruet` | `acruet-user:8080` | CNAME→apex (Ingress + HTTPRoute agree) |
| `home.bradandmarsha.com` | public | `https-home` | `wise-home-index:8080` | Apex A via route53-ddns; HTTPRoute `external-dns/exclude` |
| `acruet-admin.home.bradandmarsha.com` | internal | `https-acruet-admin` | `acruet-admin:8080` | Ingress A→`.235`; HTTPRoute `external-dns/exclude` |

Ingress retained. Internal HTTPRoutes are `--resolve` against `.236` only until internal DNS contract.

### Wave D expand (2026-08-16)

| nginx behavior | kgateway resource |
|----------------|-------------------|
| flux-web NetworkPolicy (nginx-internal only) | same policy also allows `kgateway-system` pods labeled `homelab.bradandmarsha.com/gateway=gateway-internal` |
| Ceph `backend-protocol: HTTPS` + `proxy-ssl-verify: off` | `BackendConfigPolicy` `ceph-dashboard-backend-tls` — skip-verify + `simpleTLS` + SNI; **no ALPN** (ALPN+SNI 503'd; no-SNI also 503'd because dashboard is TLS 1.3) |

| Host | Listener | Service |
|------|----------|---------|
| `flux-web.home.bradandmarsha.com` | `https-flux-web` | `flux-operator:9080` |
| `ceph-dashboard.home.bradandmarsha.com` | `https-ceph-dashboard` | `rook-ceph-mgr-dashboard:8443` |
| `grafana-dashboard.home.bradandmarsha.com` | `https-grafana-dashboard` | `prometheus-stack-grafana:80` |

Internal HTTPRoutes use `external-dns/exclude` so LAN A records stay on nginx `.235` until internal contract.

### Per-app checklist (repeat)

1. **Expand:** HTTPRoute (+ TLS listener binding) + any kgateway policies for affinity / buffers / backend TLS.
2. **Verify:** `--resolve` against Gateway VIP; then DNS; OIDC / app-specific flows.
3. **Contract:** delete Ingress; drop `dependsOn` on `ingress-nginx-*` from that app’s Flux Kustomization. **Public hosts:** only after VIP/DNAT cutover.
4. Update app docs (e.g. KEYCLOAK.md) if they mention ingress class or VIP.

### Wave-specific gates

| Wave | Extra verification |
|------|-------------------|
| B | plex large media; OIDC discovery JSON on `oidc.` |
| C | Keycloak login + token size; acruet user session stickiness; acruet-admin **only** on internal VIP |
| D | flux-web NetworkPolicy allows Gateway proxy ns/labels; Ceph dashboard TLS-to-upstream; Grafana login |

### Public VIP / router cutover — option B (locked)

**Do not change the router until** Flux has applied Wave C/D expand **and** every **public** hostname returns 200 + Let’s Encrypt when forced to `gateway-public`:

```bash
VIP=192.168.40.217
for h in \
  flask-hello-world.home.bradandmarsha.com \
  media.home.bradandmarsha.com \
  oidc.home.bradandmarsha.com \
  plex.home.bradandmarsha.com \
  auth.home.bradandmarsha.com \
  acruet.home.bradandmarsha.com \
  home.bradandmarsha.com
do
  echo "=== $h ==="
  curl -skI --resolve "$h:443:$VIP" "https://$h/" | head -n 20
done
```

Optional internal `--resolve` (does **not** use WAN DNAT; skip if you only care about public cutover):

```bash
VIP=192.168.40.236
for h in \
  acruet-admin.home.bradandmarsha.com \
  flux-web.home.bradandmarsha.com \
  ceph-dashboard.home.bradandmarsha.com \
  grafana-dashboard.home.bradandmarsha.com
do
  echo "=== $h ==="
  curl -skI --resolve "$h:443:$VIP" "https://$h/" | head -n 20
done
```

#### Home router change (WAN DNAT only)

On the home router, edit the existing port-forward / DNAT rules that send **Internet TCP 80 and TCP 443** into the LAN:

| Field | From (today) | To (option B) |
|-------|----------------|---------------|
| Protocol | TCP | TCP (unchanged) |
| WAN / external ports | 80 and 443 | 80 and 443 (unchanged) |
| LAN destination | **`192.168.40.216`** (ingress-nginx public) | **`192.168.40.217`** (`gateway-public`) |
| LAN destination ports | 80 and 443 | 80 and 443 (unchanged) |

**Do not** change:

- Hairpin / NAT loopback **policy** (keep it enabled if browsers on LAN already use public hostnames)
- Any rule aimed at **`192.168.40.235`** (nginx-internal) or **`.236`** (`gateway-internal`)
- DNS (public CNAMEs still → apex; apex A still WAN via route53-ddns)

If the UI shows two rules (one for 80, one for 443), update **both** destinations to `.217`. Apply/save, then from a **WAN path** (phone LTE, or LAN with hairpin):

```bash
curl -sI https://home.bradandmarsha.com/ | head
curl -sI https://auth.home.bradandmarsha.com/ | head
curl -sI https://acruet.home.bradandmarsha.com/ | head
```

Expect HTTP 200 or 302 and a Let’s Encrypt cert. Rollback: set the 443 DNAT destination back to **`192.168.40.216`**.

**Verified 2026-08-16 (post-cutover):** DNS HTTPS to all public hosts returns `server: envoy` + Let’s Encrypt. Browser checks passed on-LAN and off-LAN. Internal hosts were still nginx `.235` until the contract PR below.

Record: option **B**, public VIP **`192.168.40.217`**. WAN cutover date: **2026-08-16**. Router: TCP **443 only** (no WAN 80 forward).

### Contract (2026-08-16)

Ingress objects removed; HTTPRoutes remain. ingress-nginx controllers removed in Phase 6.

| Change | Detail |
|--------|--------|
| Public Ingresses deleted | flask, media, oidc, plex, keycloak, acruet-user, wise-home-index |
| Internal Ingresses deleted | acruet-admin, flux-web, ceph-dashboard, grafana (`$patch: delete` on helm Ingress) |
| Internal DNS | Drop `external-dns/exclude` on internal HTTPRoutes so they publish **A → `192.168.40.236`** |
| Apex DNS | `home.bradandmarsha.com` still route53-ddns; HTTPRoute stays excluded |
| Flux | `acruet` no longer `dependsOn` `ingress-nginx-*` |

### Exit criteria

- ✅ Public WAN 443 lands on `gateway-public` `.217` (option B).
- ✅ No app Ingress objects (grafana helm Ingress deleted via patch).
- ✅ App Flux Kustomizations depend on `kgateway`, not `ingress-nginx-*`.
- ✅ ingress-nginx controllers removed — **Phase 6**.

---

## Phase 6 — Cleanup: remove ingress-nginx

**Goal:** No ingress-nginx controllers, classes, or Flux kustomizations.

### Contract (2026-08-16)

1. ✅ No Ingress objects (Phase 5).
2. ✅ Removed Flux Kustomizations `ingress-nginx-public` / `ingress-nginx-internal` and their entries in `fluxcd/kustomizations/kustomization.yaml`.
3. ✅ Deleted `iac/kustomize/ingress-nginx/` (history retains it).
4. ✅ flux-web NetworkPolicy allows only `kgateway-system` pods labeled `homelab.bradandmarsha.com/gateway=gateway-internal`.
5. MetalLB `.216` / `.235` free after Flux prune of the nginx LoadBalancer Services (`prune: true` on the removed KS). Pools left wide (no CIDR shrink).
6. Skipped pinning `gateway-public` to `.216` (option B already locked).

Grafana helm Ingress stays `$patch: delete`. external-dns may keep `--source=ingress` (harmless with no Ingress objects).

### Verify (after merge)

FluxInstance sync of `./iac/kustomize/fluxcd` prunes the `ingress-nginx-*` Kustomization CRs; those KS then prune controllers, IngressClasses, and LB Services.

```bash
kubectl -n flux-system get kustomization | grep ingress-nginx   # expect gone
kubectl get ns | grep ingress-nginx                             # expect gone
kubectl get ingressclass                                        # nginx classes gone
kubectl get svc -A | grep LoadBalancer
# only MetalLB consumers: gateway-public, gateway-internal (+ any intentional others)
```

Spot-check public + internal HTTPS still `server: envoy`.

**Verified 2026-08-16** after merge of `#26` (`ff0c89b`):

| Check | Result |
|-------|--------|
| Flux `ingress-nginx-*` KS | Gone |
| Namespaces `ingress-nginx` / `ingress-nginx-internal` | Gone (briefly Terminating, then deleted) |
| IngressClass / Ingress / nginx webhooks / ClusterRoles | None |
| LoadBalancer Services | Only `gateway-public` `.217` and `gateway-internal` `.236` |
| Flux KS | All Ready on `ff0c89b` |
| Public HTTPS (WAN path) | All `server: envoy` — flask/media/home/acruet 200; auth 302; plex 401; oidc `/` 403, `/.well-known/openid-configuration` 200 |
| Internal HTTPS A→`.236` | acruet-admin 302 OIDC; flux-web 200; ceph 200; grafana 302 `/login` |

### Exit criteria

- [x] Cluster edge is **only** kgateway + MetalLB L2 (after Flux prune).
- [x] README To Do #1 marked complete with date.

---

## Phase 7 — Documentation

- [x] This rollout Progress table → phases 0–8 ✅
- [x] `README.md` To Do #1 struck / completed (Gateway edge live; wildcard TLS frozen)
- [x] KEYCLOAK.md / app READMEs: Ingress class → Gateway; VIP if changed
- [x] Platform notes: new apps use HTTPRoute + parentRefs, not Ingress ([Onboarding](#onboarding-a-new-hostname))
- [x] Note kgateway / Gateway API versions pinned in GitOps (locked decision 2a; `iac/kustomize/kgateway/base/`)
- [x] New hostnames attach to frozen listeners (no Gateway edit) — Phase 8 contract

---

## Onboarding a new hostname

**Do not create `Ingress` objects.** Do **not** edit `gateway-public` / `gateway-internal`. The cluster edge is kgateway + MetalLB L2 with frozen HTTPS listeners.

| Piece | Pin |
|-------|-----|
| Gateway API CRDs | **v1.6.1** standard channel (`iac/kustomize/kgateway/base/gateway-api/`) |
| kgateway | **2.4.2** vendored YAML (`iac/kustomize/kgateway/base/2.4.2/`; re-vendor notes in that `kustomization.yaml`) |
| Public Gateway | `gateway-public` in `kgateway-system` — VIP **`192.168.40.217`**; WAN TCP **443** DNAT |
| Internal Gateway | `gateway-internal` in `kgateway-system` — VIP **`192.168.40.236`** (LAN A records) |
| Platform TLS | Secret `gateway-home-tls` in `kgateway-system` (`*.home.bradandmarsha.com` + `home.bradandmarsha.com`) |

Copy **`iac/kustomize/flask-hello-world/`** HTTPRoutes (simplest public app) or **`acruet/`** (public + internal + Maglev cookie). Skip app `Certificate` / `ReferenceGrant` / Gateway listener edits.

1. **HTTPS `HTTPRoute`:** `parentRefs` → `gateway-public` or `gateway-internal`, `sectionName: https-wildcard`, `hostnames:` (including apex `home.bradandmarsha.com`), `backendRefs` to the Service.
2. **Redirect `HTTPRoute`:** same hostname, `sectionName: http`, `RequestRedirect` to HTTPS 301.
3. **Flux:** app `Kustomization` `dependsOn: kgateway`.
4. **DNS:** public hostnames inherit CNAME→`home.bradandmarsha.com` from `gateway-public`’s `external-dns.alpha.kubernetes.io/target`. Internal hostnames publish **A → `.236`**. Apex stays on route53-ddns; that HTTPRoute keeps `external-dns/exclude`.
5. **Index tile:** `index.home.bradandmarsha.com/*` annotations on the HTTPS `HTTPRoute`.
6. **Policies if needed:** cookie affinity → `BackendConfigPolicy` Maglev (acruet); backend HTTPS → `BackendConfigPolicy` skip-verify + SNI, **no ALPN** (Ceph); large OIDC headers already covered by `ListenerPolicy` `maxRequestHeadersKb: 128` on `gateway-public`.

---

## Phase 8 — Wildcard TLS + freeze Gateway listeners

**Goal:** Converge HTTPS on platform-owned certs/listeners so app onboarding matches Gateway API separation of duties: **infra owns `Gateway`**, **apps own `HTTPRoute`** (and Services). Adding `foo.home.bradandmarsha.com` must not require editing `gateway-public` / `gateway-internal`.

**When:** After Phase 6 (ingress-nginx gone) and traffic is stable on kgateway.

### Why

| Today (interim) | Target |
|-----------------|--------|
| One HTTPS `listener` + `certificateRefs` per hostname | Stable listeners: HTTP `:80`, one HTTPS catch-all (`https-wildcard`) |
| New service → Gateway YAML change in `kgateway` overlay | New service → app `HTTPRoute` (+ DNS annotations) only |
| Per-app LE Secrets + `ReferenceGrant`s | Platform cert Secret `gateway-home-tls` in `kgateway-system` |

### Expand (2026-08-16)

1. ✅ **Certificate** `gateway-home-tls` (Let’s Encrypt DNS-01) SANs `*.home.bradandmarsha.com` + `home.bradandmarsha.com`.
2. ✅ Frozen listener **names** for new subdomains: `https-wildcard` (`*.home…`). Apex stays `https-home` until contract (cannot dual-run two `home.bradandmarsha.com` listeners).
3. ✅ Subdomain HTTPRoutes: `sectionName: https-wildcard`. Apex HTTPRoute unchanged (`https-home`).
4. Per-host listeners + placeholder `https` / `gateway-edge-tls` **kept** so existing SNI stays programmed until `gateway-home-tls` is Ready (`kgateway` Flux `wait: true` + `dependsOn: lets-encrypt`).

### Contract (2026-08-16)

1. ✅ Delete leftover per-host HTTPS listeners and placeholder `https` (`#28`).
2. ✅ Replace `https-home` with `https-apex` on `gateway-home-tls`; apex HTTPRoute `sectionName: https-apex`.
3. ✅ Delete `certificate-edge-tls` + `Issuer` `selfsigned`; delete app-ns `ReferenceGrant`s.
4. ✅ Delete unused per-app `Certificate` CRs (platform cert only).
5. ✅ Public Gateway: `http` + `https-wildcard` + `https-apex`. Internal: `http` + `https-wildcard`.

### Verify (after merge)

**Verified 2026-08-16** after `#27` (`8f60f52`): subdomain 404s while per-host listeners remained (SNI steal).

**Verified 2026-08-16** after `#28` (`6ca6e99`) — listener contract; apex still on the app cert:

| Check | Result |
|-------|--------|
| Flux `kgateway` | Ready on `6ca6e99` |
| Public listeners | `http` (7), `https-wildcard` (6), `https-home` (1) — all Programmed |
| Internal listeners | `http` (4), `https-wildcard` (4) — all Programmed |
| Subdomain HTTPS | All `server: envoy` — flask/media/home/acruet/flux-web/ceph 200; auth/acruet-admin 302; grafana 302 `/login`; plex 401; oidc `/` 403, well-known 200 |
| Subdomain cert | `CN=*.home.bradandmarsha.com` SAN wildcard + apex (flask `.217`, flux-web `.236`) |
| Apex cert | Still app cert `CN=home.bradandmarsha.com` (`https-home`) |
| Throwaway HTTPRoute `phase8-verify.home…` | Accepted/Programmed **without** Gateway edit; GET 200 envoy + wildcard cert; deleted |

**After this contract finish:** `wise-home-index` Flux KS `dependsOn: kgateway`, so kgateway applies `https-apex` first. Apex may 404 briefly until the HTTPRoute `sectionName` updates (Secret is already Ready — no ACME wait). Then:

| Check | Expect |
|-------|--------|
| Public listeners | `http` + `https-wildcard` + `https-apex` (no `https-home`) |
| Internal listeners | `http` + `https-wildcard` |
| Apex `openssl` SAN | `*.home.bradandmarsha.com` + `home.bradandmarsha.com` (`gateway-home-tls`) |
| Certificates | Only `gateway-home-tls` (Flux prune deletes per-app CRs; cert-manager drops their Secrets) |
| ReferenceGrants | None for Gateway→Secret |
| Public + internal HTTPS | Still `server: envoy` (spot-check) |

**Follow-up (Chrome HTTP/2 coalescing):** `#29` put apex + wildcard on the **same cert** but **two listeners**. Chrome reuses the `home.bradandmarsha.com` connection for subdomains (cert SAN covers both); Envoy keeps SNI=apex → subdomain **404** while `curl` (new SNI) is 200. Index tile images from `media.home…` 404 the same way. Fix: public Gateway has a **single** HTTPS listener `https-wildcard` with **no** `hostname`; apex HTTPRoute uses `sectionName: https-wildcard`. Do not add a second HTTPS listener on this VIP.

Reproduce: `openssl s_client -servername home.bradandmarsha.com` then `Host: flask-hello-world.home.bradandmarsha.com` → 404 before the fix; 200 after.

### Exit criteria

- [x] New subdomain apps require **no** `Gateway` manifest change (throwaway HTTPRoute).
- [x] Gateway HTTPS listener set is stable (http + one HTTPS catch-all); per-app cert sprawl removed.
- [x] Onboarding / ENGINEERING describe the SoD boundary.
- [x] Same-cert public hostnames share one HTTPS listener (no Chrome H2 coalescing 404).

### Rollback

Re-add hostname-scoped listeners + per-app cert refs from git; keep wildcard cert issued but unused until ready to retry.

---

## Risk register

| Risk | Mitigation |
|------|------------|
| Dual Ingress+HTTPRoute DNS fight (`policy=sync`) | Phase 4 rules; one publisher per hostname |
| VIP conflict / ARP flap | Never share IP between nginx and Gateway Services |
| Session affinity gap breaks acruet | Wave C: Maglev cookie `BackendConfigPolicy`; verify stickiness after `--resolve` |
| Ceph HTTPS upstream unsupported | Wave D: `BackendConfigPolicy` skip-verify TLS origination |
| Router still DNAT to old VIP after cutover | Phase 5 VIP checklist; LAN + WAN curl tests |
| Flux NetworkPolicy blocks flux-web | Update in same PR as flux-web HTTPRoute |
| kgateway chart upgrade breaks CRDs | Pin versions; stage upgrades like cert-manager |
| Wildcard omits apex `home.bradandmarsha.com` | Phase 8 cert includes apex SAN; HTTPRoute hostname match on the catch-all HTTPS listener |
| Same cert + two HTTPS listeners on one VIP | Chrome HTTP/2 coalescing 404s subdomains; **one** public HTTPS listener, no hostname |
| Wildcard cutover breaks one hostname’s cert pinning / HSTS assumptions | Dual-run listeners briefly; roll host-by-host if needed |

---

## Rollback

| Stage | Rollback |
|-------|----------|
| Phase 1–2 | Delete Gateways / kgateway Flux KS; ingress-nginx untouched |
| Phase 3 canary | Re-apply flask Ingress; delete HTTPRoute; revert DNS annotations |
| Mid Wave B–D | Re-create that app’s Ingress from git history; remove HTTPRoute; fix DNS |
| Phase 6 after nginx deleted | Restore `ingress-nginx` kustomizations from git + re-migrate (painful) — **do not** delete nginx until Wave D exit criteria met for ≥ several days |

---

## References (in-repo)

| Path | Why |
|------|-----|
| `iac/kustomize/metal-lb/overlays/home-pool.yaml` | Public L2 pool |
| `iac/kustomize/metal-lb/overlays/home-pool-internal.yaml` | Internal L2 pool |
| `iac/kustomize/kgateway/overlays/gateways/` | Public/internal Gateways + MetalLB `GatewayParameters` |
| `iac/kustomize/flask-hello-world/` | Copy HTTPRoutes for new public hostnames (`https-wildcard`) |
| `iac/kustomize/kgateway/overlays/gateways/certificate-home-tls.yaml` | Platform wildcard + apex cert |
| [Onboarding a new hostname](#onboarding-a-new-hostname) | New-app recipe (HTTPRoute only) |
| `iac/kustomize/external-dns/` | DNS sources (`gateway-httproute`) |
| `iac/kustomize/lets-encrypt/base/cluster-issuer.yaml` | DNS-01 issuer (unchanged) |
| `iac/kustomize/fluxcd/flux-system/networkpolicy-flux-web-ingress.yaml` | Allows `gateway-internal` proxies only |

External: [kgateway docs](https://kgateway.dev/docs/), [Gateway API](https://gateway-api.sigs.k8s.io/), [MetalLB usage](https://metallb.io/usage/).
