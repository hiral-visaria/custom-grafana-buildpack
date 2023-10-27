#!/usr/bin/env bash
[ -z "$DEBUG" ] || set -x
set -euo pipefail

# See bin/finalize to check predefined vars
ROOT="/home/vcap"
export AUTH_ROOT="${ROOT}/auth"
#export GRAFANA_ROOT=$(find ${ROOT}/deps -name grafana -type d -maxdepth 2)
export GRAFANA_ROOT=$GRAFANA_ROOT
#export SQLPROXY_ROOT=$(find ${ROOT}/deps -name cloud_sql_proxy -type d -maxdepth 2)
export SQLPROXY_ROOT=$SQLPROXY_ROOT
export APP_ROOT="${ROOT}/app"
export GRAFANA_CFG_INI="${ROOT}/app/grafana.ini"
export GRAFANA_CFG_PLUGINS="${ROOT}/app/plugins.txt"
export GRAFANA_POST_START="${ROOT}/app/post-start.sh"
export PATH=${PATH}:${GRAFANA_ROOT}/bin:${SQLPROXY_ROOT}

### Bindings
# SQL DB
export DB_BINDING_NAME="${DB_BINDING_NAME:-}"

# Exported variables used in default.ini config file
export DOMAIN=${DOMAIN:-$(jq -r '.uris[0]' <<<"${VCAP_APPLICATION}")}
export URL="${URL:-http://$DOMAIN/}"
export HOME_DASHBOARD_UID="${HOME_DASHBOARD_UID:-home}"
export HOME_ORG_ID="${HOME_ORG_ID:-1}"
export ADMIN_USER="${ADMIN_USER:-admin}"
export ADMIN_PASS="${ADMIN_PASS:-admin}"
export EMAIL="${EMAIL:-grafana@$DOMAIN}"
export SECRET_KEY="${SECRET_KEY:-}"
export DEFAULT_DATASOURCE_EDITABLE="${DEFAULT_DATASOURCE_EDITABLE:-false}"
export DEFAULT_DATASOURCE_TIMEINTERVAL="${DEFAULT_DATASOURCE_TIMEINTERVAL:-60s}"

# Variables exported, they are automatically filled from the
# service broker instances.
# See reset_DB for default values!
export DB_TYPE="sqlite3"
export DB_USER="root"
export DB_HOST=""
export DB_PASS=""
export DB_PORT=""
export DB_NAME="grafana"
export DB_CA_CERT=""
export DB_CLIENT_CERT=""
export DB_CLIENT_KEY=""
export DB_CERT_NAME=""
export DB_TLS=""

###

# exec process in bg
launch() {
  (
    echo "Launching pid=$$: '$@'"
    {
      exec $@ 2>&1
    }
  ) &
  pid=$!
  sleep 15
  if ! ps -p ${pid} >/dev/null 2>&1; then
    echo
    echo "Error launching '$@'."
    rvalue=1
  else
    echo "Pid=${pid} running"
    rvalue=0
  fi
  return ${rvalue}
}

random_string() {
  (
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1 || true
  )
}

get_binding_service() {
  local binding_name="${1}"
  jq --arg b "${binding_name}" '.[][] | select(.binding_name == $b)' <<<"${VCAP_SERVICES}"
}

get_db_vcap_service() {
  local binding_name="${1}"

  if [[ -z "${binding_name}" ]] || [[ "${binding_name}" == "null" ]]; then
    # search for a sql service looking at the label
    jq '[.[][] | select(.credentials.uri) | select(.credentials.uri | split(":")[0] == ("mysql","postgres","postgresql"))] | first | select (.!=null)' <<<"${VCAP_SERVICES}"
  else
    get_binding_service "${binding_name}"
  fi
}

get_db_vcap_service_type() {
  local db="${1}"
  jq -r '.credentials.uri | split(":")[0]' <<<"${db}"
}

reset_env_DB() {
  DB_TYPE="sqlite3"
  DB_USER="root"
  DB_HOST=""
  DB_PASS=""
  DB_PORT=""
  DB_NAME="grafana"
  DB_CA_CERT=""
  DB_CLIENT_CERT=""
  DB_CLIENT_KEY=""
  DB_CERT_NAME=""
  DB_TLS=""
}

