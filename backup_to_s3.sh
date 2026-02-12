#!/usr/bin/env bash
set -euo pipefail

# Load environment files if present (exporting variables for cron)
set -a
[ -f /fast_api_ex/backups.env ] && . /fast_api_ex/backups.env
[ -f /fast_api_ex/.env ] && . /fast_api_ex/.env
set +a

# Обязательные переменные
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"
: "${PGHOST:?PGHOST is required}"
: "${PGUSER:?PGUSER is required}"
: "${MEDIA_DIR:?MEDIA_DIR is required}"

# Ensure postgres credentials are available: either PGPASSWORD or ~/.pgpass
if [ -z "${PGPASSWORD:-}" ] && [ ! -f "${HOME}/.pgpass" ]; then
  echo "[pg] ERROR: neither PGPASSWORD is set nor ${HOME}/.pgpass exists" >&2
  exit 1
fi

TIMESTAMP="$(date +'%Y-%m-%d_%H-%M-%S')"
WORKDIR="/var/backups/run_${TIMESTAMP}"
mkdir -p "$WORKDIR"

# Инициализация репозитория (идемпотентно)
if ! restic snapshots >/dev/null 2>&1; then
  echo "[restic] init repository..."
  restic init
fi

# Дамп всех баз Postgres
PG_DUMP_FILE="$WORKDIR/postgres_${TIMESTAMP}.sql.gz"
echo "[pg] dumping all databases from ${PGHOST}:${PGPORT:-5432} ..."
PGPASSWORD="${PGPASSWORD:-}" pg_dumpall -h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" -w | gzip -c > "${PG_DUMP_FILE}"

# Инвентарный файл
INV_FILE="$WORKDIR/inventory_${TIMESTAMP}.txt"
{
  echo "timestamp=$TIMESTAMP"
  echo "host=$(hostname)"
  echo "pg_host=${PGHOST}"
  echo "media_dir=${MEDIA_DIR}"
} > "$INV_FILE"

# Бэкап в restic
echo "[restic] backup starting..."
restic backup \
  --tag "host:$(hostname)" \
  --tag "type:daily" \
  --tag "ts:${TIMESTAMP}" \
  "${PG_DUMP_FILE}" "${MEDIA_DIR}" "${INV_FILE}"

# Политика хранения
echo "[restic] applying retention..."
restic forget --prune \
  --keep-daily "${KEEP_DAILY:-7}" \
  --keep-weekly "${KEEP_WEEKLY:-4}" \
  --keep-monthly "${KEEP_MONTHLY:-12}"

# Очистка
rm -rf "$WORKDIR"
echo "[backup] done ${TIMESTAMP}"
