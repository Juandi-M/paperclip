#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ops/local/env.sh"

COMPOSE_FILE="$PAPERCLIP_REPO_ROOT/docker-compose.quickstart.yml"
RUNTIME_ENV_FILE="$PAPERCLIP_HOME/instances/$PAPERCLIP_INSTANCE_ID/.env"
DOCKER_ENV_FILE="$PAPERCLIP_HOME/docker-compose.env"

ACTION="up"
INTERACTIVE=1
NO_BUILD=0
FORCE_PORT=0
TAIL_LOGS=1

OPENAI_KEY_OVERRIDE=""
ANTHROPIC_KEY_OVERRIDE=""
AUTH_SECRET_OVERRIDE=""
PUBLIC_URL_OVERRIDE=""
PORT_OVERRIDE=""
DATA_DIR_OVERRIDE=""
S3_BUCKET_OVERRIDE=""
S3_REGION_OVERRIDE=""
S3_ENDPOINT_OVERRIDE=""
AWS_ACCESS_KEY_OVERRIDE=""
AWS_SECRET_KEY_OVERRIDE=""

COMPOSE_CMD=()
TMP_FILES=()
RUNTIME_OPTION_KEYS=()
RUNTIME_OPTION_LABELS=()
SELECTED_RUNTIME_CHOICE=""

cleanup() {
  set +e
  local f=""
  for f in "${TMP_FILES[@]:-}"; do
    if [[ -n "$f" && -f "$f" ]]; then
      rm -f "$f"
    fi
  done
}

on_error() {
  local exit_code="$1"
  local line="$2"
  local cmd="$3"
  echo "[ERROR] bootstrap-docker failed (exit=${exit_code}, line=${line}): ${cmd}" >&2
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./bootstrap-docker.sh [action] [options]

Actions (switch/case):
  up        (default) configure secrets/env and start compose
  down      stop compose
  restart   restart compose with current env
  status    show compose status
  logs      show compose logs (tail by default)

Options:
  -y, --non-interactive        no prompts; use existing values/defaults/flags
      --no-build               skip compose --build on up/restart
      --force-port             allow using a busy port
      --no-tail                for logs action, do not follow
      --openai-key <value>     set OPENAI_API_KEY
      --anthropic-key <value>  set ANTHROPIC_API_KEY
      --auth-secret <value>    set BETTER_AUTH_SECRET
      --public-url <value>     set PAPERCLIP_PUBLIC_URL (http/https)
      --port <value>           set PAPERCLIP_PORT
      --data-dir <value>       set PAPERCLIP_DATA_DIR
      --s3-bucket <value>      set PAPERCLIP_STORAGE_S3_BUCKET (enables S3 storage + agent runtime sync)
      --s3-region <value>      set PAPERCLIP_STORAGE_S3_REGION (default: us-east-1)
      --s3-endpoint <value>    set PAPERCLIP_STORAGE_S3_ENDPOINT (optional, for MinIO/R2)
      --aws-access-key <value> set AWS_ACCESS_KEY_ID
      --aws-secret-key <value> set AWS_SECRET_ACCESS_KEY
  -h, --help                   show this help
EOF
}

