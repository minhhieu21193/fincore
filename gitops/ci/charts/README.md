# Vendored chart archives (CI rendering only)

public.ecr.aws rate-limits anonymous pulls by data volume per source IP, and shared
GitHub runners regularly hit it (`429 toomanyrequests: Data limit exceeded`).
Charts published only there are vendored here so `scripts/render.sh` (kubeconform)
is deterministic. Argo CD still pulls from the registry; nothing here is deployed.

Each archive is byte-identical to the published chart: its sha256 equals the chart
layer digest of the OCI manifest. `render.sh` refuses an archive whose checksum is
not in `SHA256SUMS`.

When bumping a vendored chart version in `gitops/bootstrap/app-of-apps/values.yaml`:

```sh
helm pull oci://public.ecr.aws/karpenter/karpenter --version <v> -d gitops/ci/charts
tok=$(curl -s "https://public.ecr.aws/token/?scope=repository:karpenter/karpenter:pull" | jq -r .token)
curl -s -H "Authorization: Bearer $tok" -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  https://public.ecr.aws/v2/karpenter/karpenter/manifests/<v> | jq -r '.layers[0].digest'
shasum -a 256 gitops/ci/charts/karpenter-<v>.tgz   # must match, then update SHA256SUMS
```
