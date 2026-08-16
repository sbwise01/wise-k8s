# Keycloak identity provider rollout plan

Deploy **Keycloak** on **wise-k8s** as a self-hosted OIDC/OAuth2 identity provider for a new **public-facing application**, backed by a **highly available Postgres** database.

This plan follows the same phased, verifiable style used for other homelab rollouts (see `LONG_HORIZON.md` if present). Update the **Progress** table as phases complete. Cluster edge is **kgateway** — see [`GATEWAY_API_ROLLOUT.md`](GATEWAY_API_ROLLOUT.md).

---

## Recommendation

**Yes — Keycloak is a good fit for this homelab**, with caveats.

### Why it fits

| Factor | Assessment |
|--------|------------|
| **Your goal** | Public app + user authentication + HA database → standard OIDC IdP pattern |
| **Existing stack** | CloudNativePG operator is already deployed; Keycloak runs well on **external Postgres** (required for HA) |
| **GitOps** | Flux + Kustomize overlays match how the rest of `wise-k8s` is managed |
| **Platform direction** | README already lists “Add keycloak for idp” — suggests multiple apps over time, not a one-off |
| **Standards** | OIDC/OAuth2 integrates with kgateway (`gateway-public`), Grafana, custom apps, and future services |

### Caveats (go in with eyes open)

| Topic | Notes |
|-------|--------|
| **Complexity** | Keycloak is powerful but heavy (realms, clients, flows, sessions). Budget time to learn admin concepts. |
| **Not the only option** | For a *single* simple app with no growth plans, **oauth2-proxy** or **Authentik/Zitadel** may be lighter. Keycloak wins when you want a full IdP platform. |
| **Name collision** | `oidc.home.bradandmarsha.com` is your **AWS IAM Roles Anywhere OIDC provider** — unrelated to user login. Use a distinct hostname for Keycloak (e.g. `auth.home.bradandmarsha.com`). |
| **Resources** | JVM + 3× CNPG instances + 2× Keycloak replicas is non-trivial on a 3-node homelab. Start with minimal replicas, scale after validation. |
| **HA semantics** | HA Keycloak = **external DB (CNPG)** + **2+ replicas** + **embedded Infinispan** (default; `jdbc-ping` discovery via Postgres). External Infinispan is **not** needed for single-cluster homelab. |

### Architecture target

```text
Internet / LAN
    │
    ▼
kgateway gateway-public (VIP 192.168.40.217; WAN TCP 443)
    ──►  auth.home.bradandmarsha.com  ──►  Keycloak (2+ replicas)
                                                                    │
                                                                    ▼
                                                          CNPG cluster (keycloak-db)
                                                                    │
                                                          Ceph RBD (csi-rbd-sc)

New public app  ──OIDC──►  Keycloak          New public app  ──►  CNPG (app-db)  [separate cluster]
```

**Separate databases:** one CNPG cluster for Keycloak, one for the application. Do not share the Plex DB cluster.

---

## Scope

| In scope | Out of scope (later) |
|----------|----------------------|
| Keycloak Operator deployment | Social login (Google/GitHub) — optional Phase 7 |
| Dedicated CNPG cluster for Keycloak | Migrating existing apps to Keycloak |
| Public HTTPRoute + TLS + external-dns | — (Gateway API migration complete 2026-08-16; see `docs/GATEWAY_API_ROLLOUT.md`) |
| Realm for the new app (Phase 4) | SAML / LDAP federation |
| OIDC client + app integration (Phase 5) | — |
| HA Postgres + 2 Keycloak replicas | Multi-site disaster recovery |
| Basic monitoring hooks | Full SSO for Grafana/Ceph dashboard |

---

## Conventions (match existing `wise-k8s` patterns)

| Item | Suggested value |
|------|-----------------|
| Keycloak hostname | `auth.home.bradandmarsha.com` |
| Public edge | HTTPRoute → `gateway-public` (`sectionName: https-wildcard`); VIP **`192.168.40.217`**; WAN TCP **443** |
| Header size | `ListenerPolicy` `maxRequestHeadersKb: 128` on `gateway-public` (OIDC cookies) |
| TLS | Platform Secret `gateway-home-tls` on frozen listener `https-wildcard` |
| DNS | external-dns `gateway-httproute`; CNAME → `home.bradandmarsha.com` |
| Storage class | `csi-rbd-sc` (Rook Ceph) |
| Git layout | `iac/kustomize/keycloak-operator/`, `keycloak/`, `keycloak-cnpg/` |
| Flux Kustomizations | `cloud-native-pg` already exists; add `keycloak-cnpg`, `keycloak-operator`, `keycloak` (`dependsOn: kgateway`) |
| Secrets | SOPS or Sealed Secrets if already used elsewhere; never commit plaintext admin passwords |

---

## Progress

| Phase | Status |
|-------|--------|
| 0 — Baseline & decisions | ✅ Complete (2026-07-11) |
| 1 — Keycloak CNPG database | ✅ Complete (2026-07-11) |
| 2 — Keycloak Operator + dev instance | ✅ Complete (2026-07-11) |
| 3 — Public ingress + TLS | ✅ Complete (2026-07-11) |
| 4 — Realm + admin hardening | ✅ Complete (2026-07-12) |
| 5 — OIDC client + a-cruet integration | Pending — product decisions locked (2026-07-12) |
| 5.1 — GitOps leftover client / console config | Pending — cluster works; console steps not in Git (README todo) |
| 6 — HA Keycloak + acruet-cnpg | Pending |
| 7 — Observability, backup, optional extras | Pending |
| 8 — End-to-end verification | Pending |

