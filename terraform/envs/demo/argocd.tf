# GitOps bootstrap: install Argo CD and the root app-of-apps. Everything else
# in the cluster is reconciled by Argo CD from gitops/. Cluster facts are
# passed as values here, so no account IDs or endpoints live in git.

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.11.1"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [
    file("${path.module}/../../../gitops/bootstrap/argocd/values.yaml"),
    yamlencode({
      global = {
        nodeSelector = { "fincore.io/node-role" = "system" }
      }
    }),
  ]

  depends_on = [module.eks]
}

resource "helm_release" "root_app" {
  name       = "root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.7"
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      root = {
        namespace  = "argocd"
        project    = "default"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = "https://github.com/${var.github_repository}.git"
          targetRevision = var.gitops_revision
          path           = "gitops/bootstrap/app-of-apps"
          helm = {
            valueFiles = ["../../envs/aws/app-of-apps.yaml"]
            valuesObject = {
              repoURL        = "https://github.com/${var.github_repository}.git"
              targetRevision = var.gitops_revision
              cluster = {
                name                       = module.eks.cluster_name
                region                     = var.region
                vpcId                      = module.network.vpc_id
                domain                     = var.domain
                hostedZoneId               = data.aws_route53_zone.this.zone_id
                acmeEmail                  = var.acme_email
                karpenterNodeRole          = module.eks.karpenter_node_role_name
                karpenterInterruptionQueue = module.eks.karpenter_interruption_queue
                ecrRegistry                = module.ecr.registry
                dbHost                     = module.aurora.endpoint
                dbAdminSecretName          = module.aurora.master_user_secret_arn
                paymentEventsQueueUrl      = module.queues.queue_url
              }
            }
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]

  depends_on = [helm_release.argocd]
}
