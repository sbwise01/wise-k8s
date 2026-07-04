# Flux image automation

Controllers (`image-reflector-controller`, `image-automation-controller`) are
installed via `flux-system/gotk-components.yaml`.

Per-app automation (not yet added):

1. Add a marker comment on the image field in the workload manifest, e.g.
   `# {"$imagepolicy": "flux-system:wise-home-index:tag"}`.
2. Add `ImageRepository`, `ImagePolicy`, and `ImageUpdateAutomation` manifests
   to this directory and list them in `kustomization.yaml`.
3. Ensure the `flux-system` git secret can **push** to `sbwise01/wise-k8s`
   (read-only deploy keys will not work for `ImageUpdateAutomation`).

See [Flux image update automation](https://fluxcd.io/flux/guides/image-update/).
