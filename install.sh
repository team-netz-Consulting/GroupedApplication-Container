#!/usr/bin/env bash
set -Eeuo pipefail

# Published as install.sh in team-netz-Consulting/GroupedApplication-Container (see
# release-container.sh). Installs or updates the stack under /opt/groupedapplication from the
# prebuilt GHCR image - no source checkout and no GitHub deploy key needed on the customer host.

readonly INSTALL_ROOT="/opt/groupedapplication"
readonly DATA_ROOT="${INSTALL_ROOT}/data"
readonly IMAGE="ghcr.io/team-netz-consulting/groupedapplication"

fail() {
    printf 'FEHLER: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Das Programm '$1' ist nicht installiert."
}

prompt_required() {
    local variable_name="$1" prompt="$2" value
    while [[ -z "${value:-}" ]]; do
        read -r -p "$prompt" value
    done
    [[ "$value" != *$'\n'* && "$value" != *"'"* ]] || fail "Der Wert darf kein Hochkomma enthalten."
    printf -v "$variable_name" '%s' "$value"
}

random_password() {
    printf 'Aa!%s' "$(openssl rand -hex 24)"
}

env_value() {
    sed -n "s/^$1=//p" "$env_file" | head -n 1
}

ensure_env_value() {
    local key="$1" value="$2"
    if ! grep -q "^${key}=" "$env_file"; then
        printf '%s=%s\n' "$key" "$value" >> "$env_file"
        printf 'Fehlender Eintrag %s wurde in %s ergaenzt.\n' "$key" "$env_file"
    fi
}

if [[ "${EUID}" -ne 0 ]]; then
    fail "Bitte mit Root-Rechten starten: sudo ./install.sh"
fi

require_command docker
require_command openssl
docker compose version >/dev/null 2>&1 || fail "Das Docker-Compose-Plug-in fehlt."
docker info >/dev/null 2>&1 || fail "Der Docker-Daemon ist nicht erreichbar."

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${script_dir}/docker-compose.yml" ]] || fail "docker-compose.yml fehlt neben dem Installationsskript."

default_tag="$(sed -n 's/^GROUPED_APP_IMAGE_TAG=//p' "$script_dir/.env.example" 2>/dev/null | head -n 1)"
default_tag="${default_tag:-latest}"

install -d -m 0750 "$INSTALL_ROOT"
install -m 0644 "$script_dir/docker-compose.yml" "$INSTALL_ROOT/docker-compose.yml"

# SQL Server runs as uid 10001, the app as the .NET image's "app" user (uid 1654).
install -d -o 10001 -g 0 -m 0770 "$DATA_ROOT/mssql"
install -d -o 1654 -g 0 -m 0750 "$DATA_ROOT/uploads" "$DATA_ROOT/logs"
install -d -o 1654 -g 0 -m 0700 "$DATA_ROOT/license"
install -d -o 0 -g 0 -m 0755 "$DATA_ROOT/certs"
chown -R 10001:0 "$DATA_ROOT/mssql"
chmod -R u+rwX,g+rwX,o-rwx "$DATA_ROOT/mssql"
chown -R 1654:0 "$DATA_ROOT/uploads" "$DATA_ROOT/logs" "$DATA_ROOT/license"
chmod -R u+rwX,go-rwx "$DATA_ROOT/uploads" "$DATA_ROOT/logs" "$DATA_ROOT/license"