set_env_DB() {
  local db="${1}"
  local uri=""

  DB_TYPE=$(get_db_vcap_service_type "${db}")
  if [[ $DB_TYPE == "postgresql" ]]; then
    DB_TYPE="postgres"
  fi

  uri="${DB_TYPE}://"
  if ! DB_USER=$(jq -r -e '.credentials.username' <<<"${db}"); then
    DB_USER=$(jq -r -e '.credentials.uri |
            split("://")[1] | split(":")[0]' <<<"${db}") || DB_USER=''
  fi
  uri="${uri}${DB_USER}"
  if ! DB_PASS=$(jq -r -e '.credentials.password' <<<"${db}"); then
    DB_PASS=$(jq -r -e '.credentials.uri |
            split("://")[1] | split(":")[1] |
            split("@")[0]' <<<"${db}") || DB_PASS=''
  fi
  uri="${uri}:${DB_PASS}"
  if ! DB_HOST=$(jq -r -e '.credentials.hostname' <<<"${db}"); then
    DB_HOST=$(jq -r -e '.credentials.uri |
            split("://")[1] | split(":")[1] |
            split("@")[1] |
            split(":")[0]' <<<"${db}") || DB_HOST=''
  fi
  uri="${uri}@${DB_HOST}"
  if [[ "${DB_TYPE}" == "mysql" ]]; then
    DB_PORT="3306"
    uri="${uri}:${DB_PORT}"
    DB_TLS="false"
  elif [[ "${DB_TYPE}" == "postgres" ]]; then
    if ! DB_PORT=$(jq -r -e '.credentials.port' <<<"${db}"); then
      DB_PORT=$(jq -r -e '.credentials.uri |
            split("://")[1] | split(":")[1] |
            split("@")[1] | split(":")[1] | split("/")[0]' <<<"${db}") || DB_PORT='' 
    fi
    uri="${uri}:${DB_PORT}"
    DB_TLS="disable"
  fi
  if ! DB_NAME=$(jq -r -e '.credentials.database_name' <<<"${db}"); then
    DB_NAME=$(jq -r -e '.credentials.uri |
            split("://")[1] | split("/")[1]' <<<"${db}") || DB_NAME=''
  fi
  uri="${uri}/${DB_NAME}"

  # TLS
  mkdir -p ${AUTH_ROOT}
  if jq -r -e '.credentials.ClientCert' <<<"${db}" >/dev/null; then
    jq -r '.credentials.CaCert' <<<"${db}" >"${AUTH_ROOT}/${DB_NAME}-ca.crt"
    jq -r '.credentials.ClientCert' <<<"${db}" >"${AUTH_ROOT}/${DB_NAME}-client.crt"
    jq -r '.credentials.ClientKey' <<<"${db}" >"${AUTH_ROOT}/${DB_NAME}-client.key"
    DB_CA_CERT="${AUTH_ROOT}/${DB_NAME}-ca.crt"
    DB_CLIENT_CERT="${AUTH_ROOT}/${DB_NAME}-client.crt"
    DB_CLIENT_KEY="${AUTH_ROOT}/${DB_NAME}-client.key"
    if instance=$(jq -r -e '.credentials.instance_name' <<<"${db}"); then
      DB_CERT_NAME="${instance}"
      if project=$(jq -r -e '.credentials.ProjectId' <<<"${db}"); then
        # Google GCP format
        DB_CERT_NAME="${project}:${instance}"
      fi
      [[ "${DB_TYPE}" == "mysql" ]] && DB_TLS="true"
      [[ "${DB_TYPE}" == "postgres" ]] && DB_TLS="verify-full"
    else
      DB_CERT_NAME=""
      [[ "${DB_TYPE}" == "mysql" ]] && DB_TLS="skip-verify"
      [[ "${DB_TYPE}" == "postgres" ]] && DB_TLS="require"
    fi
  fi

  # SSL
  if jq -r -e '.credentials.sslcert' <<<"${db}" >/dev/null; then
    if instance=$(jq -r -e '.credentials.instance_name' <<<"${db}"); then
      DB_CERT_NAME="${instance}"
      if project=$(jq -r -e '.credentials.ProjectId' <<<"${db}"); then
        # Google GCP format
        DB_CERT_NAME="${project}:${instance}"
      fi
      [[ "${DB_TYPE}" == "mysql" ]] && DB_TLS="true"
      [[ "${DB_TYPE}" == "postgres" ]] && DB_TLS="verify-full"
    else
      DB_CERT_NAME=""
      [[ "${DB_TYPE}" == "mysql" ]] && DB_TLS="skip-verify"
      [[ "${DB_TYPE}" == "postgres" ]] && DB_TLS="require"
    fi
  fi

  echo "${uri}"
}

set_vcap_datasource_postgres() {
  local datasource="${1}"

  local hostname=$(jq -r -e '.credentials.uri | split("://")[1] | split(":")[1] | split("@")[1] | split(":")[0]' <<<"${datasource}")
  local port=$(jq -r -e '.credentials.port' <<<"${datasource}")
  local url="${hostname}:${port}"
  local user=$(jq -r '.credentials.username | select (.!=null)' <<<"${datasource}")
  local pass=$(jq -r '.credentials.password | select (.!=null)' <<<"${datasource}")
  local dbname=$(jq -r '.credentials.dbname | select (.!=null)' <<<"${datasource}")
  mkdir -p "${APP_ROOT}/datasources"

  # Be careful, this is a HERE doc with tabs indentation!!
  cat <<-EOF >"${APP_ROOT}/datasources/postgres.yml"
	apiVersion: 1

	datasources:
- name: Postgres
  type: postgres
  editable: false
  allowUiUpdates: false
  uid: my-postgres-db
  url: ${url}
  user: ${user}
  database: ${dbname}
  jsonData:
    sslmode: require
  secureJsonData:
    password: ${pass}
	EOF
}

# Sets all DB
set_sql_databases() {
  local db

  echo "Initializing DB settings from service instances ..."
  reset_env_DB

  db=$(get_db_vcap_service "${DB_BINDING_NAME}")

  if [[ -n "${db}" ]]; then
    set_env_DB "${db}" >/dev/null
    set_vcap_datasource_postgres "${db}" >/dev/null
  fi
}

set_seed_secrets() {
  if [[ -z "${SECRET_KEY}" ]]; then
    # Take it from the space_id. It is not random!
    export SECRET_KEY=$(jq -r '.space_id' <<<"${VCAP_APPLICATION}")
    echo "######################################################################"
    echo "WARNING: SECRET_KEY environment variable not defined!"
    echo "Used for signing some datasource settings like secrets and passwords."
    echo "Cannot be changed without requiring an update to datasource settings to re-encode them."
    echo "Please define it in grafana.ini or using an environment variable!"
    echo "Generated SECRET_KEY=${SECRET_KEY}"
    echo "######################################################################"
  fi
}

install_grafana_plugins() {
  echo "Initializing plugins from ${GRAFANA_CFG_PLUGINS} ..."
  if [[ -f "${GRAFANA_CFG_PLUGINS}" ]]; then
    while read -r pluginid pluginversion; do
      if [[ -n "${pluginid}" ]]; then
        echo "Installing ${pluginid} ${pluginversion} ..."
        grafana-cli --pluginsDir "$GF_PATHS_PLUGINS" plugins install ${pluginid} ${pluginversion}
      fi
    done <<<$(grep -v '^#' "${GRAFANA_CFG_PLUGINS}")
  fi
}

run_sql_proxies() {
  local instance
  local dbname

  if [[ -d ${AUTH_ROOT} ]]; then
    for filename in $(find ${AUTH_ROOT} -name '*.proxy'); do
      dbname=$(basename "${filename}" | sed -n 's/^\(.*\)\.proxy$/\1/p')
      instance=$(head "${filename}")
      echo "Launching local sql proxy for instance ${instance} ..."
      launch cloud_sql_proxy -verbose \
        -instances="${instance}" \
        -credential_file="${AUTH_ROOT}/${dbname}-auth.json" \
        -term_timeout=30s -ip_address_types=PRIVATE,PUBLIC
    done
  fi
}

run_grafana_server() {
  echo "Launching grafana server ..."
  pushd "${GRAFANA_ROOT}" >/dev/null
  if [[ -f "${GRAFANA_CFG_INI}" ]]; then
    launch grafana-server -config=${GRAFANA_CFG_INI}
  else
    launch grafana-server
  fi
  popd
}

set_homedashboard() {
  local dashboard_httpcode=()
  local dashboard_id
  local counter=30
  local status=0

  while [[ ${counter} -gt 0 ]]; do
    if status=$(curl -s -o /dev/null -w '%{http_code}' \
      -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -H "X-Grafana-Org-Id: ${HOME_ORG_ID}" \
      "http://127.0.0.1:${PORT}/api/org/preferences"); then
      [[ ${status} -eq 200 ]] && break
    fi
    sleep 2
    counter=$((counter - 1))
  done
  if [[ ${status} -eq 200 ]]; then
    readarray -t dashboard_httpcode <<<$(
      curl -s -w "\n%{response_code}\n" \
        -u "${ADMIN_USER}:${ADMIN_PASS}" \
        "http://127.0.0.1:${PORT}/api/dashboards/uid/${HOME_DASHBOARD_UID}"
    )
    if [[ "${dashboard_httpcode[1]}" -eq 200 ]]; then
      dashboard_id=$(jq '.dashboard.id' <<<"${dashboard_httpcode[0]}")
      output=$(curl -s -X PUT -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -H 'Content-Type: application/json;charset=UTF-8' \
        -H "X-Grafana-Org-Id: ${HOME_ORG_ID}" \
        --data-binary "{\"homeDashboardId\": ${dashboard_id}}" \
        "http://127.0.0.1:${PORT}/api/org/preferences")
      echo "Defined default home dashboard id ${dashboard_id} for org ${HOME_ORG_ID}: ${output}"
    elif [[ "${dashboard_httpcode[1]}" -eq 404 ]]; then
      echo "No default home dashboard for org ${HOME_ORG_ID} has been found"
    else
      echo "Error setting default HOME dashboard: ${dashboard_httpcode[0]}"
    fi
  else
    echo "Error setting querying preferences to set default dashboard: ${status}"
  fi
}

################################################################################

set_sql_databases
set_seed_secrets

# Run
install_grafana_plugins
run_sql_proxies
run_grafana_server &
# Set home dashboard only on the first instance
[[ "${CF_INSTANCE_INDEX:-0}" == "0" ]] && set_homedashboard
# Go back to grafana_server and keep waiting, exit whit its exit code
wait
