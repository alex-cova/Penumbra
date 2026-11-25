#!/usr/bin/env bash
# Disposable database servers for Umbra's live integration tests.
#
#   Scripts/db-test-env.sh up      start PostgreSQL+PostGIS, MySQL and MongoDB, wait until ready
#   Scripts/db-test-env.sh down    stop and delete them (volumes included)
#   Scripts/db-test-env.sh status  show what is running
#   Scripts/db-test-env.sh env     print the variables the tests read
#
# Containers are named umbra-dbtest-* and use ports that are not the defaults, so a database you
# already run is never touched. Only containers with that prefix are ever stopped or removed.
set -euo pipefail

PG_PORT="${UMBRA_TEST_PG_PORT:-55432}"
MYSQL_PORT="${UMBRA_TEST_MYSQL_PORT:-53306}"
MONGO_PORT="${UMBRA_TEST_MONGO_PORT:-57017}"
PASSWORD="umbra_test"

PG_NAME=umbra-dbtest-postgres
MYSQL_NAME=umbra-dbtest-mysql
MONGO_NAME=umbra-dbtest-mongo

up() {
  docker run -d --name "$PG_NAME" -p "127.0.0.1:${PG_PORT}:5432" \
    -e POSTGRES_PASSWORD="$PASSWORD" -e POSTGRES_DB=umbra postgis/postgis:16-3.4 >/dev/null
  docker run -d --name "$MYSQL_NAME" -p "127.0.0.1:${MYSQL_PORT}:3306" \
    -e MYSQL_ROOT_PASSWORD="$PASSWORD" -e MYSQL_DATABASE=umbra mysql:8.4 >/dev/null
  # A one-node replica set, so transactions and change streams are available to test.
  docker run -d --name "$MONGO_NAME" -p "127.0.0.1:${MONGO_PORT}:27017" mongo:7 \
    --replSet rs0 --bind_ip_all >/dev/null

  echo "waiting for PostgreSQL…"
  until docker exec "$PG_NAME" pg_isready -U postgres -d umbra >/dev/null 2>&1; do sleep 1; done
  echo "waiting for MySQL…"
  until docker exec "$MYSQL_NAME" mysqladmin ping -uroot -p"$PASSWORD" --silent >/dev/null 2>&1; do sleep 2; done
  echo "waiting for MongoDB…"
  until docker exec "$MONGO_NAME" mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1; do sleep 1; done
  docker exec "$MONGO_NAME" mongosh --quiet --eval \
    'try { rs.status().ok } catch (e) { rs.initiate({_id:"rs0",members:[{_id:0,host:"localhost:27017"}]}).ok }' >/dev/null
  echo "ready."
  env
}

down() {
  for name in "$PG_NAME" "$MYSQL_NAME" "$MONGO_NAME"; do
    docker rm -f -v "$name" >/dev/null 2>&1 || true
  done
  echo "removed."
}

status() {
  docker ps -a --filter "name=umbra-dbtest-" --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
}

env() {
  cat <<EOF
export UMBRA_DB_INTEGRATION=1
export UMBRA_TEST_PG_URL="postgresql://postgres:${PASSWORD}@127.0.0.1:${PG_PORT}/umbra"
export UMBRA_TEST_MYSQL_URL="mysql://root:${PASSWORD}@127.0.0.1:${MYSQL_PORT}/umbra"
export UMBRA_TEST_MONGO_URL="mongodb://127.0.0.1:${MONGO_PORT}/umbra?directConnection=true"
EOF
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  env) env ;;
  *) echo "usage: $0 up|down|status|env" >&2; exit 2 ;;
esac
