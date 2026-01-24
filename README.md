# 🎬 Video Processor - Ambiente de Desenvolvimento Local

Este repositório contém todo o necessário para rodar a arquitetura completa de microserviços do Video Processor localmente.

## 📐 Arquitetura

### AWS Production
![AWS Architecture](./architecture_aws.png)

### Local Development  
![Local Architecture](./architecture_local.png)

---

## 🏗️ Repositórios do Projeto

| Repositório | Descrição | Porta |
|-------------|-----------|-------|
| [fiap-soat-video-shared](https://github.com/morgadope/fiap-soat-video-shared) | Biblioteca compartilhada (Value Objects, DTOs, Events) | - |
| [fiap-soat-video-auth](https://github.com/morgadope/fiap-soat-video-auth) | Serviço de autenticação (JWT, registro, login) | 8001 |
| [fiap-soat-video-service](https://github.com/morgadope/fiap-soat-video-service) | Serviço de upload e gestão de vídeos | 8002 |
| [fiap-soat-video-jobs](https://github.com/morgadope/fiap-soat-video-jobs) | Serviço de processamento de jobs (FFmpeg) | 8003 |
| [fiap-soat-video-notifications](https://github.com/morgadope/fiap-soat-video-notifications) | Serviço de notificações por email (SMTP) | 8004 |
| [fiap-soat-video-infra](https://github.com/morgadope/fiap-soat-video-infra) | Infraestrutura Terraform para AWS | - |
| [fiap-soat-video-local-dev](https://github.com/morgadope/fiap-soat-video-local-dev) | Este repositório - ambiente local | - |

---

## 🚀 Quick Start - Rodar Localmente

### Pré-requisitos

- Docker Desktop instalado e rodando
- Git
- 8GB RAM disponível (recomendado)

### 1. Clone este repositório

```bash
git clone https://github.com/morgadope/fiap-soat-video-local-dev.git
cd fiap-soat-video-local-dev
```

### 2. Configure as variáveis de ambiente

```bash
cp .env.example .env
# Edite o .env conforme necessário
```

### 3. Inicie a infraestrutura

```bash
# Subir apenas infraestrutura (PostgreSQL, Redis, RabbitMQ, MinIO)
docker-compose -f docker-compose.infra.yml up -d

# Verificar se está saudável
docker-compose -f docker-compose.infra.yml ps
```

### 4. Inicie todos os serviços

```bash
# Subir tudo (infraestrutura + microserviços)
docker-compose up -d

# Ver logs
docker-compose logs -f
```

### 5. Acesse os serviços

| Serviço | URL | Credenciais |
|---------|-----|-------------|
| API Docs (Swagger) | http://localhost:8000/docs | - |
| RabbitMQ Management | http://localhost:15672 | admin / admin123 |
| MinIO Console | http://localhost:9001 | minioadmin / minioadmin123 |
| Flower (Celery) | http://localhost:5555 | - |
| Grafana | http://localhost:3000 | admin / admin123 |
| Prometheus | http://localhost:9090 | - |

---

## 📁 Estrutura dos Arquivos

```
fiap-soat-video-local-dev/
├── docker-compose.yml           # Orquestra TODOS os serviços
├── docker-compose.infra.yml     # Apenas infraestrutura
├── .env.example                  # Variáveis de ambiente
├── init-scripts/                 # Scripts de inicialização do banco
│   ├── init-auth-db.sql         # Schema do Auth Service
│   ├── init-video-db.sql        # Schema do Video Service
│   ├── init-job-db.sql          # Schema do Job Service
│   └── init-notification-db.sql # Schema do Notification Service
├── nginx/
│   └── nginx.conf               # Configuração do load balancer
├── architecture_aws.png         # Diagrama da arquitetura AWS
├── architecture_local.png       # Diagrama da arquitetura local
└── generate_diagrams.py         # Script para gerar diagramas
```

---

## 🔧 Comandos Úteis

### Docker Compose

```bash
# Iniciar tudo
docker-compose up -d

# Parar tudo
docker-compose down

# Ver logs de um serviço específico
docker-compose logs -f api

# Reiniciar um serviço
docker-compose restart worker

# Ver status
docker-compose ps

# Limpar tudo (incluindo volumes)
docker-compose down -v
```

### Banco de Dados

```bash
# Acessar PostgreSQL
docker exec -it video_processor_db psql -U postgres -d video_processor

# Ver tabelas
\dt

# Sair
\q
```

### Redis

```bash
# Acessar Redis CLI
docker exec -it video_processor_redis redis-cli

# Ver todas as chaves
KEYS *

# Sair
exit
```

---

## 🧪 Testando a API

### 1. Health Check

```bash
curl http://localhost:8000/health | python -m json.tool
```

### 2. Registrar Usuário

```bash
curl -X POST http://localhost:8000/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"user@test.com","password":"Test1234!","full_name":"Test User"}'
```

### 3. Login

```bash
curl -X POST http://localhost:8000/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"user@test.com","password":"Test1234!"}'
```

### 4. Listar Vídeos (com token)

```bash
TOKEN="seu_token_aqui"
curl http://localhost:8000/videos \
  -H "Authorization: Bearer $TOKEN"
```

---

## 🐛 Troubleshooting

### Erro: "Cannot connect to Docker daemon"
```bash
# Verifique se Docker Desktop está rodando
open -a Docker
```

### Erro: "Port already in use"
```bash
# Encontrar processo na porta
lsof -i :8000
# Matar processo
kill -9 <PID>
```

### Containers não iniciam
```bash
# Ver logs detalhados
docker-compose logs --tail=100

# Reconstruir imagens
docker-compose build --no-cache
docker-compose up -d
```

### Banco de dados vazio
```bash
# Recriar volumes
docker-compose down -v
docker-compose up -d
```

---

## 📊 Monitoramento

### Prometheus Queries

- **Requisições por segundo**: `rate(http_requests_total[5m])`
- **Latência P95**: `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))`
- **Jobs na fila**: `rabbitmq_queue_messages{queue="video_processing"}`

### Grafana Dashboards

Acesse http://localhost:3000 e importe os dashboards:
- API Performance
- Worker Metrics
- Infrastructure Health

---

## 🔄 Fluxo de Processamento

```
1. Usuário faz upload do vídeo
   └─> POST /videos/upload

2. Video Service salva metadados no PostgreSQL
   └─> Faz upload do arquivo para MinIO
   └─> Publica evento no RabbitMQ

3. Celery Worker consome a mensagem
   └─> Baixa vídeo do MinIO
   └─> Extrai frames com FFmpeg
   └─> Cria ZIP com frames
   └─> Upload do ZIP para MinIO
   └─> Atualiza status do job para COMPLETED

4. Notification Service envia email
   └─> Usuário recebe link para download
```

---

## 📝 Licença

MIT License - veja [LICENSE](LICENSE) para detalhes.
