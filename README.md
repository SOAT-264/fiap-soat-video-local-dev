# fiap-soat-video-local-dev

## Introdução
Este é o repositório principal do ecossistema FIAP SOAT Video Processor. Ele orquestra a infraestrutura local, o roteamento, a observabilidade e o deploy dos microserviços para desenvolvimento integrado.

## Sumário
- Explicação do projeto
- Objetivo
- Como funciona
- Integrações com outros repositórios
- Como executar
- Como testar

## Explicação do projeto
O repositório centraliza o ambiente de desenvolvimento local com:
- `docker-compose.yml` para infraestrutura base, gateway (Traefik) e stack de observabilidade.
- Scripts de inicialização (`start.ps1`) e encerramento (`down.ps1`) do ambiente completo.
- Scripts de bootstrap do LocalStack para S3, SNS, SQS e SES (`init-scripts/localstack-init.ps1`).
- Rotas dinâmicas do Traefik para expor os serviços Kubernetes em domínios locais (`*.localhost`).

## Objetivo
Padronizar e simplificar o processo de subir, integrar e validar todos os serviços do sistema em um único fluxo de desenvolvimento local.

## Como funciona
1. O `docker compose up -d` sobe a infraestrutura local:
PostgreSQLs por domínio, Redis, LocalStack, Traefik e observabilidade (Prometheus/Grafana/Loki/Blackbox).
2. O script `localstack-init.ps1` cria e conecta recursos AWS simulados:
S3 (`video-uploads`, `video-outputs`), SNS (`video-events`, `job-events`) e SQS (`job-queue`, `notification-queue`).
3. O script `start.ps1` faz build das imagens locais dos serviços e aplica os overlays Kubernetes `local-dev` dos repositórios:
auth, jobs (api + worker), notifications (api + worker) e video-service.
4. O Traefik roteia os hosts locais para NodePorts Kubernetes:
`auth.localhost`, `jobs.localhost`, `notify.localhost`, `video.localhost`.
5. O pipeline assíncrono principal fica:
`video uploaded -> video-events (SNS) -> job-queue (SQS) -> jobs worker -> job-events (SNS) -> notification-queue (SQS) -> notifications worker`.

## Integrações com outros repositórios
| Repositório integrado | Como integra | Para que serve |
| --- | --- | --- |
| `fiap-soat-video-auth` | Build da imagem local e deploy via `kubectl apply -k .../k8s/overlays/local-dev` | Disponibilizar autenticação/identidade para os demais serviços |
| `fiap-soat-video-service` | Build e deploy, roteamento `video.localhost` e dependência de LocalStack para storage/eventos | Receber uploads de vídeo e disparar eventos de processamento |
| `fiap-soat-video-jobs` | Build e deploy da API e worker SQS/KEDA | Processar vídeos assincronamente e publicar eventos de status |
| `fiap-soat-video-notifications` | Build e deploy da API e worker SQS/KEDA | Consumir eventos de job e enviar notificações por e-mail |
| `fiap-soat-video-shared` | Copiado e instalado nos Dockerfiles dos serviços | Compartilhar contratos, eventos e value objects entre microserviços |
| `fiap-soat-video-obs` | Incluído no `docker-compose.yml` principal via `include` | Coletar métricas, health checks e dashboards do ambiente |

## Como executar
### Pré-requisitos
- Docker Desktop com Kubernetes habilitado.
- `kubectl` configurado para o cluster local.
- PowerShell 5.1+.

### Execução recomendada (ambiente completo)
```powershell
cd /fiap-soat-video-local-dev
Copy-Item .env.example .env -ErrorAction SilentlyContinue
.\start.ps1
```

### Execução alternativa

Subir o compose principal com serviços de app em containers (perfil opcional):
```powershell
cd /fiap-soat-video-local-dev
docker compose --profile compose-apps up -d
```

### Encerrar ambiente
```powershell
cd /fiap-soat-video-local-dev
.\down.ps1
```

Com limpeza total de volumes:
```powershell
cd /fiap-soat-video-local-dev
.\down.ps1 -PurgeData
```

## Como testar
Este repositório não possui suíte automatizada de testes. A validação é feita por smoke tests de ambiente.

1. Validar pods e serviços Kubernetes:
```powershell
kubectl get pods -n video-processor
kubectl get svc -n video-processor
```

2. Validar health checks expostos pelo gateway:
```powershell
curl http://auth.localhost/health
curl http://video.localhost/health
curl http://jobs.localhost/health
curl http://notify.localhost/health
```

3. Validar observabilidade:
- Grafana: `http://grafana.localhost`
- Prometheus: `http://prometheus.localhost`
- Traefik Dashboard: `http://traefik.localhost`

