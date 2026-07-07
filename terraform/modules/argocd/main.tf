locals {
  admin_password_ssm_path  = "/${var.name}/argocd/admin-password-hash"
  viewer_password_ssm_path = "/${var.name}/argocd/viewer-password-hash"
}

# Created manually, same as wg-easy's — Terraform only reads it.
data "aws_ssm_parameter" "admin_password_hash" {
  name            = local.admin_password_ssm_path
  with_decryption = true
}

# Same pattern as admin — bcrypt hash generated locally, stored in SSM by
# hand, Terraform only reads it. Backs the read-only "viewer" local account
# (RBAC role granted in the policy layer, not here — see variables.tf).
data "aws_ssm_parameter" "viewer_password_hash" {
  name            = local.viewer_password_ssm_path
  with_decryption = true
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = "argocd"
  version    = var.argocd_version

  create_namespace = true

  # policy.csv specifically has to go through `values` (real YAML), not
  # `set` — confirmed via a real apply failure: Helm's `--set` syntax reads
  # unescaped commas in a value as separators between *additional*
  # key=value pairs, and this CSV-formatted policy is full of them
  # ("Failed parsing key ' role:chess-prod-viewer' has no value" — the
  # comma after "role:chess-prod-viewer" split what should've been one
  # value into fragments). `values` has no such parsing, since it's a plain
  # YAML string, not Helm's CLI-flag-style mini-syntax.
  #
  # role:<name>-viewer gets read-only "applications, get" on every
  # AppProject this instance owns — root (defined above) plus one entry
  # per var.app_projects key (apps-dev/apps-staging on shared, apps on
  # prod) — then the final `g` line is what actually grants this role to
  # the viewer account; without it the role would exist but nobody would
  # hold it.
  values = [
    <<-YAML
      configs:
        rbac:
          policy.csv: |
            p, role:${var.name}-viewer, applications, get, ${var.name}-root/*, allow
            %{~ for key in keys(var.app_projects) ~}
            p, role:${var.name}-viewer, applications, get, ${var.name}-${key}/*, allow
            %{~ endfor ~}
            g, viewer, role:${var.name}-viewer
    YAML
  ]

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
        # Declares the account and its capabilities (argocd-cm) — not a
        # secret itself, the password lives separately below in
        # set_sensitive. "login" is enough for UI/password auth; no "apiKey"
        # since this account has no CLI/API-token use case.
        name  = "configs.cm.accounts\\.viewer"
        value = "login"
      },
      {
        # Explicit "no default role" — any account without its own `g` line
        # above (e.g. a new account added later and forgotten in policy.csv)
        # gets zero access, rather than depending on the chart's own default
        # staying empty.
        name  = "configs.rbac.policy\\.default"
        value = ""
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

  # Both password values happen to already be redacted in plan/console output
  # via the SSM data source's own sensitivity marking (SecureString), but
  # set_sensitive forces that regardless of where the value came from — it
  # stays hidden even if a source is ever swapped for something not
  # inherently marked sensitive (e.g. a plain variable).
  set_sensitive = [
    {
      name  = "configs.secret.argocdServerAdminPassword"
      value = data.aws_ssm_parameter.admin_password_hash.value
    },
    {
      name  = "configs.secret.extra.accounts\\.viewer\\.password"
      value = data.aws_ssm_parameter.viewer_password_hash.value
    }
  ]
}

# Scopes root_app itself — its only allowed destination is the argocd
# namespace, where it creates ApplicationSet objects. Kept separate from the
# apps projects below: root_app's job (create ApplicationSets) is a
# different privilege than what those ApplicationSets generate (deploy
# chess-chart into app namespaces).
resource "kubectl_manifest" "app_project_root" {
  depends_on = [helm_release.argocd]

  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: AppProject
    metadata:
      name: ${var.name}-root
      namespace: argocd
    spec:
      sourceRepos:
        - ${var.repo_url}
      destinations:
        - server: https://kubernetes.default.svc
          namespace: argocd
  YAML
}

# One AppProject per var.app_projects entry — scopes the chess-chart
# Applications each bucket's ApplicationSet generates. Split per namespace on
# shared (apps-dev / apps-staging) so a bug in the auto-syncing dev bucket's
# generator can't land an Application in staging: staging isn't in
# apps-dev's destinations, so ArgoCD rejects the sync outright rather than
# silently applying it.
resource "kubectl_manifest" "app_project_apps" {
  for_each   = var.app_projects
  depends_on = [helm_release.argocd]

  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: AppProject
    metadata:
      name: ${var.name}-${each.key}
      namespace: argocd
    spec:
      sourceRepos:
        - ${var.repo_url}
      destinations:
      %{~ for ns in each.value ~}
        - server: https://kubernetes.default.svc
          namespace: ${ns}
      %{~ endfor ~}
      # Applications in this project sync with CreateNamespace=true — without
      # this whitelist entry, ArgoCD refuses the PreSync Namespace create with
      # "resource :Namespace is not permitted in project", but only on a
      # namespace that doesn't already exist yet. Never surfaced on prod
      # because its target namespaces were created out-of-band before ArgoCD
      # ever synced into them; shared's dev/staging were not.
      clusterResourceWhitelist:
        - group: ""
          kind: Namespace
  YAML
}

# Root "app of apps" — the only ArgoCD object Terraform still owns directly.
# It watches a folder of hand-written ApplicationSet YAML in git
# (helm/git-ops/<instance>/, no Terraform templating involved) and lets
# ArgoCD's own applicationset-controller take it from there. See
# helm/git-ops/{shared,prod}/*.yaml for the actual bucket definitions.
resource "kubectl_manifest" "root_app" {
  # app_project_root must exist before root_app, since root_app's own
  # spec.project references it directly. app_project_apps isn't a hard
  # Terraform-level dependency (only the git-committed ApplicationSet YAML
  # references those, applied later by ArgoCD's own controller, not by this
  # resource) — included anyway so a fresh `apply` brings up the whole
  # topology in one pass instead of leaving transient "project does not
  # exist" errors for ArgoCD to retry past.
  depends_on = [helm_release.argocd, kubectl_manifest.app_project_root, kubectl_manifest.app_project_apps]

  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: chess-gitops-root
      namespace: argocd
    spec:
      project: "${var.name}-root"
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
