# Infraestrutura ToggleMaster — O que o Terraform provisiona

> Conta AWS: `603727984890` | Região: `us-east-1`  
> Executar: `terraform init && terraform apply -auto-approve`

---

## Visão Geral

```
                          ┌─────────────────────────────────────┐
                          │           VPC (10.0.0.0/16)         │
                          │                                     │
        Internet ────►    │  Public Subnets                     │
                          │  ├── 10.0.1.0/24 (us-east-1a)      │
                          │  └── 10.0.2.0/24 (us-east-1b)      │
                          │           │                         │
                          │       NAT Gateway (único)           │
                          │           │                         │
                          │  Private Subnets                    │
                          │  ├── 10.0.3.0/24 (us-east-1a)      │
                          │  └── 10.0.4.0/24 (us-east-1b)      │
                          │     │         │         │           │
                          │    EKS       RDS      Redis         │
                          └─────────────────────────────────────┘
```

---

## 1. Rede (vpc.tf)

| Recurso | Detalhe |
|---|---|
| VPC | CIDR `10.0.0.0/16` |
| Subnets públicas | 2x (us-east-1a, us-east-1b) — Load Balancers |
| Subnets privadas | 2x (us-east-1a, us-east-1b) — EKS nodes, RDS, Redis |
| NAT Gateway | 1 único (economiza custo vs. um por AZ) |
| Internet Gateway | 1 |

---

## 2. Kubernetes — EKS (eks.tf)

| Recurso | Detalhe |
|---|---|
| Cluster EKS | `togglemaster` — Kubernetes **1.36** |
| Node Group | `workers` — EC2 `t3.medium` |
| Escalabilidade | Min: 1 / Desejado: 2 / Max: 3 nós |
| Disco por nó | 20 GB gp2 |
| Endpoint | Público (kubectl funciona de qualquer máquina) |
| IAM | Roles criadas automaticamente pelo módulo EKS |

---

## 3. Bancos de Dados Relacionais — RDS (rds.tf)

3 instâncias **independentes** PostgreSQL 15, cada uma para um microsserviço:

| Instância | Banco | Serviço |
|---|---|---|
| `togglemaster-auth-pg` | `auth_db` | auth-service |
| `togglemaster-flags-pg` | `flags_db` | flag-service |
| `togglemaster-targeting-pg` | `targeting_db` | targeting-service |

Configuração de cada instância:
- Tipo: `db.t3.micro`
- Storage: 20 GB gp2
- Single-AZ (sem Multi-AZ para economizar)
- Sem backup automático (`backup_retention_period = 0`)
- Acesso restrito ao Security Group dos nós do EKS

---

## 4. Cache — ElastiCache Redis (elasticache.tf)

| Recurso | Detalhe |
|---|---|
| Cluster | `togglemaster-redis` |
| Engine | Redis 7 |
| Tipo | `cache.t3.micro` |
| Nós | 1 (sem cluster mode) |
| Porta | 6379 |
| Acesso | Restrito ao SG dos nós EKS |
| Uso | evaluation-service — cache de decisões de flags |

---

## 5. Mensageria (messaging.tf)

### SQS
| Recurso | Detalhe |
|---|---|
| Fila | `togglemaster-events` (Standard) |
| Retenção | 1 dia (86400s) |
| Visibility timeout | 30s |
| Produtores | evaluation-service |
| Consumidores | analytics-service |

### DynamoDB
| Recurso | Detalhe |
|---|---|
| Tabela | `analytics-events` |
| Billing | PAY_PER_REQUEST (zero custo fixo) |
| Chave primária | `event_id` (String) |
| TTL | `expires_at` (limpeza automática) |
| Uso | analytics-service persiste eventos de avaliação |

---

## 6. Segredos — AWS Secrets Manager (iam-eso.tf)

Senhas geradas automaticamente pelo Terraform (`random_password`). Nunca expostas no terminal nem em arquivos.

| Secret | Conteúdo |
|---|---|
| `togglemaster/auth-service` | `DATABASE_URL`, `MASTER_KEY` |
| `togglemaster/flag-service` | `DATABASE_URL` |
| `togglemaster/targeting-service` | `DATABASE_URL` |
| `togglemaster/evaluation-service` | `REDIS_URL`, `SERVICE_API_KEY`, `AWS_SQS_URL` |
| `togglemaster/analytics-service` | `AWS_SQS_URL` |

---

## 7. IAM — Roles e Políticas

### IRSA para External Secrets Operator (iam-eso.tf)
- Role: `togglemaster-eso-role`
- Permissão: `secretsmanager:GetSecretValue` nos secrets `togglemaster/*`
- Assumida por: SA `external-secrets` no namespace `external-secrets`

### IRSA para KEDA (iam-keda.tf)
- Role: `togglemaster-keda-role`
- Permissão: `sqs:GetQueueAttributes`, `sqs:GetQueueUrl` na fila `togglemaster-events`
- Assumida por: SA `keda-operator` no namespace `keda`

