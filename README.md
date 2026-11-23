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

`deploy-app.sh` deploys from the split frontend and backend repositories:

```text
/root/annie-deploy/
├── docker-compose.yml
├── frontend/  # cloned from annie-frontend
└── backend/   # cloned from annie-backend
```

Repository variables:

```bash
REMOTE_DIR=/root/annie-deploy
COMPOSE_PROJECT_NAME=annie-website
FRONTEND_REPO_URL=https://github.com/DeepUmbrella/annie-frontend.git
BACKEND_REPO_URL=https://github.com/DeepUmbrella/annie-backend.git
FRONTEND_BRANCH=main
BACKEND_BRANCH=main
```

## Frontend Image Releases

On the deployment host, place `docker-compose.frontend-image.yml` beside
`/root/annie-deploy/docker-compose.yml` and install
`scripts/deploy-frontend-image.sh` in `/root/annie-deploy/scripts`.
Docker Compose v2 must support `!reset` in merge files and `up --wait`.
When the GHCR package is private, authenticate Docker on the server with a
read-only package credential before deploying.

Run an image release with the digest published by the frontend build:

```bash
/root/annie-deploy/scripts/deploy-frontend-image.sh \
  ghcr.io/deepumbrella/annie-frontend@sha256:<64-hex-digit-digest>
```

The script uses the existing `annie-website` Compose project and environment.
It pulls only the frontend image, records the current container's exact local
image under an `annie-frontend-rollback` tag, and replaces only the frontend.
Verification checks the container's image ID and loopback health, then compares
the built JavaScript entry point and response bytes over loopback and the
public HTTPS site. If replacement fails, it restores the recorded local image.
Run the broader production smoke check below to verify API and Nginx routes
independently.

To return to the previously running image:

```bash
/root/annie-deploy/scripts/deploy-frontend-image.sh --rollback
```

Keep `.frontend-deploy` and the local rollback tags on the deployment host. If an
interruption leaves a pending release, the next invocation attempts recovery
first and exits so the requested release can be retried separately. Coordinate
any full-stack deployment with frontend image releases since both manage the
same frontend container.

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
