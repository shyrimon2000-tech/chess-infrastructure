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
      }
    ] : []
  )
}

resource "kubectl_manifest" "chess_chart_applicationset" {
  depends_on = [helm_release.argocd]

  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: ApplicationSet
    metadata:
      name: chess-chart
      namespace: argocd
    spec:
      goTemplate: true
      goTemplateOptions: ["missingkey=error"]
      generators:
        - list:
            elements:
    %{ for env in var.environments ~}
              - env: ${env.name}
                namespace: ${env.namespace}
                valuesFile: ${env.values_file}
                targetRevision: ${env.target_revision}
                automated: ${env.automated}
                prune: ${env.prune}
                selfHeal: ${env.self_heal}
    %{ endfor ~}
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
            {{- if .automated }}
            automated:
              prune: {{ .prune }}
              selfHeal: {{ .selfHeal }}
            {{- end }}
            syncOptions:
              - CreateNamespace=true
  YAML
}