---

## Phase 0 — Baseline & decisions ✅ complete (2026-07-11)

**Goal:** Confirm prerequisites and lock design choices before manifests.

### Checklist results

| Check | Result |
|-------|--------|
| CNPG operator (`cnpg-system`) | **Pass** — `cnpg-controller-manager` 1/1; image `cloudnative-pg:1.30.0` |
| Flux `cloud-native-pg` | **Pass** — Ready @ `d7c41b50` |
| Flux `cert-manager` | **Pass** — Ready |
| Flux `external-dns` | **Pass** — Ready |
| Flux `ingress-nginx-public` | **Pass** — Ready |
| Public ingress LB | **Pass** — `ingress-nginx-controller` at `192.168.40.216` (80/443) |
| ClusterIssuer `letsencrypt-prod` | **Pass** — Ready |
| StorageClass `csi-rbd-sc` | **Pass** — Ceph RBD provisioner |
| CNPG reference cluster | **Pass** — `plex-cnpg/plex-db` healthy, 3/3 instances (recent rebuild) |
| Hostname collision | **Pass** — `oidc.home.bradandmarsha.com` is AWS IAM OIDC only; `auth.home.bradandmarsha.com` unused |
| `kubectl top nodes` | **Skip** — metrics-server not installed (optional check) |

**Capacity note:** 4 nodes (`wise-k8s-10`–`13`), 16 CPU / ~32 GiB each; ~94 running pods cluster-wide. Sufficient for Keycloak + another CNPG cluster, but watch JVM memory during Phase 2–6.