read_env_value() {
  local file="$1"
  local key="$2"
  if [[ ! -f "$file" ]]; then
    echo ""
    return 0
  fi
  grep -E "^${key}=" "$file" | tail -n 1 | cut -d'=' -f2- || true
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return 0
  fi
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

generate_base64_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n'
    return 0
  fi
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

to_abs_path() {
  local p="$1"
  if [[ "$p" = /* ]]; then
    echo "$p"
    return 0
  fi
  echo "$PAPERCLIP_REPO_ROOT/$p"
}

detect_compose_cmd() {
  if ! command -v docker >/dev/null 2>&1; then
    die "docker no esta instalado."
  fi
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return 0
  fi
  die "docker compose no esta disponible."
}

docker_daemon_ready() {
  docker info >/dev/null 2>&1
}

has_macos_app() {
  local app_name="$1"
  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 1
  fi
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "id of app \"$app_name\"" >/dev/null 2>&1
    return $?
  fi
  [[ -d "/Applications/${app_name}.app" || -d "$HOME/Applications/${app_name}.app" ]]
}

add_runtime_option() {
  local key="$1"
  local label="$2"
  RUNTIME_OPTION_KEYS+=("$key")
  RUNTIME_OPTION_LABELS+=("$label")
}

populate_runtime_options() {
  RUNTIME_OPTION_KEYS=()
  RUNTIME_OPTION_LABELS=()

  if has_macos_app "Docker"; then
    add_runtime_option "docker_desktop" "Docker Desktop"
  fi
  if has_macos_app "OrbStack"; then
    add_runtime_option "orbstack" "OrbStack"
  fi
  if command -v colima >/dev/null 2>&1; then
    add_runtime_option "colima" "Colima"
  fi
  if command -v podman >/dev/null 2>&1; then
    add_runtime_option "podman" "Podman"
  fi
}

runtime_label_for_key() {
  local key="$1"
  local i
  for (( i = 0; i < ${#RUNTIME_OPTION_KEYS[@]}; i++ )); do
    if [[ "${RUNTIME_OPTION_KEYS[$i]}" == "$key" ]]; then
      echo "${RUNTIME_OPTION_LABELS[$i]}"
      return 0
    fi
  done
  echo "$key"
}

format_runtime_options() {
  local out=""
  local i
  for (( i = 0; i < ${#RUNTIME_OPTION_LABELS[@]}; i++ )); do
    if [[ -n "$out" ]]; then
      out+=", "
    fi
    out+="${RUNTIME_OPTION_LABELS[$i]}"
  done
  echo "$out"
}

prompt_runtime_choice() {
  local choice=""
  local count="${#RUNTIME_OPTION_KEYS[@]}"
  local max_index="$count"
  local i
  SELECTED_RUNTIME_CHOICE=""

  echo
  warn "docker esta instalado pero el daemon no responde."
  echo "Elige que runtime quieres arrancar:"
  for (( i = 0; i < count; i++ )); do
    printf "  %d) %s\n" "$((i + 1))" "${RUNTIME_OPTION_LABELS[$i]}"
  done
  echo "  q) cancelar"

  while true; do
    read -r -p "Seleccion [1-${max_index}/q]: " choice
    case "$choice" in
      [Qq])
        return 1
        ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
          SELECTED_RUNTIME_CHOICE="${RUNTIME_OPTION_KEYS[$((choice - 1))]}"
          return 0
        fi
        warn "Seleccion invalida. Elige un numero valido o 'q'."
        ;;
    esac
  done
}

start_selected_runtime() {
  local runtime_key="$1"
  case "$runtime_key" in
    docker_desktop)
      log "Arrancando Docker Desktop..."
      open -a "Docker"
      ;;
    orbstack)
      log "Arrancando OrbStack..."
      open -a "OrbStack"
      ;;
    colima)
      log "Arrancando Colima..."
      colima start
      ;;
    podman)
      log "Arrancando Podman..."
      if [[ "$(uname -s)" == "Darwin" ]]; then
        podman machine start
      elif command -v systemctl >/dev/null 2>&1; then
        systemctl --user start podman.socket || podman machine start
      else
        podman machine start
      fi
      ;;
    *)
      die "Runtime no soportado: $runtime_key"
      ;;
  esac
}

wait_for_docker_daemon() {
  local timeout_sec="${1:-60}"
  local poll_sec=2
  local elapsed=0

  while (( elapsed < timeout_sec )); do
    if docker_daemon_ready; then
      return 0
    fi
    sleep "$poll_sec"
    elapsed=$((elapsed + poll_sec))
  done
  return 1
}

ensure_docker_daemon() {
  if docker_daemon_ready; then
    return 0
  fi

  populate_runtime_options

  if (( INTERACTIVE == 1 )) && (( ${#RUNTIME_OPTION_KEYS[@]} > 0 )); then
    if ! prompt_runtime_choice; then
      die "Operacion cancelada por el usuario."
    fi

    start_selected_runtime "$SELECTED_RUNTIME_CHOICE"

    local selected_label
    selected_label="$(runtime_label_for_key "$SELECTED_RUNTIME_CHOICE")"
    log "Esperando a que el daemon Docker responda despues de arrancar ${selected_label}..."
    if wait_for_docker_daemon 90; then
      log "Docker daemon listo."
      return 0
    fi

    die "Se intento arrancar ${selected_label}, pero 'docker info' sigue sin responder. Revisa el runtime seleccionado y vuelve a intentar."
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    local runtime_options=""
    runtime_options="$(format_runtime_options)"
    if [[ -n "$runtime_options" ]]; then
      die "docker esta instalado pero el daemon no responde. Arranca uno de estos runtimes y reintenta: ${runtime_options}."
    fi
    die "docker esta instalado pero el daemon no responde. Abre Docker Desktop, OrbStack, Colima o Podman y espera a que arranque antes de correr ./bootstrap-docker.sh."
  fi

  die "docker esta instalado pero el daemon no responde. Inicia el servicio de Docker antes de correr ./bootstrap-docker.sh."
}

compose_exec() {
  "${COMPOSE_CMD[@]}" --env-file "$DOCKER_ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

json_escape() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  raw="${raw//$'\n'/\\n}"
  raw="${raw//$'\r'/\\r}"
  raw="${raw//$'\t'/\\t}"
  printf '%s' "$raw"
}

strip_ansi() {
  sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g'
}

resolve_url_hostname() {
  local url="$1"
  local without_scheme="$url"
  without_scheme="${without_scheme#http://}"
  without_scheme="${without_scheme#https://}"
  without_scheme="${without_scheme%%/*}"
  without_scheme="${without_scheme%%:*}"
  printf '%s' "$without_scheme"
}

maybe_open_url() {
  local url="$1"
  [[ -n "$url" ]] || return 0
  (( INTERACTIVE == 1 )) || return 0

  if [[ "$(uname -s)" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
    log "Abriendo en el browser: $url"
    open "$url" >/dev/null 2>&1 || warn "No pude abrir automaticamente $url"
    return 0
  fi

  if command -v xdg-open >/dev/null 2>&1; then
    log "Abriendo en el browser: $url"
    xdg-open "$url" >/dev/null 2>&1 || warn "No pude abrir automaticamente $url"
  fi
}

prompt_secret_with_default() {
  local label="$1"
  local current="$2"
  local input=""
  local state="empty"
  [[ -n "$current" ]] && state="set"
  read -r -p "${label} [current: ${state}] (visible input, Enter = keep current): " input
  if [[ -n "$input" ]]; then
    echo "$input"
  else
    echo "$current"
  fi
}

prompt_text_with_default() {
  local label="$1"
  local current="$2"
  local input=""
  read -r -p "${label} [${current}]: " input
  if [[ -n "$input" ]]; then
    echo "$input"
  else
    echo "$current"
  fi
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]{2,5}$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

validate_url() {
  local u="$1"
  [[ "$u" =~ ^https?://[A-Za-z0-9._:-]+(/.*)?$ ]]
}

validate_optional_openai_key() {
  local key_value="$1"
  [[ -z "$key_value" ]] && return 0
  [[ "$key_value" =~ ^sk-[A-Za-z0-9._-]{10,}$ ]]
}

validate_optional_anthropic_key() {
  local key_value="$1"
  [[ -z "$key_value" ]] && return 0
  [[ "$key_value" =~ ^sk-ant-[A-Za-z0-9._-]{10,}$ ]]
}

port_in_use() {
  local p="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$p" -sTCP:LISTEN -n -P >/dev/null 2>&1
    return $?
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$p" >/dev/null 2>&1
    return $?
  fi
  return 1
}

service_container_id() {
  compose_exec ps -q paperclip 2>/dev/null | tail -n 1
}

service_container_status() {
  local container_id="$1"
  [[ -n "$container_id" ]] || return 1
  docker inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null
}

service_running() {
  local container_id
  container_id="$(service_container_id)"
  [[ -n "$container_id" ]] || return 1
  [[ "$(service_container_status "$container_id")" == "running" ]]
}

wait_for_service_ready() {
  local port="$1"
  local timeout_sec="${2:-60}"
  local poll_sec=2
  local elapsed=0
  local health_url="http://127.0.0.1:${port}/api/health"

  while (( elapsed < timeout_sec )); do
    if ! service_running; then
      return 1
    fi

    if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "$health_url" >/dev/null 2>&1; then
      return 0
    fi

    sleep "$poll_sec"
    elapsed=$((elapsed + poll_sec))
  done

  return 1
}

print_start_failure_context() {
  warn "El servicio no quedo listo. Estado actual de compose:"
  compose_exec ps || true
  warn "Ultimos logs del contenedor:"
  compose_exec logs --tail 120 || true
}

fetch_health_json() {
  local port="$1"
  curl -fsS --max-time 3 "http://127.0.0.1:${port}/api/health"
}

ensure_local_files() {
  mkdir -p "$(dirname "$RUNTIME_ENV_FILE")" "$PAPERCLIP_HOME"
  touch "$RUNTIME_ENV_FILE"
  chmod 600 "$RUNTIME_ENV_FILE"
}

ensure_quickstart_secrets_key_file() {
  local key_file="$1"
  [[ -f "$key_file" ]] && return 0

  mkdir -p "$(dirname "$key_file")"
  printf '%s\n' "$(generate_base64_secret)" > "$key_file"
  chmod 600 "$key_file"
  log "Cree local secrets master key para Docker quickstart: $key_file"
}

ensure_quickstart_config_file() {
  local paperclip_data_dir="$1"
  local public_url="$2"
  local port="$3"
  local instance_root="$paperclip_data_dir/instances/$PAPERCLIP_INSTANCE_ID"
  local config_path="$instance_root/config.json"
  local logs_dir="$instance_root/logs"
  local backup_dir="$instance_root/data/backups"
  local storage_dir="$instance_root/data/storage"
  local secrets_key_path="$instance_root/secrets/master.key"
  local updated_at public_hostname allowed_hostnames_json
  local public_url_json db_dir_json logs_dir_json backup_dir_json storage_dir_json secrets_key_path_json

  mkdir -p "$instance_root" "$logs_dir" "$backup_dir" "$storage_dir"
  ensure_quickstart_secrets_key_file "$secrets_key_path"

  [[ -f "$config_path" ]] && return 0

  updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  public_hostname="$(resolve_url_hostname "$public_url")"
  if [[ -n "$public_hostname" ]]; then
    allowed_hostnames_json="[\"$(json_escape "$public_hostname")\"]"
  else
    allowed_hostnames_json="[]"
  fi

  public_url_json="$(json_escape "$public_url")"
  db_dir_json="$(json_escape "/paperclip/instances/$PAPERCLIP_INSTANCE_ID/db")"
  logs_dir_json="$(json_escape "/paperclip/instances/$PAPERCLIP_INSTANCE_ID/logs")"
  backup_dir_json="$(json_escape "/paperclip/instances/$PAPERCLIP_INSTANCE_ID/data/backups")"
  storage_dir_json="$(json_escape "/paperclip/instances/$PAPERCLIP_INSTANCE_ID/data/storage")"
  secrets_key_path_json="$(json_escape "/paperclip/instances/$PAPERCLIP_INSTANCE_ID/secrets/master.key")"

  cat > "$config_path" <<EOF
{
  "\$meta": {
    "version": 1,
    "updatedAt": "${updated_at}",
    "source": "onboard"
  },
  "database": {
    "mode": "embedded-postgres",
    "embeddedPostgresDataDir": "${db_dir_json}",
    "embeddedPostgresPort": 54329,
    "backup": {
      "enabled": true,
      "intervalMinutes": 60,
      "retentionDays": 30,
      "dir": "${backup_dir_json}"
    }
  },
  "logging": {
    "mode": "file",
    "logDir": "${logs_dir_json}"
  },
  "server": {
    "deploymentMode": "authenticated",
    "exposure": "private",
    "host": "0.0.0.0",
    "port": ${port},
    "allowedHostnames": ${allowed_hostnames_json},
    "serveUi": true
  },
  "auth": {
    "baseUrlMode": "explicit",
    "publicBaseUrl": "${public_url_json}",
    "disableSignUp": false
  },
  "storage": {
    "provider": "local_disk",
    "localDisk": {
      "baseDir": "${storage_dir_json}"
    },
    "s3": {
      "bucket": "paperclip",
      "region": "us-east-1",
      "prefix": "",
      "forcePathStyle": false
    }
  },
  "secrets": {
    "provider": "local_encrypted",
    "strictMode": false,
    "localEncrypted": {
      "keyFilePath": "${secrets_key_path_json}"
    }
  }
}
EOF

  chmod 600 "$config_path"
  log "Cree config persistente para Docker quickstart: $config_path"
}

cleanup_empty_embedded_postgres_dir() {
  local paperclip_data_dir="$1"
  local db_dir="$paperclip_data_dir/instances/$PAPERCLIP_INSTANCE_ID/db"

  [[ -d "$db_dir" ]] || return 0
  [[ ! -f "$db_dir/PG_VERSION" ]] || return 0

  if find "$db_dir" -mindepth 1 -print -quit | grep -q .; then
    warn "El directorio de embedded-postgres existe pero no parece inicializado: $db_dir"
    warn "No lo borro automaticamente porque no esta vacio. Si sigues fallando, revisa ese directorio."
    return 0
  fi

  if rmdir "$db_dir"; then
    log "Elimine directorio vacio de embedded-postgres para permitir una inicializacion limpia: $db_dir"
  fi
}

repair_quickstart_permissions() {
  local paperclip_data_dir="$1"
  local instances_dir="$paperclip_data_dir/instances"
  local instance_root="$instances_dir/$PAPERCLIP_INSTANCE_ID"
  local data_root="$instance_root/data"
  local logs_dir="$instance_root/logs"
  local backup_dir="$data_root/backups"
  local storage_dir="$data_root/storage"
  local secrets_dir="$instance_root/secrets"
  local config_path="$instance_root/config.json"
  local secrets_key_path="$secrets_dir/master.key"
  local db_dir="$instance_root/db"

  mkdir -p "$instances_dir" "$instance_root" "$data_root" "$logs_dir" "$backup_dir" "$storage_dir" "$secrets_dir"

  chmod 755 "$paperclip_data_dir" "$instances_dir" "$instance_root" "$data_root" "$logs_dir" "$backup_dir" "$storage_dir" "$secrets_dir" \
    || warn "No pude ajustar permisos base de quickstart en $paperclip_data_dir; continuo."

  if [[ -f "$config_path" ]]; then
    chmod 600 "$config_path" || warn "No pude ajustar permisos de $config_path; continuo."
  fi

  if [[ -f "$secrets_key_path" ]]; then
    chmod 600 "$secrets_key_path" || warn "No pude ajustar permisos de $secrets_key_path; continuo."
  fi

  if [[ -d "$db_dir" ]]; then
    find "$db_dir" -type d -exec chmod 700 {} + \
      || warn "No pude ajustar permisos de directorios PostgreSQL en $db_dir; continuo."
    find "$db_dir" -type f -exec chmod 600 {} + \
      || warn "No pude ajustar permisos de archivos PostgreSQL en $db_dir; continuo."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      up|down|restart|status|logs)
        ACTION="$1"
        shift
        ;;
      -y|--non-interactive)
        INTERACTIVE=0
        shift
        ;;
      --no-build)
        NO_BUILD=1
        shift
        ;;
      --force-port)
        FORCE_PORT=1
        shift
        ;;
      --no-tail)
        TAIL_LOGS=0
        shift
        ;;
      --openai-key)
        OPENAI_KEY_OVERRIDE="${2:-}"
        [[ -n "$OPENAI_KEY_OVERRIDE" ]] || die "--openai-key requiere valor"
        shift 2
        ;;
      --anthropic-key)
        ANTHROPIC_KEY_OVERRIDE="${2:-}"
        [[ -n "$ANTHROPIC_KEY_OVERRIDE" ]] || die "--anthropic-key requiere valor"
        shift 2
        ;;
      --auth-secret)
        AUTH_SECRET_OVERRIDE="${2:-}"
        [[ -n "$AUTH_SECRET_OVERRIDE" ]] || die "--auth-secret requiere valor"
        shift 2
        ;;
      --public-url)
        PUBLIC_URL_OVERRIDE="${2:-}"
        [[ -n "$PUBLIC_URL_OVERRIDE" ]] || die "--public-url requiere valor"
        shift 2
        ;;
      --port)
        PORT_OVERRIDE="${2:-}"
        [[ -n "$PORT_OVERRIDE" ]] || die "--port requiere valor"
        shift 2
        ;;
      --data-dir)
        DATA_DIR_OVERRIDE="${2:-}"
        [[ -n "$DATA_DIR_OVERRIDE" ]] || die "--data-dir requiere valor"
        shift 2
        ;;
      --s3-bucket)
        S3_BUCKET_OVERRIDE="${2:-}"
        [[ -n "$S3_BUCKET_OVERRIDE" ]] || die "--s3-bucket requiere valor"
        shift 2
        ;;
      --s3-region)
        S3_REGION_OVERRIDE="${2:-}"
        [[ -n "$S3_REGION_OVERRIDE" ]] || die "--s3-region requiere valor"
        shift 2
        ;;
      --s3-endpoint)
        S3_ENDPOINT_OVERRIDE="${2:-}"
        shift 2
        ;;
      --aws-access-key)
        AWS_ACCESS_KEY_OVERRIDE="${2:-}"
        [[ -n "$AWS_ACCESS_KEY_OVERRIDE" ]] || die "--aws-access-key requiere valor"
        shift 2
        ;;
      --aws-secret-key)
        AWS_SECRET_KEY_OVERRIDE="${2:-}"
        [[ -n "$AWS_SECRET_KEY_OVERRIDE" ]] || die "--aws-secret-key requiere valor"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Argumento no soportado: $1 (usa --help)"
        ;;
    esac
  done
}

write_runtime_env() {
  local openai="$1"
  local anthropic="$2"
  local tmp_runtime
  tmp_runtime="$(mktemp)"
  TMP_FILES+=("$tmp_runtime")

  awk '
    BEGIN { FS="=" }
    /^[[:space:]]*OPENAI_API_KEY=/ { next }
    /^[[:space:]]*ANTHROPIC_API_KEY=/ { next }
    { print }
  ' "$RUNTIME_ENV_FILE" > "$tmp_runtime"

  {
    cat "$tmp_runtime"
    [[ -n "$openai" ]] && printf "OPENAI_API_KEY=%s\n" "$openai"
    [[ -n "$anthropic" ]] && printf "ANTHROPIC_API_KEY=%s\n" "$anthropic"
  } > "$RUNTIME_ENV_FILE"

  chmod 600 "$RUNTIME_ENV_FILE"
}

write_docker_env() {
  local openai="$1"
  local anthropic="$2"
  local auth_secret="$3"
  local public_url="$4"
  local port="$5"
  local data_dir="$6"
  local s3_bucket="$7"
  local s3_region="$8"
  local s3_endpoint="$9"
  local aws_access_key="${10}"
  local aws_secret_key="${11}"

  local storage_provider="local_disk"
  [[ -n "$s3_bucket" ]] && storage_provider="s3"

  cat > "$DOCKER_ENV_FILE" <<EOF
# Local compose env generated by ./bootstrap-docker.sh
OPENAI_API_KEY=${openai}
ANTHROPIC_API_KEY=${anthropic}
BETTER_AUTH_SECRET=${auth_secret}
PAPERCLIP_PUBLIC_URL=${public_url}
PAPERCLIP_PORT=${port}
PAPERCLIP_DATA_DIR=${data_dir}
PAPERCLIP_STORAGE_PROVIDER=${storage_provider}
PAPERCLIP_STORAGE_S3_BUCKET=${s3_bucket}
PAPERCLIP_STORAGE_S3_REGION=${s3_region}
PAPERCLIP_STORAGE_S3_ENDPOINT=${s3_endpoint}
AWS_ACCESS_KEY_ID=${aws_access_key}
AWS_SECRET_ACCESS_KEY=${aws_secret_key}
EOF
  chmod 600 "$DOCKER_ENV_FILE"
}

prepare_env_values() {
  local existing_openai existing_anthropic existing_port existing_public_url existing_data_dir existing_auth_secret
  local default_port default_data_dir default_public_url default_auth_secret

  existing_openai="$(read_env_value "$RUNTIME_ENV_FILE" "OPENAI_API_KEY")"
  existing_anthropic="$(read_env_value "$RUNTIME_ENV_FILE" "ANTHROPIC_API_KEY")"
  existing_port="$(read_env_value "$DOCKER_ENV_FILE" "PAPERCLIP_PORT")"
  existing_public_url="$(read_env_value "$DOCKER_ENV_FILE" "PAPERCLIP_PUBLIC_URL")"
  existing_data_dir="$(read_env_value "$DOCKER_ENV_FILE" "PAPERCLIP_DATA_DIR")"
  existing_auth_secret="$(read_env_value "$DOCKER_ENV_FILE" "BETTER_AUTH_SECRET")"

  default_port="${existing_port:-3100}"
  default_data_dir="${existing_data_dir:-$PAPERCLIP_REPO_ROOT/.paperclip-local/docker-data}"
  default_public_url="${existing_public_url:-http://localhost:${default_port}}"
  default_auth_secret="${existing_auth_secret:-$(generate_secret)}"

  local existing_s3_bucket existing_s3_region existing_s3_endpoint existing_aws_access_key existing_aws_secret_key
  existing_s3_bucket="$(read_env_value "$DOCKER_ENV_FILE" "PAPERCLIP_STORAGE_S3_BUCKET")"
  existing_s3_region="$(read_env_value "$DOCKER_ENV_FILE" "PAPERCLIP_STORAGE_S3_REGION")"
  existing_s3_endpoint="$(read_env_value "$DOCKER_ENV_FILE" "PAPERCLIP_STORAGE_S3_ENDPOINT")"
  existing_aws_access_key="$(read_env_value "$DOCKER_ENV_FILE" "AWS_ACCESS_KEY_ID")"
  existing_aws_secret_key="$(read_env_value "$DOCKER_ENV_FILE" "AWS_SECRET_ACCESS_KEY")"

  local openai_key anthropic_key paperclip_port paperclip_public_url paperclip_data_dir better_auth_secret
  local s3_bucket s3_region s3_endpoint aws_access_key aws_secret_key

  openai_key="${OPENAI_KEY_OVERRIDE:-$existing_openai}"
  anthropic_key="${ANTHROPIC_KEY_OVERRIDE:-$existing_anthropic}"
  paperclip_port="${PORT_OVERRIDE:-$default_port}"
  paperclip_public_url="${PUBLIC_URL_OVERRIDE:-$default_public_url}"
  paperclip_data_dir="${DATA_DIR_OVERRIDE:-$default_data_dir}"
  better_auth_secret="${AUTH_SECRET_OVERRIDE:-$default_auth_secret}"
  s3_bucket="${S3_BUCKET_OVERRIDE:-$existing_s3_bucket}"
  s3_region="${S3_REGION_OVERRIDE:-${existing_s3_region:-us-east-1}}"
  s3_endpoint="${S3_ENDPOINT_OVERRIDE:-$existing_s3_endpoint}"
  aws_access_key="${AWS_ACCESS_KEY_OVERRIDE:-$existing_aws_access_key}"
  aws_secret_key="${AWS_SECRET_KEY_OVERRIDE:-$existing_aws_secret_key}"

  if (( INTERACTIVE == 1 )); then
    log "Configuracion Docker local de Paperclip"
    log "Repo: $PAPERCLIP_REPO_ROOT"
    log "Runtime env local: $RUNTIME_ENV_FILE"
    log "Compose env local: $DOCKER_ENV_FILE"
    echo

    openai_key="$(prompt_secret_with_default "OPENAI_API_KEY" "$openai_key")"
    anthropic_key="$(prompt_secret_with_default "ANTHROPIC_API_KEY" "$anthropic_key")"
    paperclip_port="$(prompt_text_with_default "PAPERCLIP_PORT" "$paperclip_port")"
    paperclip_public_url="$(prompt_text_with_default "PAPERCLIP_PUBLIC_URL" "$paperclip_public_url")"
    paperclip_data_dir="$(prompt_text_with_default "PAPERCLIP_DATA_DIR" "$paperclip_data_dir")"
    better_auth_secret="$(prompt_secret_with_default "BETTER_AUTH_SECRET" "$better_auth_secret")"
    echo
    log "S3 Storage (opcional — Enter para saltar y usar disco local)"
    s3_bucket="$(prompt_text_with_default "PAPERCLIP_STORAGE_S3_BUCKET" "$s3_bucket")"
    if [[ -n "$s3_bucket" ]]; then
      s3_region="$(prompt_text_with_default "PAPERCLIP_STORAGE_S3_REGION" "$s3_region")"
      s3_endpoint="$(prompt_text_with_default "PAPERCLIP_STORAGE_S3_ENDPOINT (opcional)" "$s3_endpoint")"
      aws_access_key="$(prompt_secret_with_default "AWS_ACCESS_KEY_ID" "$aws_access_key")"
      aws_secret_key="$(prompt_secret_with_default "AWS_SECRET_ACCESS_KEY" "$aws_secret_key")"
    fi
  fi

  paperclip_data_dir="$(to_abs_path "$paperclip_data_dir")"

  validate_port "$paperclip_port" || die "PAPERCLIP_PORT invalido: $paperclip_port"
  validate_url "$paperclip_public_url" || die "PAPERCLIP_PUBLIC_URL invalido: $paperclip_public_url"
  [[ "$better_auth_secret" =~ ^[[:graph:]]{32,}$ ]] || die "BETTER_AUTH_SECRET debe tener al menos 32 caracteres visibles"
  validate_optional_openai_key "$openai_key" || die "OPENAI_API_KEY invalida: debe empezar con 'sk-' y usar solo [A-Za-z0-9._-]"
  validate_optional_anthropic_key "$anthropic_key" || die "ANTHROPIC_API_KEY invalida: debe empezar con 'sk-ant-' y usar solo [A-Za-z0-9._-]"

  if (( FORCE_PORT == 0 )) && port_in_use "$paperclip_port"; then
    die "Puerto $paperclip_port ya esta en uso. Usa --force-port o cambia --port."
  fi

  mkdir -p "$paperclip_data_dir"
  cleanup_empty_embedded_postgres_dir "$paperclip_data_dir"
  ensure_quickstart_config_file "$paperclip_data_dir" "$paperclip_public_url" "$paperclip_port"
  repair_quickstart_permissions "$paperclip_data_dir"

  write_runtime_env "$openai_key" "$anthropic_key"
  write_docker_env "$openai_key" "$anthropic_key" "$better_auth_secret" "$paperclip_public_url" "$paperclip_port" "$paperclip_data_dir" \
    "$s3_bucket" "$s3_region" "$s3_endpoint" "$aws_access_key" "$aws_secret_key"
  log "Valores persistidos en:"
  log "  Runtime env: $RUNTIME_ENV_FILE"
  log "  Compose env: $DOCKER_ENV_FILE"
}

try_step() {
  local label="$1"
  shift
  if "$@"; then
    log "$label: ok"
    return 0
  fi
  warn "$label: fallo"
  return 1
}

action_up() {
  local up_args=(up -d)
  if (( NO_BUILD == 0 )); then
    up_args+=(--build)
  fi

  if try_step "compose up" compose_exec "${up_args[@]}"; then
    return 0
  fi

  if (( NO_BUILD == 0 )); then
    warn "Failover: reintentando compose up sin --build..."
    compose_exec up -d
    return 0
  fi

  die "No se pudo levantar compose."
}

action_down() {
  compose_exec down
}

action_restart() {
  if ! compose_exec down; then
    warn "compose down fallo; continuo con compose up"
  fi
  action_up
}

action_status() {
  compose_exec ps
}

action_logs() {
  if (( TAIL_LOGS == 1 )); then
    compose_exec logs -f
  else
    compose_exec logs
  fi
}

post_up_check() {
  local configured_port
  configured_port="$(read_env_value "$DOCKER_ENV_FILE" "PAPERCLIP_PORT")"
  configured_port="${configured_port:-3100}"

  log "Verificando que Paperclip haya quedado arriba en http://127.0.0.1:${configured_port} ..."
  if wait_for_service_ready "$configured_port" 75; then
    log "Paperclip responde en http://127.0.0.1:${configured_port}/api/health"
    return 0
  fi

  print_start_failure_context
  die "Compose termino, pero Paperclip no quedo listo en el puerto ${configured_port}."
}

post_up_bootstrap_ceo() {
  local configured_port public_url health_json invite_output invite_url
  local container_config_path="/paperclip/instances/$PAPERCLIP_INSTANCE_ID/config.json"

  configured_port="$(read_env_value "$DOCKER_ENV_FILE" "PAPERCLIP_PORT")"
  configured_port="${configured_port:-3100}"
  public_url="$(read_env_value "$DOCKER_ENV_FILE" "PAPERCLIP_PUBLIC_URL")"
  public_url="${public_url:-http://localhost:${configured_port}}"

  health_json="$(fetch_health_json "$configured_port" 2>/dev/null || true)"
  [[ "$health_json" == *'"deploymentMode":"authenticated"'* ]] || return 0
  [[ "$health_json" == *'"bootstrapStatus":"bootstrap_pending"'* ]] || return 0

  log "No existe instance admin. Generando bootstrap CEO invite automaticamente..."
  if ! invite_output="$(compose_exec exec -T paperclip pnpm paperclipai auth bootstrap-ceo --config "$container_config_path" --base-url "$public_url" 2>&1)"; then
    printf '%s\n' "$invite_output" >&2
    die "No pude generar automaticamente el bootstrap CEO invite."
  fi

  printf '%s\n' "$invite_output"
  invite_url="$(
    printf '%s\n' "$invite_output" \
      | strip_ansi \
      | sed -n 's/.*Invite URL: //p' \
      | tail -n 1 \
      | tr -d '\r'
  )"

  if [[ -n "$invite_url" ]]; then
    log "Bootstrap CEO invite listo: $invite_url"
    maybe_open_url "$invite_url"
  else
    warn "No pude extraer la URL del bootstrap invite del output anterior."
  fi
}

main() {
  parse_args "$@"
  ensure_local_files
  detect_compose_cmd
  ensure_docker_daemon

  case "$ACTION" in
    up|restart)
      prepare_env_values
      ;;
    down|status|logs)
      if [[ ! -f "$DOCKER_ENV_FILE" ]]; then
        die "No existe $DOCKER_ENV_FILE. Ejecuta primero: ./bootstrap-docker.sh up"
      fi
      ;;
    *)
      die "Action no soportada: $ACTION"
      ;;
  esac

  case "$ACTION" in
    up) action_up ;;
    down) action_down ;;
    restart) action_restart ;;
    status) action_status ;;
    logs) action_logs ;;
  esac

  if [[ "$ACTION" == "up" || "$ACTION" == "restart" ]]; then
    post_up_check
    post_up_bootstrap_ceo
    echo
    log "Listo."
    log "Runtime env: $RUNTIME_ENV_FILE"
    log "Compose env: $DOCKER_ENV_FILE"
    log "Estado: usa './bootstrap-docker.sh status'"
  fi
}

main "$@"
