locals {
  k8s_path = "${path.root}/../../k8s"
}

# ── Namespace ─────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "togglemaster" {
  metadata {
    name = "togglemaster"
  }
  depends_on = [module.eks]
}

# ── ESO: ClusterSecretStore + ExternalSecrets ─────────────────────────────────
# O ESO lê do AWS Secrets Manager e cria os K8s Secrets automaticamente.
# Nenhum segredo é gerenciado diretamente pelo Terraform no cluster.

resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = file("${local.k8s_path}/external-secrets/cluster-secret-store.yaml")

  depends_on = [
    helm_release.external_secrets,
    kubernetes_namespace.togglemaster,
  ]
}

locals {
  external_secrets = toset([
    "${local.k8s_path}/auth-service/external-secret.yaml",
    "${local.k8s_path}/flag-service/external-secret.yaml",
    "${local.k8s_path}/targeting-service/external-secret.yaml",
    "${local.k8s_path}/evaluation-service/external-secret.yaml",
    "${local.k8s_path}/analytics-service/external-secret.yaml",
  ])
}

resource "kubectl_manifest" "external_secrets" {
  for_each  = local.external_secrets
  yaml_body = file(each.value)

  depends_on = [kubectl_manifest.cluster_secret_store]
}

# ── Manifestos estáticos (ConfigMaps, Deployments, Services, Ingress, HPA) ───

locals {
  static_manifests = toset([
    # ConfigMaps
    "${local.k8s_path}/auth-service/configmap.yaml",
    "${local.k8s_path}/flag-service/configmap.yaml",
    "${local.k8s_path}/targeting-service/configmap.yaml",
    "${local.k8s_path}/evaluation-service/configmap.yaml",
    "${local.k8s_path}/analytics-service/configmap.yaml",
    # Deployments
    "${local.k8s_path}/auth-service/deployment.yaml",
    "${local.k8s_path}/flag-service/deployment.yaml",
    "${local.k8s_path}/targeting-service/deployment.yaml",
    "${local.k8s_path}/evaluation-service/deployment.yaml",
    "${local.k8s_path}/analytics-service/deployment.yaml",
    # Services
    "${local.k8s_path}/auth-service/service.yaml",
    "${local.k8s_path}/flag-service/service.yaml",
    "${local.k8s_path}/targeting-service/service.yaml",
    "${local.k8s_path}/evaluation-service/service.yaml",
    "${local.k8s_path}/analytics-service/service.yaml",
    # Ingress
    "${local.k8s_path}/ingress.yaml",
    "${local.k8s_path}/ingress-evaluate.yaml",
    # HPA — só evaluation (analytics é gerenciado pelo KEDA)
    "${local.k8s_path}/evaluation-service/hpa.yaml",
  ])
}

resource "kubectl_manifest" "app" {
  for_each  = local.static_manifests
  yaml_body = file(each.value)

  depends_on = [
    kubernetes_namespace.togglemaster,
    kubectl_manifest.external_secrets,
    helm_release.metrics_server,
    helm_release.nginx_ingress,
  ]
}

# ── Bootstrap: registra SERVICE_API_KEY do evaluation-service no auth_db ─────
# Roda como Job K8s durante o terraform apply.
# Computa SHA-256 do SERVICE_API_KEY e insere na tabela api_keys do auth_db.
# ON CONFLICT DO NOTHING garante idempotência em re-applies.
resource "kubectl_manifest" "bootstrap_eval_key" {
  yaml_body = file("${local.k8s_path}/bootstrap/bootstrap-eval-key.yaml")

  depends_on = [
    kubectl_manifest.app,
    kubectl_manifest.external_secrets,
  ]
}

# ── KEDA: TriggerAuthentication ───────────────────────────────────────────────
resource "kubectl_manifest" "keda_triggerauth" {
  yaml_body = file("${local.k8s_path}/keda/triggerauth.yaml")

  depends_on = [
    helm_release.keda,
    kubernetes_namespace.togglemaster,
  ]
}

# ── KEDA: ScaledObject com SQS URL real injetada via templatefile ─────────────
resource "kubectl_manifest" "keda_scaledobject" {
  yaml_body = templatefile("${local.k8s_path}/analytics-service/keda-scaledobject.yaml", {
    sqs_url = aws_sqs_queue.events.url
  })

  depends_on = [
    helm_release.keda,
    kubectl_manifest.keda_triggerauth,
    kubectl_manifest.app,
  ]
}
