# Annie Infra

Deployment and operations repository for Annie.

This repository owns:

- Docker Compose orchestration
- host Nginx setup
- server bootstrap scripts
- production smoke checks
- deployment and environment documentation

Application code lives in separate repositories:

- `annie-frontend`
- `annie-backend`

## Production Domains

```text
Frontend: https://www.linany.com
API:      https://api.linany.com/api/v1
```

The main-domain legacy API path redirects to the API domain:

```text
https://www.linany.com/api/* -> https://api.linany.com/api/*
```

## First-Time Server Setup

Prepare `deploy.env` locally, then run:

```bash
env $(cat deploy.env | xargs) ./scripts/setup-server.sh
env $(cat deploy.env | xargs) ./scripts/setup-nginx.sh
env $(cat deploy.env | xargs) ./scripts/deploy-app.sh
```

By default, `deploy-app.sh` uses split-repository deployment:

```text
/root/annie-deploy/
├── docker-compose.yml
├── frontend/  # cloned from annie-frontend
└── backend/   # cloned from annie-backend
```

Default repository variables:

```bash
DEPLOY_MODE=split
REMOTE_DIR=/root/annie-deploy
FRONTEND_REPO_URL=https://github.com/DeepUmbrella/annie-frontend.git
BACKEND_REPO_URL=https://github.com/DeepUmbrella/annie-backend.git
FRONTEND_BRANCH=main
BACKEND_BRANCH=main
```

For the old mono-repo deployment flow, set:

```bash
DEPLOY_MODE=monorepo
REMOTE_DIR=/root/annie-website
REPO_URL=https://github.com/DeepUmbrella/annie-website.git
DEPLOY_BRANCH=main
```

## Production Smoke Check

```bash
DOMAIN=www.linany.com API_DOMAIN=api.linany.com ./scripts/smoke-production.sh
```

## Secrets

Do not commit:

- `.env`
- `.env.local`
- `.env.docker`
- `deploy.env`
- `secrets/`
- certificate or key files

Use the example files as templates only.
