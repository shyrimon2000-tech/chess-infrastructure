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

locals {
  # Split by sync mode instead of a Go-template {{if}} inside the YAML: a bare,
  # unquoted `{{- if .automated }}` spanning multiple keys isn't valid standalone
  # YAML (kubectl_manifest parses yaml_body client-side before ArgoCD ever sees
  # it, and strict YAML forbids a plain scalar starting with `{`). automated is
  # already known at terraform-apply-time (var.environments is static), so the
  # split happens here instead of at ArgoCD's runtime templating.
  automated_environments = [for env in var.environments : env if env.automated]
  manual_environments    = [for env in var.environments : env if !env.automated]
}

resource "kubectl_manifest" "chess_chart_applicationset_automated" {
  count      = length(local.automated_environments) > 0 ? 1 : 0
  depends_on = [helm_release.argocd]

  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: ApplicationSet
    metadata:
      name: chess-chart-automated
      namespace: argocd
    spec:
      goTemplate: true
      goTemplateOptions: ["missingkey=error"]
      generators:
        - list:
            elements:
    %{~for env in local.automated_environments~}
            - env: ${env.name}
              namespace: ${env.namespace}
              valuesFile: ${env.values_file}
              targetRevision: ${env.target_revision}
    %{~endfor~}
      template:
        metadata:
          name: 'chess-chart-{{.env}}'
        spec:
          project: default
          source:
            repoURL: ${var.repo_url}
            targetRevision: '{{.targetRevision}}'
            path: helm/chess-chart
            helm:
              valueFiles:
                - '{{.valuesFile}}'
          destination:
            server: https://kubernetes.default.svc
            namespace: '{{.namespace}}'
          syncPolicy:
            # Literal booleans, not `{{ .prune }}` — the ApplicationSet CRD types
            # this field strictly as boolean, and a Go-template placeholder is
            # necessarily a string until ArgoCD renders it, which happens *after*
            # kube-apiserver already rejected the raw object for the type
            # mismatch. Quoting doesn't help (valid YAML, still a string) and
            # there's no way to make an unrendered placeholder satisfy a strict
            # boolean schema. Since these are already known at terraform-apply
            # time, hardcode them here instead of templating at ArgoCD's
            # runtime — every environment in this ApplicationSet shares the same
            # values (only "dev" is automated right now; if a second automated
            # environment ever needs a *different* prune/selfHeal, it needs its
            # own ApplicationSet, same pattern as the automated/manual split).
            automated:
              prune: ${local.automated_environments[0].prune}
              selfHeal: ${local.automated_environments[0].self_heal}
            syncOptions:
              - CreateNamespace=true
  YAML
}

resource "kubectl_manifest" "chess_chart_applicationset_manual" {
  count      = length(local.manual_environments) > 0 ? 1 : 0
  depends_on = [helm_release.argocd]

  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: ApplicationSet
    metadata:
      name: chess-chart-manual
      namespace: argocd
    spec:
      goTemplate: true
      goTemplateOptions: ["missingkey=error"]
      generators:
        - list:
            elements:
    %{~for env in local.manual_environments~}
            - env: ${env.name}
              namespace: ${env.namespace}
              valuesFile: ${env.values_file}
              targetRevision: ${env.target_revision}
    %{~endfor~}
      template:
        metadata:
          name: 'chess-chart-{{.env}}'
        spec:
          project: default
          source:
            repoURL: ${var.repo_url}
            targetRevision: '{{.targetRevision}}'
            path: helm/chess-chart
            helm:
              valueFiles:
                - '{{.valuesFile}}'
          destination:
            server: https://kubernetes.default.svc
            namespace: '{{.namespace}}'
          syncPolicy:
            syncOptions:
              - CreateNamespace=true
  YAML
}
