# Setup do Ambiente de Desenvolvimento Local

## Mudanças Realizadas

### 1. Dockerfiles Ajustados

Todos os Dockerfiles foram ajustados para:
- Usar o contexto na pasta raiz do projeto (pai de cada serviço)
- Incluir o pacote compartilhado (`fiap-soat-video-shared`) antes de instalar dependências
- Instalar dependências explicitamente ao invés de usar `pip install -e .`
- Adicionar `PYTHONPATH=/app/src` para que os módulos Python sejam encontrados
- Incluir dependências essenciais:
  - `psycopg2-binary` para SQLAlchemy
  - `pydantic[email]` para validação de emails no auth-service
  - `ffmpeg-python` para processamento de vídeo no job-service

### 2. Docker Compose Ajustado

O `docker-compose.yml` foi atualizado para:
- Usar contexto `..` (pasta pai) ao invés de contexto individual por serviço
- Especificar o caminho completo do Dockerfile (ex: `fiap-soat-video-auth/Dockerfile`)
- Usar URLs de banco de dados com driver async: `postgresql+asyncpg://` ao invés de `postgresql://`

## Como Usar

### Iniciar o Ambiente

```powershell
cd d:\FIAP\HACKATON\fiap-soat-video-local-dev
docker-compose up -d
```

### Verificar Status

```powershell
docker-compose ps
```

### Ver Logs

```powershell
# Todos os serviços
docker-compose logs -f

# Serviço específico
docker-compose logs -f auth-service
docker-compose logs -f video-service
docker-compose logs -f job-api-service
docker-compose logs -f notification-service
```

### Parar o Ambiente

```powershell
docker-compose down
```

### Parar e Remover Volumes (reset completo)

```powershell
docker-compose down -v
```

### Rebuild dos Serviços

```powershell
# Rebuild todos
docker-compose build

# Rebuild específico
docker-compose build auth-service
```

## Serviços e Portas

| Serviço | Porta Host | Porta Container | Descrição |
|---------|------------|-----------------|-----------|
| nginx-gateway | 8000 | 80 | API Gateway (ponto de entrada principal) |
| auth-service | 8001 | 8000 | Serviço de autenticação |
| video-service | 8002 | 8000 | Serviço de gerenciamento de vídeos |
| job-api-service | 8003 | 8000 | API do serviço de jobs |
| notification-service | 8004 | 8000 | Serviço de notificações |
| postgres-auth | 5432 | 5432 | Banco de dados do auth-service |
| postgres-video | 5433 | 5432 | Banco de dados do video-service |
| postgres-job | 5434 | 5432 | Banco de dados do job-service |
| postgres-notification | 5435 | 5432 | Banco de dados do notification-service |
| redis | 6379 | 6379 | Cache Redis |
| localstack | 4566 | 4566 | AWS LocalStack (S3, SQS, SNS, SES) |

## Acessar os Serviços

Todos os serviços estão acessíveis através do nginx-gateway na porta 8000, ou diretamente pelas portas individuais:

```powershell
# Health check do auth-service
curl http://localhost:8001/health

# Health check do video-service
curl http://localhost:8002/health

# Health check do job-api-service
curl http://localhost:8003/health

# Health check do notification-service
curl http://localhost:8004/health

# Através do gateway
curl http://localhost:8000/health
```

## Estrutura dos Dockerfiles

Os Dockerfiles seguem o seguinte padrão:

```dockerfile
FROM python:3.11-slim

WORKDIR /app

# Instalar dependências do sistema
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Copiar e instalar pacote compartilhado
COPY fiap-soat-video-shared/ /tmp/video-processor-shared/
RUN pip install --no-cache-dir /tmp/video-processor-shared/

# Copiar pyproject.toml e instalar dependências
COPY fiap-soat-video-{service}/pyproject.toml .
RUN pip install --no-cache-dir {dependencies}

# Copiar código da aplicação
COPY fiap-soat-video-{service}/src/ src/

# Configurar PYTHONPATH
ENV PYTHONPATH=/app/src

# Criar usuário não-root
RUN adduser --disabled-password --gecos '' appuser && chown -R appuser:appuser /app
USER appuser

# Expor porta
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Comando de inicialização
CMD ["uvicorn", "{service}.infrastructure.adapters.input.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

## Troubleshooting

### Erro de Build

Se houver erro no build, tente limpar o cache do Docker:

```powershell
docker-compose build --no-cache
```

### Containers não sobem

Verifique os logs para identificar o problema:

```powershell
docker-compose logs {service-name}
```

### Problemas de Rede

Verifique se as portas não estão sendo usadas por outros processos:

```powershell
netstat -ano | findstr "8000"
netstat -ano | findstr "5432"
```

### Reset Completo

Se precisar fazer um reset completo do ambiente:

```powershell
docker-compose down -v
docker-compose build --no-cache
docker-compose up -d
```