Nginx rows above are the **2026-07-11 baseline**. Public edge is now **kgateway** `gateway-public` at **`192.168.40.217`** (WAN TCP 443); see [Conventions](#conventions-match-existing-wise-k8s-patterns).

### Decisions recorded

| Decision | Choice |
|----------|--------|
| Keycloak hostname | **`auth.home.bradandmarsha.com`** |
| Keycloak Operator version | **26.7.0** (`keycloak-k8s-resources` ref `26.7.0`) |
| Keycloak server version | **26.7.0** (match operator) |
| Realm name | **`wise-k8s`** |
| Planned app | **a-cruet** (envelope budgeting) — see `a-cruet/PRODUCT.md`, `a-cruet/ROLLOUT.md` |
| User app hostname | **`acruet.home.bradandmarsha.com`** (public `gateway-public`) |
| Admin app hostname | **`acruet-admin.home.bradandmarsha.com`** (internal `gateway-internal`, VIP **`192.168.40.236`**) |
| OIDC mode | **Native OIDC** — confidential client, Tomcat server-side sessions (Jersey) |
| OIDC client ID | **`acruet`** — redirect path `/auth/callback` on both hostnames |
| Admin API client ID | **`acruet-admin`** — service account, client credentials (user provisioning) |
| Realm role | **`a-cruet-admin`** — admin hostname authorization |
| Keycloak self-registration | **Disabled** — applicants use a-cruet public signup; Keycloak users created on admin approval |
| Admin access | **Public** `gateway-public`; permanent admin with **MFA** (Phase 4 complete) |

### Deliverable

- [x] Decisions table filled (app hostname + OIDC mode deferred)
- [x] No conflict with `oidc.home.bradandmarsha.com` (AWS IAM OIDC) confirmed

### Checklist commands (reference)

```bash
# CNPG operator healthy
kubectl get deployment -n cnpg-system
flux get kustomizations cloud-native-pg

# Public HTTPS path works (cert-manager, external-dns, kgateway)
kubectl -n kgateway-system get svc gateway-public
flux get kustomizations cert-manager external-dns kgateway

# Capacity sanity (optional)
kubectl top nodes
```

---

## Phase 1 — Keycloak CNPG database ✅ complete (2026-07-11)

**Goal:** HA Postgres ready before Keycloak starts.

**Pattern:** Copy `iac/kustomize/plex-cnpg/` → `iac/kustomize/keycloak-cnpg/`.

### Manifests

| Resource | Notes |
|----------|--------|
| Namespace | `keycloak-cnpg` |
| `Cluster` | 3 instances, `minSyncReplicas: 1`, `csi-rbd-sc`, Postgres 17 image (match plex-cnpg) |
| `Database` | e.g. `keycloak` owned by `keycloak` |
| Bootstrap | CNPG creates Secret `{cluster}-app` with connection URI |

### Sizing (starting point — tune later)

| Setting | Value |
|---------|--------|
| `instances` | 3 |
| `storage.size` | 5Gi |
| `resources.requests` | 100m CPU, 512Mi memory |
| `max_connections` | 200 |

### Verify

```bash
kubectl -n keycloak-cnpg get cluster
kubectl -n keycloak-cnpg get pods
kubectl -n keycloak-cnpg get secret keycloak-db-app -o jsonpath='{.data.uri}' | base64 -d
# expect: postgresql://keycloak:***@keycloak-db-rw.keycloak-cnpg.svc:5432/keycloak
```

Verified 2026-07-11:

| Check | Result |
|-------|--------|
| Flux `keycloak-cnpg` | **Ready** @ `d00888bb` |
| `keycloak-db` cluster | **Healthy** — 3/3 instances, 5Gi, primary `keycloak-db-1` |
| Pods | **3/3 Running** on `wise-k8s-11`–`13` |
| `Database` `keycloak` | **Applied** |
| Secret `keycloak-db-app` | **Present** — `uri`, `jdbc-uri`, `host`, `port`, `dbname`, `username`, `password` keys |

### Flux

Add `iac/kustomize/fluxcd/kustomizations/keycloak-cnpg.yaml` referencing `./iac/kustomize/keycloak-cnpg/overlays`.

---

## Phase 2 — Keycloak Operator + single instance (internal)

**Goal:** Keycloak running against CNPG, reachable inside the cluster only.

### Manifests

| Area | Path | Notes |
|------|------|--------|
| Operator | `iac/kustomize/keycloak-operator/` | Upstream `keycloak-k8s-resources` **26.7.0** cluster-wide install in `keycloak-operator` namespace |
| Keycloak CR | `iac/kustomize/keycloak/` | `Keycloak` CR in `keycloak` namespace — **1 replica**, ingress disabled |
| DB credentials | `keycloak/base/db-credentials-sync.yaml` | Bootstrap Job + CronJob mirrors `keycloak-db-app` from `keycloak-cnpg` → `keycloak` (operator requires same-namespace secrets) |
| Flux | `keycloak-operator.yaml`, `keycloak.yaml` | `keycloak` depends on `keycloak-cnpg` + `keycloak-operator` |

**Keycloak CR highlights (Phase 2):**

- `spec.db.host`: `keycloak-db-rw.keycloak-cnpg.svc`
- `spec.http.httpEnabled: true` (port-forward on 8080)
- `spec.hostname.hostname`: `auth.home.bradandmarsha.com` (prep for Phase 3; `strict: false` until public ingress)
- `spec.ingress.enabled: false`

### Cross-namespace DB secret

CNPG creates `keycloak-db-app` in `keycloak-cnpg`. The Keycloak Operator reads `usernameSecret` / `passwordSecret` from the Keycloak CR namespace only. Until a reflector or ExternalSecrets pattern is adopted cluster-wide, a small sync Job (bootstrap) + CronJob (every 5m, password rotation) copies the secret into `keycloak`.

### Verify

```bash
flux get kustomizations keycloak-operator keycloak
kubectl -n keycloak-operator get deployment
kubectl -n keycloak get keycloak,pods,secret keycloak-db-app
kubectl -n keycloak get job keycloak-db-credentials-sync-bootstrap
kubectl -n keycloak port-forward svc/keycloak-service 8080:8080
# Open http://localhost:8080 — admin console loads
# Admin password: kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d; echo
# Confirm Postgres (not H2): kubectl -n keycloak logs -l app=keycloak | grep -i postgres
```

Verified 2026-07-11:

| Check | Result |
|-------|--------|
| Flux `keycloak-operator` | **Ready** @ `99593ff6` |
| Flux `keycloak` | **Ready** @ `99593ff6` |
| Operator deployment | **1/1** Running in `keycloak-operator` |
| `Keycloak` CR | **Ready** — 1 instance, ingress disabled |
| Pods | **keycloak-0** 1/1 Running |
| Service | **keycloak-service** — endpoints `10.0.2.150:8080,9000` |
| Ingress | **None** (internal only) |
| DB secret mirror | **keycloak-db-app** present (11 keys); bootstrap Job + CronJob **Complete** |
| Admin bootstrap | **keycloak-initial-admin** Secret present |
| Database | **Postgres** — logs show `jdbc-postgresql`, `JDBC_PING`; not H2 |
| HTTP (in-cluster) | **302** on `/` and `/admin/` via `keycloak-service:8080` (expected redirects) |
| CNPG `keycloak-db` | **Healthy** — 3/3 instances |

**Note:** CR reports `HasErrors` with a non-blocking warning — ServiceMonitor skipped because `metrics-enabled` is not set (address in Phase 7).

### Gotchas

- Wrong JDBC URL or SSL mode → Keycloak CrashLoop; test URI from a toolbox pod first.
- Bootstrap Job must complete before Keycloak can connect — if pods CrashLoop, check `keycloak-db-app` exists in `keycloak` namespace.
- Do not expose admin console publicly until Phase 4 hardening.

---

## Phase 3 — Public ingress + TLS

**Goal (2026-07-11):** `https://auth.home.bradandmarsha.com` on **public** ingress (`ingressClassName: nginx`).

**Current edge (2026-08-16):** same hostname on **kgateway** `gateway-public` (VIP **`192.168.40.217`**, WAN TCP **443**). Manifests: `keycloak/base/httproute.yaml` (`sectionName: https-wildcard`); platform Secret `gateway-home-tls` (no app `Certificate`); `ListenerPolicy` `maxRequestHeadersKb: 128`. Operator ingress stays disabled. Historical nginx Ingress / Certificate table below is the Phase 3 verify snapshot.

### Manifests

| Resource | Path | Notes |
|----------|------|--------|
| `Certificate` | `keycloak/base/certificate.yaml` | cert-manager, DNS `auth.home.bradandmarsha.com`, issuer `letsencrypt-prod` |
| `Ingress` | `keycloak/base/ingress.yaml` | `ingressClassName: nginx`, external-dns hostname + CNAME target, backend `keycloak-service:8080` |
| Keycloak CR | `keycloak/base/keycloak.yaml` | `hostname.strict: true`; `proxy.headers: xforwarded`; operator ingress remains disabled (manual Ingress matches other `wise-k8s` apps) |

**Ingress annotations:**

- `external-dns.alpha.kubernetes.io/hostname` / `target` — DNS record via external-dns (CNAME to `home.bradandmarsha.com`)
- `nginx.ingress.kubernetes.io/proxy-buffer-size: 128k` — larger buffers for Keycloak auth cookies/headers

Nginx ingress forwards `X-Forwarded-Proto` / `X-Forwarded-Host` by default; Keycloak `proxy.headers: xforwarded` consumes them.

### Verify

```bash
flux get kustomizations keycloak kgateway
kubectl -n keycloak get certificate,httproute
kubectl -n keycloak describe certificate keycloak-certificate

curl -sI https://auth.home.bradandmarsha.com/realms/master
# HTTP 200 or 302 — not connection refused

curl -s https://auth.home.bradandmarsha.com/realms/master/.well-known/openid-configuration | jq .issuer
# issuer must be https://auth.home.bradandmarsha.com/realms/master
```

Verified 2026-07-11:

| Check | Result |
|-------|--------|
| Flux `keycloak` | **Ready** @ `cf28e21f` |
| `Certificate` `keycloak-certificate` | **Ready** — Let's Encrypt, expires 2026-10-10 |
| TLS secret | **Present** — `keycloak-certificate` |
| `Ingress` `keycloak-ingress` | **Active** — class `nginx`, address `192.168.40.208`, backend `keycloak-service:8080` |
| external-dns | **Created** — `auth.home.bradandmarsha.com` CNAME → `home.bradandmarsha.com` |
| Keycloak CR | **Ready** — `hostname.strict: true`, `proxy.headers: xforwarded` |
| `keycloak-0` | **1/1** Running |
| `curl -sI .../realms/master` | **HTTP/2 200** |
| OIDC discovery issuer | **`https://auth.home.bradandmarsha.com/realms/master`** |
| Admin console | **HTTP/2 302** → `/admin/master/console/` |
| TLS (openssl) | **CN=auth.home.bradandmarsha.com**, issuer Let's Encrypt |

---

## Phase 4 — Realm + admin hardening ✅ complete (2026-07-12)

**Goal:** Production-shaped realm; admin surface reduced.

Phase 4 is **realm and admin configuration**, not cluster infrastructure. The realm can be created via the **admin console** or **GitOps** (`KeycloakRealmImport`).

| Deliverable | Console | GitOps (Keycloak Operator CRs) |
|-------------|---------|--------------------------------|
| Realm `wise-k8s` | Create in admin UI | `KeycloakRealmImport` — `iac/kustomize/keycloak/base/realm-import.yaml` ([CRD](https://www.keycloak.org/operator/realm-import)) |
| Test user / roles | Users & roles UI | Include in realm import JSON, or create via UI |
| Admin password rotation | Users → admin → Credentials | Operator Secret `keycloak-initial-admin` or custom bootstrap |
| Admin console restriction | — | HTTPRoute / NetworkPolicy / internal Gateway |

**Admin hardening choices (2026-07-12):** Admin console remains on **public** `gateway-public`; permanent `master` admin replaces `temp-admin` with **MFA** (TOTP and/or WebAuthn) enrolled.

**Realm name:** **`wise-k8s`** (Phase 0 decision). Use `master` only for break-glass admin — not for app logins.

### Tasks

1. **Create realm `wise-k8s`**
   - Disable or don't use `master` for application authentication.
   - GitOps: `iac/kustomize/keycloak/base/realm-import.yaml` (`KeycloakRealmImport`, `keycloakCRName: keycloak`). Import is create-only; users and clients are added separately (client in Phase 5).

2. **Optional:** test user, realm roles, groups.

3. **Admin hardening:**
   - Create permanent admin in `master`; delete `temp-admin` (see operator bootstrap banner)
   - Rotate bootstrap admin password (Secret `keycloak-initial-admin` or Keycloak admin UI)
   - Consider restricting admin console to `gateway-internal` or an IP allowlist
   - Brute-force detection (enabled in `realm-import.yaml` — verify in realm settings)
   - Document break-glass admin recovery

### Verify

```bash
# Realm exists and discovery works
curl -s https://auth.home.bradandmarsha.com/realms/wise-k8s/.well-known/openid-configuration | jq .issuer
# expect: https://auth.home.bradandmarsha.com/realms/wise-k8s

# GitOps CR applied (if used)
kubectl -n keycloak get keycloakrealmimport
```

**Functional checks:**

- Login flow in Keycloak account console works for test user (`https://auth.home.bradandmarsha.com/realms/wise-k8s/account`).
- OIDC discovery document lists expected endpoints for `wise-k8s`.

Verified 2026-07-12:

| Check | Result |
|-------|--------|
| `KeycloakRealmImport` `wise-k8s-realm` | **Done** |
| OIDC issuer | **`https://auth.home.bradandmarsha.com/realms/wise-k8s`** |
| Realm settings | `sslRequired: external`, `bruteForceProtected: true`, `resetPasswordAllowed: true`, SMTP via `keycloak-smtp` + `realm-import.yaml` |
| Permanent `master` admin | **Created** — replaces `temp-admin` |
| Admin MFA | **Enrolled** on permanent admin |
| `temp-admin` | **Removed** |
| Admin console | **Public** `gateway-public` (MFA protects account access) |

---

## Phase 5 — OIDC client + a-cruet integration

**Goal:** Register **a-cruet** in Keycloak and authenticate users/admins via OIDC.

**Status:** Product decisions locked in `a-cruet/PRODUCT.md` (2026-07-12). Execute after **a-cruet ROLLOUT Phase 3** (Tomcat shells deployed with HTTPRoute + TLS). Can overlap with **a-cruet ROLLOUT Phase 2** (`acruet-cnpg`) and **Keycloak Phase 6** HA scale.

**Prerequisites (a-cruet):**

| Prerequisite | Value |
|--------------|-------|
| User HTTPRoute + TLS | `https://acruet.home.bradandmarsha.com` (`gateway-public`) |
| Admin HTTPRoute + TLS | `https://acruet-admin.home.bradandmarsha.com` (`gateway-internal` `.236`) |
| OIDC callback handler | `/auth/callback` on both hostnames |
| Client secret storage | SOPS-encrypted Secret in `iac/kustomize/acruet/` |
| First admin bootstrap | Manual `a-cruet-admin` realm role in Keycloak console |

**Can proceed without a-cruet:** Keycloak Phase 6 HA scale (`spec.instances: 2`) and Phase 7 observability.

### a-cruet Keycloak objects

| Object | ID / name | Purpose |
|--------|-----------|---------|
| OIDC client | **`acruet`** | Confidential; Authorization Code flow; user + admin Tomcat sign-in |
| Service account client | **`acruet-admin`** | Client credentials; a-cruet → Keycloak Admin API (provision users on approval) |
| Realm role | **`a-cruet-admin`** | Admin hostname authorization (checked server-side in admin WAR) |

**Realm settings (already in `realm-import.yaml`):** `registrationAllowed: false` — applicants do **not** self-register in Keycloak.

### OIDC client `acruet` (user + admin sign-in)

| Setting | Value |
|---------|-------|
| Client type | **Confidential** — client secret in k8s Secret (SOPS) |
| Client ID | `acruet` |
| Standard flow | **Enabled** (Authorization Code) |
| Implicit flow | **Disabled** |
| Direct access grants | **Disabled** (unless needed for testing) |
| Redirect URIs | `https://acruet.home.bradandmarsha.com/auth/callback` |
| | `https://acruet-admin.home.bradandmarsha.com/auth/callback` |
| Web origins | `https://acruet.home.bradandmarsha.com` |
| | `https://acruet-admin.home.bradandmarsha.com` |
| Valid post logout redirect URIs | Same host roots (or `+` pattern per Keycloak version) |
| Issuer | `https://auth.home.bradandmarsha.com/realms/wise-k8s` |

**App integration:** Native OIDC in Java/Tomcat (Jersey filters or OIDC library). Server-side HTTP sessions after callback — not a SPA public client with PKCE.

### Service account client `acruet-admin` (user provisioning)

| Setting | Value |
|---------|-------|
| Client ID | `acruet-admin` |
| Client authentication | **On** (confidential) |
| Service accounts | **Enabled** (`SERVICE_ACCOUNT` login flow) |
| Standard flow | **Disabled** |
| Grant used by app | **Client credentials** → Keycloak Admin REST API |

**Required service-account permissions (realm `wise-k8s`):** grant roles to manage users — at minimum `manage-users`, `view-users`, `manage-realm` (or equivalent `realm-management` client roles). Scope narrowly in production; document chosen role set in `oidc-client-acruet-admin.yaml` comments.

**Used for:** create Keycloak user on admin approval; set temporary password; enable/disable user on suspend/offboard; grant/revoke `a-cruet-admin` realm role.

### Realm role `a-cruet-admin`

| Setting | Value |
|---------|-------|
| Role name | `a-cruet-admin` |
| Type | Realm role (not client role) |
| First assignment | **Manual** in Keycloak admin console (bootstrap) |
| Ongoing assignment | a-cruet admin UI → Keycloak Admin API |

Map into OIDC token: include realm roles in ID token or access token; admin WAR checks `a-cruet-admin` on every request.

### GitOps manifests (recommended)

| File | CR / resource |
|------|----------------|
| `iac/kustomize/keycloak/base/realm-import.yaml` | `KeycloakRealmImport` — realm `wise-k8s` (+ `smtpServer` backfill) |
| `iac/kustomize/keycloak/base/secrets/keycloak-smtp.yaml` | SOPS Secret — Proton SMTP for realm email |
| `iac/kustomize/keycloak/base/oidc-client-acruet.yaml` | `KeycloakOIDCClient` — client `acruet` |
| `iac/kustomize/keycloak/base/oidc-client-acruet-admin.yaml` | `KeycloakOIDCClient` — client `acruet-admin` + service account |
| `iac/kustomize/keycloak/base/realm-role-acruet-admin.yaml` | Realm role (or include in realm import / console once) |

Reference CRD: `KeycloakOIDCClient` v2alpha1 — `loginFlows: [STANDARD]` for `acruet`; `loginFlows: [SERVICE_ACCOUNT]` for `acruet-admin`; `auth.secretRef` points to SOPS Secret.

**SMTP (two paths):**

| Path | Sender | Used for |
|------|--------|----------|
| **a-cruet app** (`acruet-smtp` Secret → `ACRUET_SMTP_*`) | Proton `noreply@bradandmarsha.com` | Signup verification, approval/rejection, suspend/offboard notices |
| **Keycloak realm** (`keycloak-smtp` Secret → `KeycloakRealmImport` `smtpServer`) | Same Proton relay by default | **Forgot password** on Keycloak login, execute-actions email |

GitOps: `iac/kustomize/keycloak/base/realm-import.yaml` declares `smtpServer`; kustomize **replacements** inject host/port/from/user/password from `secrets/keycloak-smtp.yaml` (SOPS). **`KeycloakRealmImport` is create-only** — on an existing cluster, configure **Realm settings → Email** in the admin console to match (or export realm JSON after console setup).

**Verify forgot-password email:**

1. Keycloak admin → `wise-k8s` → Realm settings → Email → **Test connection**
2. From Keycloak login (via a-cruet Sign in), **Forgot Password?** with a provisioned user email
3. Keycloak pod egress to `smtp.protonmail.ch:587` (STARTTLS)

If you change comments or metadata on `keycloak-smtp.yaml`, refresh the SOPS MAC: `sops updatemac secrets/keycloak-smtp.yaml` (from `iac/kustomize/keycloak/base/`).

### OIDC client checklist

- [ ] `KeycloakOIDCClient` `acruet` — redirect URIs + web origins (both hostnames)
- [ ] Client secret generated; stored in SOPS Secret; referenced by `auth.secretRef`
- [ ] `KeycloakOIDCClient` `acruet-admin` — service account enabled
- [ ] Service account granted `realm-management` roles for user CRUD
- [ ] Realm role `a-cruet-admin` created
- [ ] First admin user assigned `a-cruet-admin` manually
- [ ] a-cruet user WAR: unauthenticated → Keycloak → `/auth/callback` → session
- [ ] a-cruet admin WAR: same OIDC client; server blocks non-`a-cruet-admin` roles
- [ ] Logout clears Tomcat session (optional: Keycloak SSO logout)
- [ ] Wrong redirect URI → Keycloak error (proves client binding)

### Verify

```bash
kubectl -n keycloak get keycloakoidcclient
kubectl -n keycloak describe keycloakoidcclient acruet
kubectl -n keycloak describe keycloakoidcclient acruet-admin

# OIDC discovery (unchanged from Phase 4)
curl -s https://auth.home.bradandmarsha.com/realms/wise-k8s/.well-known/openid-configuration | jq .issuer
```

**Functional checks:**

| Check | Expected |
|-------|----------|
| User host login | `https://acruet.home.bradandmarsha.com` → Keycloak → callback → landing page |
| Admin host login | `https://acruet-admin.home.bradandmarsha.com` → Keycloak → callback → admin UI (role required) |
| Non-admin on admin host | OIDC succeeds but app returns **403** without `a-cruet-admin` |
| Admin API token | `acruet-admin` client credentials returns access token with Admin API scope |
| Provision user | Approve signup in admin UI → Keycloak user exists in `wise-k8s` |
| Public signup | No Keycloak login offered to applicants — a-cruet public form only |

**GitOps leftovers** (console-only after Phase 4/5 bootstrap) are **[Phase 5.1](#phase-51--gitops-leftover-client--console-config)** — a-cruet login working does **not** close them.

---

## Phase 5.1 — GitOps leftover client / console config

**Goal:** Put the a-cruet Keycloak settings that were applied in the admin console into GitOps (or document a durable CRD gap). Live OIDC already works; this phase is **reproducibility**, not a new login feature.

**Status:** Pending. Source of the task list: [`README.md`](../README.md) To Do #2. Can overlap with Phase 6 HA.

**Why:** `KeycloakOIDCClient` + `KeycloakRealmImport` cover client id, secret, redirect URIs, and web origins. They do **not** (today) express everything the cluster is running on. Recreating the realm or operator would drop console-only config.

### In cluster today (console / not fully in Git)

| Item | What exists | Gap |
|------|-------------|-----|
| Secret `keycloak-admin` | SOPS in `keycloak/base/secrets/keycloak-admin.yaml` (`client-id` / `client-secret`) | The **`master`** realm confidential client (operator / Admin API) was created in console; no CR owns it |
| Client `acruet` default scope **`roles`** | Console | Not in `oidc-client-acruet.yaml` |
| Dedicated client scope for **`a-cruet-admin`** on the **access token** | Console (role claims for admin WAR) | Not in Git; mapper/scope not in the CR |
| Valid post-logout redirect URIs | Need host roots `https://acruet.home.bradandmarsha.com/` and `https://acruet-admin.home.bradandmarsha.com/` | `redirectUris` are `/auth/callback` only; Keycloak `+` does **not** cover `/` |
| Client `acruet-admin` `realm-management` roles | Console after reconcile | CR cannot assign them — see comment on `oidc-client-acruet-admin.yaml` (Client Admin API v2 resolves realm roles and this client’s own roles, not `realm-management`) |

Required `realm-management` client roles (narrow set used by a-cruet admin API): **`manage-users`**, **`view-users`**, **`query-users`**, **`view-realm`**.

### Tasks

1. **Inventory** current console state (screenshot or `kcadm` / Admin API dump) for the four items above so GitOps cannot silently drop a live setting.
2. **Evaluate the CRD** before adding more console:
   - `KeycloakOIDCClient` v2alpha1 fields (scopes, protocol mappers, `postLogoutRedirectUris` / equivalent, `serviceAccountRoles`)
   - `KeycloakRealmImport` (create-only — **do not** re-import the live `wise-k8s` realm to “fix” this)
   - Operator **Client Admin API v2** (`spec.features.enabled: client-admin-api:v2` already on the Keycloak CR) — retry `serviceAccountRoles` if a newer operator maps `realm-management`
3. **GitOps what the CR can express** (expand `oidc-client-acruet.yaml` / `oidc-client-acruet-admin.yaml`, or a dedicated client in `master` for `keycloak-admin`). Flux-reconcile; confirm the operator does not wipe console-only fields it does not model.
4. **Document remaining gaps** in this phase (and on the YAML comments) if the API still cannot set scopes, post-logout URIs, or `realm-management` roles. Those stay break-glass console + README until the operator catches up.
5. **Strike README To Do #2** when every row is either in Git and reconciled, or explicitly accepted as an operator limitation with a comment + this phase note.

Do **not** treat a successful a-cruet login as exit criteria — that already passed in Phase 5 / a-cruet ROLLOUT.

### Verify

```bash
kubectl -n keycloak get secret keycloak-admin
kubectl -n keycloak get keycloakoidcclient acruet acruet-admin -o yaml
# After CR changes: operator did not reset console-only fields it cannot represent
```

| Check | Expected |
|-------|----------|
| `acruet` default client scopes | Includes `roles` |
| Access token from user login | Contains `a-cruet-admin` when the user has that realm role (dedicated scope / mapper) |
| Logout from user + admin hosts | Redirect to `https://acruet.home.bradandmarsha.com/` / `https://acruet-admin.home.bradandmarsha.com/` allowed |
| `acruet-admin` service account | `realm-management`: `manage-users`, `view-users`, `query-users`, `view-realm` |
| Approve signup / grant-revoke admin | Still works after reconcile (Admin API permissions intact) |
| Secret `keycloak-admin` | Matches a GitOps-owned `master` client, **or** gap documented |

### Exit criteria

- [ ] Each leftover item is GitOps’d **or** recorded as an operator/CRD limitation with the console steps.
- [ ] Flux `keycloak` Ready; a-cruet user + admin OIDC and Admin API provisioning still work.
- [ ] `README.md` To Do #2 removed or reduced to “accepted CRD gaps” with a link here.

### Rollback

Revert the Keycloak client CRs; restore console settings from the inventory dump. Do not delete Secret `keycloak-admin` unless a replacement client is already working.

---

## Phase 6 — HA Keycloak + application database

**Goal:** Survive pod loss; app data on its own HA Postgres.

### Keycloak HA

| Step | Action |
|------|--------|
| Scale Keycloak CR | `spec.instances: 2` (or 3 on a 3-node cluster) |
| Distributed cache | **Embedded Infinispan** inside each Keycloak pod (production default). Do **not** deploy a separate Infinispan/Data Grid cluster for wise-k8s. |
| Cluster discovery | **`jdbc-ping`** (Keycloak 26.x default): JGroups uses your **CNPG Postgres** to discover Keycloak nodes. No extra cache operator required. |
| Scheduling | Pod anti-affinity or topology spread so replicas prefer different nodes |
| PodDisruptionBudget | Allow one disruption during node maintenance |
| CNPG | Already 3-instance; verify sync replication healthy |
| Edge | Round-robin on `gateway-public` is fine once embedded cache is active; sticky sessions are optional, not required for correctness |

See **Distributed cache** below for what not to deploy.

### Application database (separate from Keycloak)

Create `iac/kustomize/acruet-cnpg/` mirroring `keycloak-cnpg` / `plex-cnpg`:

| Setting | a-cruet value |
|---------|---------------|
| Namespace | `acruet-cnpg` |
| Cluster name | `acruet-db` |
| Instances | 3 |
| Storage | 20Gi per instance, `csi-rbd-sc` |
| Postgres image | `ghcr.io/cloudnative-pg/postgresql:17.6-standard-trixie` (match other clusters) |

- Dedicated `Cluster` + `Database` for a-cruet data (applications, ledger ciphertext, audit)
- App connects via CNPG-generated Secret (`acruet-db-app`)
- Schema migrations run from app Job or init container

### Verify

```bash
# Keycloak: delete one Keycloak pod — login still works
kubectl -n keycloak delete pod -l app=keycloak --wait=false

# CNPG: primary failover drill (optional, maintenance window)
# cnpg kubectl cordons / switchover documentation

# App: data persists across app pod restart
```

---

## Phase 7 — Observability, backup, optional extras

**Goal:** Operable IdP, not a black box.

### Monitoring

| Target | Approach |
|--------|----------|
| CNPG | Prometheus metrics (CNPG exporter annotations — same pattern as `plex-cnpg`) |
| Keycloak | Keycloak metrics endpoint + ServiceMonitor if operator exposes it; Grafana dashboard |
| Edge | kgateway / prometheus stack |

### Backup

| Component | Method |
|-----------|--------|
| Postgres | CNPG `Backup` CR to object storage **or** scheduled `pg_dump` Job — pick one and test restore |
| Keycloak realm config | Export realm JSON to Git (non-secret config) + document manual export for secrets |

### Optional extras

- Social IdP (Google, GitHub) as identity brokering
- MFA (TOTP / WebAuthn) for admin and/or users
- Custom login theme
- Register Keycloak on wise-home-index (internal link only if admin is internal)

---

## Phase 8 — End-to-end verification

| Check | Expected |
|-------|----------|
| `kubectl -n keycloak-cnpg get cluster` | Healthy, 3 instances |
| `kubectl -n keycloak get keycloak` | Ready, 2+ replicas |
| `https://auth.home.bradandmarsha.com/realms/<realm>/.well-known/openid-configuration` | Valid JSON, correct issuer |
| New app login E2E | a-cruet user + admin OIDC flows — see `a-cruet/ROLLOUT.md` Phase 12 |
| Keycloak pod deleted | Login still succeeds |
| CNPG primary failover (optional drill) | Keycloak reconnects; no data loss |
| Flux | `keycloak-cnpg`, `keycloak-operator`, `keycloak` Kustomizations **Ready** |
| README todo | Remove “Add keycloak for idp” when complete |

---

## Suggested repo changes

| File / area | Change |
|-------------|--------|
| `iac/kustomize/keycloak-cnpg/` | CNPG Cluster + Database for Keycloak |
| `iac/kustomize/keycloak-operator/` | Operator install (base version pin + overlay) |
| `iac/kustomize/keycloak/` | Keycloak CR, HTTPRoute, namespace |
| `iac/kustomize/fluxcd/kustomizations/keycloak*.yaml` | Flux wiring |
| `iac/kustomize/acruet/` | a-cruet user + admin Tomcat deployments, HTTPRoutes, SOPS secrets |
| `iac/kustomize/acruet-cnpg/` | CNPG cluster for a-cruet |
| `iac/kustomize/keycloak/base/oidc-client-acruet*.yaml` | Phase 5 Keycloak clients |
| `README.md` | Remove “Add keycloak for idp” when Phase 8 passes; remove To Do #2 when Phase 5.1 passes |

---

## Rollout order (safe sequence)

1. Phase 0 decisions
2. Phase 1 CNPG (Keycloak DB only)
3. Phase 2 Keycloak internal (single replica)
4. Phase 3 public HTTPS (`HTTPRoute` → `gateway-public`)
5. Phase 4 realm + admin hardening
6. a-cruet ROLLOUT Phases 1–3 (scaffold + `acruet-cnpg` + platform deploy) — see `a-cruet/ROLLOUT.md`
7. Phase 5 OIDC clients + a-cruet OIDC integration
8. Phase 5.1 GitOps leftover client / console config (can overlap Phase 6)
9. Phase 6 HA scale (Keycloak + `acruet-cnpg` already 3-instance)
10. Phase 7–8 ops + verification

**Do not** expose Keycloak publicly before hostname/TLS/proxy settings are correct — misconfigured `frontendUrl` causes redirect loops.

---

## Risks and gotchas

- **Hostname mismatch** — Keycloak `hostname`, HTTPRoute hostname, and OIDC issuer must agree.
- **Shared DB anti-pattern** — Never put Keycloak and app tables in one database; separate CNPG clusters.
- **Admin on public internet** — High-value target; restrict or MFA early.
- **Session stickiness** — With a single replica, proxy stickiness masks missing cache config. With 2+ replicas you need **embedded Infinispan + jdbc-ping** (operator default when Postgres is configured); otherwise logins break across pods.
- **Resource pressure** — Keycloak + 2× CNPG clusters on 3 nodes; watch memory during JVM warmup.
- **Confusion with AWS OIDC** — `oidc.home.bradandmarsha.com` is for IAM/IRSA, not user login.

---

## Distributed cache (recommendation)

For **wise-k8s single-cluster** Keycloak HA, use what Keycloak 26.x and the Keycloak Operator expect by default:

### Use: embedded Infinispan + `jdbc-ping`

| Piece | What it is |
|-------|------------|
| **Embedded Infinispan** | In-memory distributed cache **inside each Keycloak pod** (sessions, login failures, action tokens, etc.) |
| **`jdbc-ping` transport** | Default cluster-discovery stack; uses the **same Postgres CNPG cluster** as Keycloak’s database to register cluster members |
| **Keycloak Operator** | Set `spec.instances: 2+`; operator wires production cache mode (not `start-dev` / local-only cache) |

You already planned CNPG for Keycloak — that database serves **two roles**: application data **and** JGroups node discovery for cache clustering.

**Do not set** `cache-stack: kubernetes` (deprecated). Leave `cache-stack` unset so `jdbc-ping` is used.

### Do not deploy (for this homelab)

| Option | When it applies |
|--------|-----------------|
| **External Infinispan / Data Grid Operator** | Multi-site / cross-DC Keycloak ([Keycloak HA multi-cluster guides](https://www.keycloak.org/high-availability/multi-cluster/deploy-infinispan-kubernetes-crossdc)). Keycloak upstream treats this as complexity reserved for that scenario. |
| **Redis / Memcached** | Not Keycloak’s session cache model |
| **HTTPRoute session affinity alone** | Workaround at best; does not replace distributed cache for 2+ replicas |

### Verify cache clustering (Phase 6)

```bash
# All Keycloak pods Ready
kubectl -n keycloak get pods -l app=keycloak

# Logs should show JGroups / Infinispan cluster formation (wording varies by version)
kubectl -n keycloak logs -l app=keycloak --tail=50 | grep -iE 'cluster|jgroups|infinispan'

# Functional test: login, delete one Keycloak pod, complete another request (refresh token / new login step)
kubectl -n keycloak delete pod -l app=keycloak --wait=false
```

### When you would revisit external Infinispan

- Second Kubernetes cluster with Keycloak in both (true multi-site)
- Zero-downtime rolling upgrades that require isolating cache versions (advanced; not homelab Phase 6)

---

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| **Keycloak** (chosen) | Full IdP, OIDC/SAML, large ecosystem | Heavy, operational learning curve |
| **Authentik** | Modern UI, lighter feel | Smaller ecosystem than Keycloak |
| **Zitadel** | Cloud-native, good OIDC | Different operational model |
| **oauth2-proxy only** | Simple for one app | Not a full IdP; poor multi-app story |
| **Managed (Auth0, Cognito)** | Less ops | Off-homelab, cost, data residency |

---

## References

- [Keycloak Operator](https://www.keycloak.org/operator/installation)
- [Keycloak caching / distributed caches](https://www.keycloak.org/server/caching)
- [Keycloak HA — single cluster (operator)](https://www.keycloak.org/high-availability/single-cluster/deploy-keycloak)
- [CloudNativePG docs](https://cloudnative-pg.io/documentation/current/)
- Existing patterns: `iac/kustomize/plex-cnpg/`, `iac/kustomize/plex/base/httproute.yaml`, `docs/GATEWAY_API_ROLLOUT.md`
- [OIDC spec](https://openid.net/specs/openid-connect-core-1_0.html)
- Homelab long-horizon workflow: `LONG_HORIZON.md` (if present)
- a-cruet app rollout: `../a-cruet/ROLLOUT.md`
