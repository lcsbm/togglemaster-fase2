# ToggleMaster — Fase 2

Plataforma de **feature flags** como microsserviços em Kubernetes (EKS) na AWS.

> **Tech Challenge — Fase 2 | FIAP Pós-Graduação DevOps e Arquitetura Cloud**  
> Aluno: Lucas Santana Bezerra de Melo | RM: 373161 | Discord: s4ntz_

---

## Arquitetura

5 microsserviços independentes + backing services:

| Serviço | Linguagem | Porta | Banco |
|---|---|---|---|
| auth-service | Go | 8001 | RDS PostgreSQL (auth_db) |
| flag-service | Python | 8002 | RDS PostgreSQL (flags_db) |
| targeting-service | Python | 8003 | RDS PostgreSQL (targeting_db) |
| evaluation-service | Go | 8004 | ElastiCache Redis |
| analytics-service | Python | 8005 | SQS + DynamoDB |

**Escalabilidade:**
- `evaluation-service` → HPA (CPU > 70%, até 5 réplicas)
- `analytics-service` → KEDA (profundidade da fila SQS, escala 0 → 5 réplicas)

---

## Estrutura do Repositório

```
.
├── auth-service/           # Go — autenticação e chaves de API
├── flag-service/           # Python — CRUD de feature flags
├── targeting-service/      # Python — regras de segmentação
├── evaluation-service/     # Go — hot path de avaliação
├── analytics-service/      # Python — consumidor SQS → DynamoDB
├── docker-compose.yml      # Ambiente local completo (9 containers)
├── infra/
│   ├── init-auth-db.sh     # Seed do banco auth (chave dev pré-registrada)
│   ├── init-flags-db.sh    # Criação dos bancos flags_db e targeting_db
│   ├── init-localstack.sh  # Cria fila SQS e tabela DynamoDB no LocalStack
│   └── terraform/          # IaC completo — 1 apply provisiona tudo
└── k8s/                    # Manifestos Kubernetes
    ├── namespaces.yaml
    ├── ingress.yaml
    ├── external-secrets/   # ClusterSecretStore (ESO → Secrets Manager)
    ├── keda/               # TriggerAuthentication
    └── <serviço>/          # deployment, service, configmap, external-secret, hpa/keda
```

---

## Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/) e docker-compose
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [AWS CLI](https://aws.amazon.com/cli/) configurado (`aws configure`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/) >= 3

---

## Rodando Localmente

```bash
# Sobe 9 containers: 5 apps + 2 PostgreSQL + Redis + LocalStack
docker-compose up --build -d

# Verifica status (todos devem estar healthy)
docker ps --format "table {{.Names}}\t{{.Status}}"

# Health checks
for p in 8001 8002 8003 8004 8005; do
  echo "--- :$p ---" && curl -s http://localhost:$p/health
done
```

### Fluxo de teste local

```bash
# 1. Criar chave de API
curl -s -X POST http://localhost:8001/admin/keys \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer master_dev_key_local" \
  -d '{"name": "minha-chave"}'
# Guarde o valor de "key" retornado

# 2. Criar feature flag
API_KEY="tm_key_..."  # cole a chave gerada
curl -s -X POST http://localhost:8002/flags \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"name": "novo-checkout", "description": "Novo checkout", "is_enabled": true}'

# 3. Avaliar flag
curl -s "http://localhost:8004/evaluate?user_id=user-123&flag_name=novo-checkout"
# → {"flag_name":"novo-checkout","user_id":"user-123","result":true}

# 4. Ver eventos no DynamoDB (LocalStack)
docker exec localstack awslocal dynamodb scan \
  --table-name analytics-events --region us-east-1
```

---

## Deploy na AWS (Terraform)

```bash
cd infra/terraform

# Inicializa providers
terraform init

# Revise o plano (sem custo)
terraform plan

# Provisiona tudo: VPC, EKS, RDS×3, ElastiCache, SQS, DynamoDB,
# Secrets Manager, IRSA, Helm addons (Nginx, ESO, KEDA, Metrics Server),
# e todos os manifestos K8s
terraform apply -auto-approve

# Configura o kubectl
aws eks update-kubeconfig --region us-east-1 --name togglemaster

# Verifica os pods
kubectl get pods -n togglemaster
```

> **Custo estimado:** ~$0,30/hora (~$7,43/dia). Execute `terraform destroy` após a entrega.

---

## Segredos — o que NÃO está no repositório

| Arquivo | Motivo |
|---|---|
| `terraform.tfstate` | Contém senhas geradas automaticamente |
| `.terraform/` | Binários dos providers (~500 MB) |
| `terraform.tfvars` | Variáveis com valores reais |
| `secrets.sh` | Qualquer script com credenciais |

As senhas são geradas automaticamente pelo `random_password` do Terraform e armazenadas no **AWS Secrets Manager**. O cluster acessa os segredos via **External Secrets Operator + IRSA** — sem credenciais hardcoded.

---

## Infraestrutura AWS

Detalhes completos em [`infra/terraform/INFRA.md`](infra/terraform/INFRA.md).

| Recurso | Configuração |
|---|---|
| EKS | Kubernetes 1.36 — t3.medium (min 1 / max 3 nós) |
| ECR | 5 repositórios (um por serviço) |
| RDS | 3× db.t3.micro PostgreSQL 15 |
| ElastiCache | cache.t3.micro Redis 7 |
| SQS | Standard queue `togglemaster-events` |
| DynamoDB | `analytics-events` (PAY_PER_REQUEST) |
| Secrets Manager | 5 secrets — um por serviço |
