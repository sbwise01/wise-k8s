# kube-promethus-stack

This kustomization was generated from a Helm chart by doing the following:

1. Create `kustomization.yaml` with the following contents:
   ```
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization

   namespace: monitoring

   helmCharts:
    - name: kube-prometheus-stack
      repo: https://prometheus-community.github.io/helm-charts
      releaseName: prometheus-stack
      version: 86.1.0
      valuesFile: release.yaml
      namespace: monitoring
      includeCRDs: true
   ```
2. Create `release.yaml` with the following contents:
   ```
   prometheus:
     prometheusSpec:
       retention: 14d

   grafana:
      ingress:
        enabled: true
        hosts:
          - grafana-dashboard
        tls: []

   prometheus:
      prometheusSpec:
        resources:
          requests:
            cpu: 100m
            memory: 512Mi
        storageSpec:
          volumeClaimTemplate:
            spec:
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 20Gi
              storageClassName: csi-rbd-sc
              volumeMode: Filesystem

   ```
3. Run kustomize build to generate yaml manifests
   ```
   kustomize build --enable-helm . > deployment.yaml
   ```
4. Cleanup `kustomization.yaml`, `release.yaml`, and generated `charts` directory
5. Create base and overlays
