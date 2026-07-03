locals {
  admin_password_ssm_path = "/${var.name}/argocd/admin-password-hash"
}

# Created manually, same as wg-easy's — Terraform only reads it.
data "aws_ssm_parameter" "admin_password_hash" {
  name            = local.admin_password_ssm_path
  with_decryption = true
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = "argocd"
  version    = var.argocd_version

  create_namespace = true

  set = concat(
    [
      {
        name  = "dex.enabled"
        value = "false"
      },
      {
        name  = "notifications.enabled"
        value = "false"
      },
      {
        name  = "configs.secret.argocdServerAdminPassword"
        value = data.aws_ssm_parameter.admin_password_hash.value
      }
    ],
    var.ingress_enabled ? [
      {
        name  = "server.ingress.enabled"
        value = "true"
      },
      {
        name  = "server.ingress.ingressClassName"
        value = var.ingress_class_name
      },
      {
        name  = "server.ingress.hostname"
        value = var.ingress_hostname
      },
      {
        # argocd-server's own self-signed TLS would otherwise mismatch nginx's
        # plain-HTTP proxying to the backend. Traffic is already inside the VPN
        # tunnel + private VPC network, so dropping TLS here is fine for this project.
        #
        # Bug fixed 2026-07-02: this was `name = "server.insecure"` before, which
        # Helm's --set syntax reads as nested server: {insecure: true} — but the
        # chart actually reads this setting from a *flat* key literally named
        # "server.insecure" (dot included) under configs.params, which is what
        # populates the argocd-cmd-params-cm ConfigMap argocd-server reads at
        # startup (`helm show values argo-cd --version 7.7.11` confirms the real
        # path). The old key silently set a value nothing reads, while the
        # ConfigMap stayed at its default `server.insecure: "false"` forever —
        # first misdiagnosed on shared as a stuck/interrupted helm upgrade
        # (patched the ConfigMap by hand as a workaround), then reproduced
        # identically on a completely clean, single-revision prod install,
        # which is what proved the values path itself was wrong all along.
        name  = "configs.params.server\\.insecure"
        value = "true"
      },
      {
        # Without this, ingress-nginx assumes an HTTPS-capable backend and the
        # proxy_pass to argocd-server's plain-HTTP port breaks (empty/garbled
        # response, sometimes surfaced as a redirect loop).
        name  = "server.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/backend-protocol"
        value = "HTTP"
      },
      {
        # ingress-nginx forces an HTTP->HTTPS redirect by default even when no
        # TLS is configured on the Ingress. There's no cert for this host (TLS
        # intentionally dropped, see server.insecure above) — left at the
        # default, the client gets redirected to https://, nginx serves its
        # self-signed fake cert there, and argocd-server (behind on plain
        # HTTP, believing every request is already HTTPS) redirects right
        # back — ERR_TOO_MANY_REDIRECTS.
        name  = "server.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect"
        value = "false"
      }
    ] : []
  )
}

# Root "app of apps" — the only ArgoCD object Terraform still owns directly.
# It watches a folder of hand-written ApplicationSet YAML in git
# (helm/git-ops/<instance>/, no Terraform templating involved) and lets
# ArgoCD's own applicationset-controller take it from there. See
# helm/git-ops/{shared,prod}/*.yaml for the actual bucket definitions.
resource "kubectl_manifest" "root_app" {
  depends_on = [helm_release.argocd]

  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: chess-gitops-root
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: ${var.repo_url}
        targetRevision: ${var.gitops_target_revision}
        path: helm/git-ops/${var.gitops_dir}
        directory:
          recurse: true
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        # Auto-sync + prune: this is the infra layer (which buckets exist),
        # not app deployment content — a new/changed ApplicationSet committed
        # to git should take effect without a manual `argocd app sync`, same
        # reasoning as dev's automated bucket. No selfHeal, same as
        # everywhere else in this project (see dev bucket comment in
        # helm/git-ops/shared/chess-chart-automated.yaml).
        automated:
          prune: true
          selfHeal: false
        syncOptions:
          - CreateNamespace=true
  YAML
}
