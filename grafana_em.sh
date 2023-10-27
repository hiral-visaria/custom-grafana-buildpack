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


###


get_binding_service() {
    local binding_name="${1}"
    jq --arg b "${binding_name}" '.[][] | select(.binding_name == $b)' <<<"${VCAP_SERVICES}"
}


get_db_vcap_service() {
    local binding_name="${1}"

    if [[ -z "${binding_name}" ]] || [[ "${binding_name}" == "null" ]]
    then
        # search for a sql service looking at the label
        jq '[.[][] | select(.credentials.uri) | select(.credentials.uri | split(":")[0] == ("mysql","postgres","postgresql"))] | first | select (.!=null)' <<<"${VCAP_SERVICES}"
    else
        get_binding_service "${binding_name}"
    fi
}


# Sets all DB
set_sql_databases() {
    local db

    echo "Initializing DB settings for EM ..."

    db=$(get_db_vcap_service "${DB_BINDING_NAME}")
    if [[ -n "${db}" ]]
    then
        set_vcap_datasource_postgres "${db}" >/dev/null
    fi
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

run_grafana_server() {
    echo "Launching grafana server ..."
    pushd "${GRAFANA_ROOT}" >/dev/null
        if [[ -f "${GRAFANA_CFG_INI}" ]]
        then
            launch grafana-server -config=${GRAFANA_CFG_INI}
        else
            launch grafana-server
        fi
    popd
}


################################################################################

set_sql_databases

# Run
run_grafana_server &
# Set home dashboard only on the first instance
[[ "${CF_INSTANCE_INDEX:-0}" == "0" ]] && set_homedashboard
# Go back to grafana_server and keep waiting, exit whit its exit code
wait