env_file="$INSTALL_ROOT/.env"
if [[ ! -f "$env_file" ]]; then
    prompt_required owner_email 'E-Mail des ersten SystemOwners: '
    prompt_required customer_name 'Lizenz-Kundenname (wie im License Manager): '
    read -r -p "Host-Port der Anwendung [8080]: " app_port
    app_port="${app_port:-8080}"
    read -r -p "Container-Version [$default_tag]: " image_tag
    image_tag="${image_tag:-$default_tag}"

    sa_password="$(random_password)"
    owner_password="$(random_password)"
    jwt_key="$(openssl rand -base64 48 | tr -d '\n')"

    {
        printf '%s\n' \
            "GROUPED_APP_DATA_ROOT=$DATA_ROOT" \
            "GROUPED_APP_IMAGE=$IMAGE" \
            "GROUPED_APP_IMAGE_TAG=$image_tag" \
            "APP_PORT=$app_port" \
            'TZ=Europe/Berlin' \
            'LICENSE_MANAGER_BASE_URL=https://license.team-netz.net:5181' \
            "LICENSE_CUSTOMER_NAME=$customer_name" \
            'LICENSE_MANAGER_ALLOW_INVALID_CERTIFICATE=false' \
            'MSSQL_PID=Express' \
            "DB_SA_PASSWORD=$sa_password" \
            "JWT_SIGNING_KEY=$jwt_key" \
            "BOOTSTRAP_ADMIN_EMAIL=$owner_email" \
            "BOOTSTRAP_ADMIN_PASSWORD=$owner_password"
    } > "$env_file"
    chmod 0600 "$env_file"

    credentials_file="$INSTALL_ROOT/ERSTANMELDUNG.txt"
    {
        printf 'GroupedApplication-Erstanmeldung\nURL: https://<DNS-Name des Reverse Proxys>/admin\n'
        printf 'Direkt (nur intern): http://<Host>:%s/admin\nBenutzer: %s\nPasswort: %s\n' \
            "$app_port" "$owner_email" "$owner_password"
        printf '\nDanach unter /admin im Reiter "Lizenz" den Aktivierungscode eingeben.\n'
        printf 'Diese Datei nach erfolgreicher Anmeldung sicher loeschen.\n'
    } > "$credentials_file"
    chmod 0600 "$credentials_file"
    printf 'Erstanmeldedaten wurden unter %s gespeichert.\n' "$credentials_file"
else
    printf 'Vorhandene Konfiguration %s wird beibehalten.\n' "$env_file"
    # A .env carried over from a source-build installation lacks the image settings.
    ensure_env_value GROUPED_APP_DATA_ROOT "$DATA_ROOT"
    ensure_env_value GROUPED_APP_IMAGE "$IMAGE"
    ensure_env_value GROUPED_APP_IMAGE_TAG "$default_tag"
    # Installations from before the license check have no license settings yet.
    ensure_env_value LICENSE_MANAGER_BASE_URL 'https://license.team-netz.net:5181'
    ensure_env_value LICENSE_MANAGER_ALLOW_INVALID_CERTIFICATE false
    if [[ -z "$(env_value LICENSE_CUSTOMER_NAME)" ]]; then
        prompt_required customer_name 'Lizenz-Kundenname (wie im License Manager): '
        sed -i '/^LICENSE_CUSTOMER_NAME=/d' "$env_file"
        printf 'LICENSE_CUSTOMER_NAME=%s\n' "$customer_name" >> "$env_file"
    fi

    current_tag="$(env_value GROUPED_APP_IMAGE_TAG)"
    if [[ "$current_tag" != "$default_tag" ]]; then
        read -r -p "Container-Version von $current_tag auf $default_tag aktualisieren? [j/N] " confirmation
        if [[ "$confirmation" =~ ^[jJyY]$ ]]; then
            sed -E -i "s|^GROUPED_APP_IMAGE_TAG=.*$|GROUPED_APP_IMAGE_TAG=${default_tag}|" "$env_file"
        fi
    fi
fi

cd "$INSTALL_ROOT"
docker compose config --quiet
docker compose pull
docker compose up -d --no-build --remove-orphans
docker compose ps

printf '\nInstallation abgeschlossen (Version %s).\n' "$(env_value GROUPED_APP_IMAGE_TAG)"
printf 'Konfiguration: %s\nDaten: %s\n' "$env_file" "$DATA_ROOT"
printf 'Eigene CA-Zertifikate: %s/certs (danach: docker compose restart app)\n' "$DATA_ROOT"
printf 'Lizenz: nach der Anmeldung unter /admin im Reiter "Lizenz" aktivieren.\n'
printf 'Status: cd %s && docker compose ps\n' "$INSTALL_ROOT"
printf 'Logs:   cd %s && docker compose logs -f\n' "$INSTALL_ROOT"
