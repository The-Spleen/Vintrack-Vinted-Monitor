#!/usr/bin/env bash
# Deploy the fork's Vintrack images on hermass.
# Idempotent: safe to re-run after a new image build.
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/vintrack}"
COMPOSE_FILES=(-f docker-compose.yml -f deploy/hermass/docker-compose.override.yml)

cd "$REPO_DIR"

echo "== pulling images =="
docker compose "${COMPOSE_FILES[@]}" pull --ignore-buildable

echo "== starting stack =="
docker compose "${COMPOSE_FILES[@]}" up -d --no-build

echo "== waiting for migrations =="
for _ in $(seq 1 60); do
    state="$(docker inspect -f '{{.State.Status}}' vintrack_migrate 2>/dev/null || echo missing)"
    code="$(docker inspect -f '{{.State.ExitCode}}' vintrack_migrate 2>/dev/null || echo 1)"
    if [ "$state" = "exited" ]; then
        [ "$code" = "0" ] || { echo "migration failed (exit $code)"; docker logs --tail 50 vintrack_migrate; exit 1; }
        break
    fi
    sleep 2
done

echo "== seeding the automatic-admin user =="
docker compose "${COMPOSE_FILES[@]}" exec -T control-center node -e '
const { PrismaClient } = require("@prisma/client");
const db = new PrismaClient();
const id = process.env.E2E_TEST_USER_ID || "admin";
db.user.upsert({
  where: { id },
  create: {
    id,
    name: process.env.E2E_TEST_USER_NAME || "Admin",
    email: process.env.E2E_TEST_USER_EMAIL || "admin@vintrack.local",
    role: "admin",
    monitor_onboarding_status: "completed",
  },
  update: { role: "admin", monitor_onboarding_status: "completed" },
}).then(() => { console.log("admin user ready:", id); process.exit(0); })
  .catch((e) => { console.error(e); process.exit(1); });
'

echo "== status =="
docker compose "${COMPOSE_FILES[@]}" ps
