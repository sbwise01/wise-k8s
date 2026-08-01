# wise-k8s

## Description

Repository to house manifests and applications hosted in the wise-k8s homelab

## To Do list

1. Replace Ingress' with Gateway API
2. Add keycloak for idp
3. **Keycloak a-cruet manual client config follow-up** — Phase 4 required console steps not yet GitOps'd: `keycloak-admin` operator secret (`master` service account), `acruet` client scopes (`roles` default + `a-cruet-admin` in dedicated scope for access-token role claims), `acruet` valid post-logout redirect URIs (host roots `/` for user + admin — not covered by `redirectUris` or `+`), `acruet-admin` `realm-management` service-account roles. Evaluate `KeycloakOIDCClient` CR gaps, realm import, or operator API v2 improvements when Client Admin API matures.
4. Add actions runner controller scale set controller to cluster
5. migrate ci workflows and cd workflows to use cluster runners
6. replace custom cronjobs with generalized reflector impelementation