### Policy nos nós EKS (iam-keda.tf)
Permite que os pods acessem AWS sem credenciais hardcoded:
- SQS: `SendMessage`, `ReceiveMessage`, `DeleteMessage`
- DynamoDB: `PutItem`, `GetItem`, `Query`, `Scan`
- ECR: pull das imagens `togglemaster/*`

---

## 8. Helm — Addons do Cluster (helm-addons.tf)

| Chart | Namespace | Versão | Função |
|---|---|---|---|
| `metrics-server` | `kube-system` | 3.12.1 | Métricas de CPU/memória (necessário para HPA) |
| `ingress-nginx` | `ingress-nginx` | 4.10.1 | Load Balancer externo + roteamento HTTP |
| `external-secrets` | `external-secrets` | 0.9.19 | Sincroniza secrets do AWS SM para K8s |
| `keda` | `keda` | 2.14.0 | Autoscaling baseado em profundidade da fila SQS |

---

## 9. Kubernetes — Aplicação (k8s-app.tf)

Aplicado via `kubectl_manifest` — reusa os YAMLs em `k8s/`.

### Namespace
- `togglemaster`

### External Secrets (ESO)
- `ClusterSecretStore` → aponta para AWS Secrets Manager
- 5x `ExternalSecret` → um por serviço, `refreshInterval: "0"` (busca única, sem polling)

### Por microsserviço (×5)
- `ConfigMap` — variáveis não-sensíveis (URLs internas, portas, região)
- `Deployment` — imagem do ECR, 2 réplicas, resources/limits, readiness + liveness probes
- `Service` — ClusterIP

### Ingress (Nginx)
| Path | Serviço | Porta |
|---|---|---|
| `/auth` | auth-service | 8001 |
| `/flags` | flag-service | 8002 |
| `/rules` | targeting-service | 8003 |
| `/evaluate` | evaluation-service | 8004 |

### Escalabilidade
| Recurso | Serviço | Gatilho |
|---|---|---|
| HPA | evaluation-service | CPU > 70% → escala até 5 réplicas |
| KEDA ScaledObject | analytics-service | Fila SQS > 5 mensagens → escala 0→5 réplicas |
| KEDA TriggerAuthentication | analytics-service | IRSA (sem credenciais AWS no cluster) |

---

## Ordem de criação (dependency graph simplificado)

```
random_password
    └── RDS × 3
    └── Secrets Manager × 5
            └── (ESO sincroniza → K8s Secrets)

VPC
 └── EKS (cluster + node group + IAM roles)
 └── RDS × 3 (subnet group + security group)
 └── ElastiCache (subnet group + security group)
      └── Helm: metrics-server
      └── Helm: ingress-nginx
      └── Helm: external-secrets  ←── IRSA (eso_irsa)
      └── Helm: keda              ←── IRSA (keda_irsa)
               └── K8s: Namespace
               └── K8s: ClusterSecretStore + ExternalSecrets
               └── K8s: ConfigMaps + Deployments + Services
               └── K8s: Ingress + HPA
               └── K8s: KEDA TriggerAuth + ScaledObject

SQS ──────────────────────────────────────────────────────┘
DynamoDB ─────────────────────────────────────────────────┘
```

---

## Outputs após o apply

| Output | Descrição |
|---|---|
| `eks_cluster_name` | Nome do cluster (`togglemaster`) |
| `eks_cluster_endpoint` | URL da API do EKS |
| `rds_auth_endpoint` | Host:porta do RDS do auth-service |
| `rds_flags_endpoint` | Host:porta do RDS do flag-service |
| `rds_targeting_endpoint` | Host:porta do RDS do targeting-service |
| `redis_host` | Host do ElastiCache |
| `sqs_url` | URL da fila SQS |
| `dynamodb_table` | Nome da tabela DynamoDB |
| `kubectl_config_cmd` | Comando para configurar o kubectl |
| `keda_role_arn` | ARN da role IRSA do KEDA |
| `eso_role_arn` | ARN da role IRSA do ESO |

---

## Custo estimado (us-east-1)

| Serviço | Tipo | /hora | /dia | /mês |
|---|---|---|---|---|
| EKS Control Plane | — | ~$0,10 | ~$2,40 | ~$73 |
| EC2 Nodes | 2× t3.medium | ~$0,08 | ~$2,00 | ~$60 |
| RDS | 3× db.t3.micro | ~$0,06 | ~$1,50 | ~$45 |
| ElastiCache | cache.t3.micro | ~$0,02 | ~$0,40 | ~$12 |
| NAT Gateway | 1× | ~$0,04 | ~$1,05 | ~$32 |
| SQS | PAY_PER_REQUEST | ~$0 | ~$0 | ~$0 (lab) |
| DynamoDB | PAY_PER_REQUEST | ~$0 | ~$0 | ~$0 (lab) |
| Secrets Manager | 5 secrets | ~$0 | ~$0,08 | ~$2,50 |
| **Total estimado** | | **~$0,30/h** | **~$7,43/dia** | **~$225/mês** |

> Destrua com `terraform destroy` após a entrega para evitar cobranças.
