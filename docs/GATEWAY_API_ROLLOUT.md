# Gateway API rollout (kgateway + MetalLB L2)

Replace **ingress-nginx** (public + internal) with **Kubernetes Gateway API** using **[kgateway](https://kgateway.dev/)** as the control plane, keeping **MetalLB layer-2** as the on-LAN VIP advertisement for both public and internal edge traffic.

**Status:** Phase 2 ✅ complete (2026-08-08) — decisions below are **locked**; revise only via PR.

**README backlog:** [To Do #1](../README.md) — *Replace Ingress' with Gateway API*.

---

## Architecture target

```text
Internet (WAN)
    │
    │  Port-forward / hairpin on home router
    │  (today: WAN → 192.168.40.216 ingress-nginx public VIP)
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
| 5 | Dual-run strategy | **Expand → migrate → contract** — kgateway alongside ingress-nginx until all routes cut over |
| 6 | Canary app | **flask-hello-world** (simple public Ingress, no nginx-specific annotations) |
| 7 | TLS | Keep existing per-app `Certificate` CRs (Let’s Encrypt DNS-01). Phase 2 Gateways use a **placeholder self-signed** secret (`gateway-edge-tls` in `kgateway-system`) on a hostname-agnostic HTTPS listener so L2/HTTPS smoke works. Phase 3+ attaches real secrets via **hostname-scoped HTTPS listeners** (one listener per host + cert). |
| 8 | DNS cutover | Enable external-dns **`gateway-httproute`** (and RBAC) before deleting Ingresses; keep public CNAME→apex pattern where used today |
| 9 | Public VIP cutover | During dual-run, public Gateway gets a **new** IP from `home-pool` (do **not** steal `192.168.40.216` while nginx still holds it). Final cutover: move router DNAT / reclaim `.216` for Gateway **or** leave Gateway on new VIP and point router at it — pick one in Phase 5 checklist |
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
- Pool selection must be explicit (`metallb.io/address-pool: home-pool` vs `home-pool-internal`) — same pattern as `ingress-nginx` overlays.
- **Do not** run two Services claiming the same VIP. Dual-run = two public VIPs until nginx is removed.
- L2 means speakers must run on nodes that can ARP on that L2 segment (already true for ingress-nginx).
- After nginx removal, update any **router port-forward** or docs that hardcode `192.168.40.216` (see KEYCLOAK.md).

**Pools (current)**

| Pool | CIDR range | Used by today | Target Gateway |
|------|------------|---------------|----------------|
| `home-pool` | `192.168.40.216–234` | ingress-nginx public (`.216`) | `gateway-public` |
| `home-pool-internal` | `192.168.40.235–253` | ingress-nginx-internal | `gateway-internal` |

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
| `flux-web.home.bradandmarsha.com` | Update Flux NetworkPolicy that allows only `ingress-nginx-internal` |
| `ceph-dashboard.home.bradandmarsha.com` | Backend **HTTPS** + SSL verify off |
| `grafana-dashboard.home.bradandmarsha.com` | Helm Ingress patch today |

---

## Feature parity (nginx → Gateway)

Resolve **before** migrating the owning app (spike in Phase 2 / early Wave C–D):

| nginx annotation / behavior | Apps | Gateway / kgateway approach (investigate & lock) |
|-----------------------------|------|--------------------------------------------------|
| `affinity: cookie` + session-cookie-* | acruet user/admin | kgateway session affinity / cookie policy (or sticky via app redesign — prefer Gateway policy) |
| `proxy-buffer-size: 128k` | Keycloak | Envoy buffer / kgateway HTTP listener options |
| `backend-protocol: HTTPS` + `proxy-ssl-verify: off` | Ceph dashboard | `BackendTLSPolicy` and/or kgateway upstream TLS |
| Default body/timeout sizes | plex, others | Confirm defaults; raise if uploads fail |

If a feature has no clean Gateway equivalent, document a temporary exception and keep that Ingress until solved — **do not** block Wave A/B.

---

## Progress

| Phase | Status |
|-------|--------|
| 0 — Decisions & inventory | ✅ Locked in this doc |
| 1 — Deploy kgateway + Gateway API CRDs (no traffic) | ✅ Complete (2026-08-08) — Flux Ready; GatewayClass Accepted; no edge LB |
| 2 — MetalLB-backed public/internal Gateways + smoke test | ✅ Complete (2026-08-08) — public `.217`, internal `.236`; nginx `.216`/`.235` unchanged |
| 3 — Canary: flask-hello-world on Gateway API | ⬜ |
| 4 — external-dns Gateway sources + dual-publish strategy | ⬜ |
| 5 — Convert remaining Ingresses (Waves B–D) | ⬜ |
| 6 — Contract: remove Ingresses, ingress-nginx, dead deps | ⬜ |
| 7 — Docs / README / KEYCLOAK.md VIP references | ⬜ |

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

1. Add `HTTPRoute` (and any ReferenceGrant if cross-namespace) for `flask-hello-world.home.bradandmarsha.com` → Service `flask-hello-world:5000`.
2. Attach existing TLS secret `certificate-flask-hello-world` to the public Gateway listener (or listener hostname entry).
3. Keep existing `Ingress` **until** canary verification passes (dual-run).

### Test plan

- [ ] `kubectl get httproute -n default` Accepted / ResolvedRefs
- [ ] `curl -vk --resolve flask-hello-world.home.bradandmarsha.com:443:<gateway-public-vip> https://flask-hello-world.home.bradandmarsha.com/`
- [ ] TLS cert matches Let’s Encrypt secret
- [ ] Index / health behavior unchanged vs nginx path
- [ ] After DNS cutover (Phase 4): public DNS resolves; browser OK from WAN and LAN

### Contract (canary only)

- Remove flask-hello-world `Ingress` (+ Flux deps if any).
- Leave Certificate CR in place.

### Exit criteria

- Canary serves **only** via Gateway for ≥1 day with no rollback.
- Document kgateway + MetalLB annotation recipe used (copy for later apps).

---

## Phase 4 — external-dns Gateway awareness

**Goal:** DNS follows HTTPRoutes / Gateways without relying on Ingress.

### Deliverables

1. Add external-dns source(s): `--source=gateway-httproute` (and Gateway if required by chart version).
2. Extend ClusterRole for `gateway.networking.k8s.io` resources.
3. Annotation strategy:
   - Prefer Gateway API / external-dns supported annotations on `HTTPRoute` or `Gateway` (match today’s hostname + optional `external-dns.alpha.kubernetes.io/target: home.bradandmarsha.com` for public CNAMEs).
4. Dual-publish rule: while Ingress and HTTPRoute both exist for a host, **avoid** conflicting owners under `--policy=sync` — migrate DNS by removing Ingress annotations **or** deleting Ingress only after HTTPRoute is annotated and records verified.

### Verify

- Route53 record for canary host still correct after Ingress removal.
- TXT ownership records update cleanly (`txt-owner-id` unchanged).

### Exit criteria

- New hostnames can be published **without** an Ingress object.

---

## Phase 5 — Convert remaining Ingresses (Waves B–D)

**Goal:** Every hostname from the [inventory](#inventory--ingress--httproute-migration-order) is Gateway-only.

### Per-app checklist (repeat)

1. **Expand:** HTTPRoute (+ TLS listener binding) + any kgateway policies for affinity / buffers / backend TLS.
2. **Verify:** `--resolve` against Gateway VIP; then DNS; OIDC / app-specific flows.
3. **Contract:** delete Ingress; drop `dependsOn` on `ingress-nginx-*` from that app’s Flux Kustomization.
4. Update app docs (e.g. KEYCLOAK.md) if they mention ingress class or VIP.

### Wave-specific gates

| Wave | Extra verification |
|------|-------------------|
| B | plex large media; OIDC discovery JSON on `oidc.` |
| C | Keycloak login + token size; acruet user session stickiness; acruet-admin **only** on internal VIP |
| D | flux-web NetworkPolicy allows Gateway proxy ns/labels; Ceph dashboard TLS-to-upstream; Grafana login |

### Public VIP / router cutover (end of waves)

Pick **one**:

- **A (preferred if router DNAT is sticky):** Drain nginx public Service → free `192.168.40.216` → assign that IP to `gateway-public` → no router change.
- **B:** Leave Gateway on its dual-run VIP → update router DNAT (and any docs) to the new IP.

Record the choice and final VIP here when done.

### Exit criteria

- `kubectl get ingress -A` empty (or only non-homelab leftovers explicitly waived).
- All Flux app Kustomizations depend on Gateway stack, not `ingress-nginx-*`.

---

## Phase 6 — Cleanup: remove ingress-nginx

**Goal:** No ingress-nginx controllers, classes, or Flux kustomizations.

### Contract steps

1. Confirm no Ingress objects and no Services selecting nginx controllers.
2. Remove Flux Kustomizations:
   - `ingress-nginx-public`
   - `ingress-nginx-internal`
   - entries in `fluxcd/kustomizations/kustomization.yaml`
3. Delete `iac/kustomize/ingress-nginx/` (or archive in git history only).
4. Remove NetworkPolicy references to `ingress-nginx-internal` (flux-web); replace with kgateway proxy selectors.
5. Reclaim MetalLB IPs formerly held by nginx Services.
6. Optional: tighten `home-pool` if unused addresses should stay reserved for Gateways only.

### Verify

```bash
kubectl get ns | grep ingress-nginx   # expect gone
kubectl get ingressclass              # nginx classes gone
kubectl get svc -A | grep LoadBalancer
# only MetalLB consumers: gateway-public, gateway-internal (+ any intentional others)
```

### Exit criteria

- Cluster edge is **only** kgateway + MetalLB L2.
- README To Do #1 marked complete with date.

---

## Phase 7 — Documentation

- [ ] This rollout Progress table → all phases ✅
- [ ] `README.md` To Do #1 struck / completed
- [ ] KEYCLOAK.md / app READMEs: Ingress class → Gateway; VIP if changed
- [ ] ENGINEERING or platform notes: new apps use HTTPRoute + parentRefs, not Ingress
- [ ] Note kgateway / Gateway API versions pinned in GitOps

---

## Risk register

| Risk | Mitigation |
|------|------------|
| Dual Ingress+HTTPRoute DNS fight (`policy=sync`) | Phase 4 rules; one publisher per hostname |
| VIP conflict / ARP flap | Never share IP between nginx and Gateway Services |
| Session affinity gap breaks acruet | Spike policy before Wave C; hold Ingress until ready |
| Ceph HTTPS upstream unsupported | `BackendTLSPolicy` spike in Phase 2/5 |
| Router still DNAT to old VIP after cutover | Phase 5 VIP checklist; LAN + WAN curl tests |
| Flux NetworkPolicy blocks flux-web | Update in same PR as flux-web HTTPRoute |
| kgateway chart upgrade breaks CRDs | Pin versions; stage upgrades like cert-manager |

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
| `iac/kustomize/ingress-nginx/overlays/public/` | Pattern for LB + `home-pool` |
| `iac/kustomize/ingress-nginx/overlays/internal/` | Pattern for LB + `home-pool-internal` |
| `iac/kustomize/flask-hello-world/base/ingress.yaml` | Canary Ingress |
| `iac/kustomize/external-dns/` | DNS sources to extend |
| `iac/kustomize/lets-encrypt/base/cluster-issuer.yaml` | DNS-01 issuer (unchanged) |
| `iac/kustomize/fluxcd/flux-system/networkpolicy-flux-web-ingress.yaml` | Must update for Gateway |

External: [kgateway docs](https://kgateway.dev/docs/), [Gateway API](https://gateway-api.sigs.k8s.io/), [MetalLB usage](https://metallb.io/usage/).
