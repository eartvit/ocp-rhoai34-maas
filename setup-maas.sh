#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/setup-maas.conf"
TRACKER_FILE="${SCRIPT_DIR}/setup-maas.tracker.json"
RESET_REQUESTED="false"

for arg in "$@"; do
  case "${arg}" in
    config=*) CONFIG_FILE="${arg#config=}" ;;
    reset=true|RESET=true) RESET_REQUESTED="true" ;;
    reset=false|RESET=false) RESET_REQUESTED="false" ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Supported arguments: config=/path/to/setup-maas.conf reset=true" >&2
      exit 1
      ;;
  esac
done

if [[ "${reset:-false}" == "true" || "${RESET:-false}" == "true" ]]; then
  RESET_REQUESTED="true"
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

###############################################################################
# Generic helpers
###############################################################################

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

warn() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2
}

die() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

as_bool() {
  case "${1:-false}" in
    true|TRUE|True|yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

need_cmd oc
need_cmd python3

if as_bool "${MAAS_VALIDATE_API_HEALTH:-true}"; then
  need_cmd curl
fi

if [[ "${RESET_REQUESTED}" == "true" ]]; then
  log "reset=true requested; removing tracker file only: ${TRACKER_FILE}"
  rm -f "${TRACKER_FILE}"
fi

init_tracker() {
  if [[ ! -f "${TRACKER_FILE}" ]]; then
    cat > "${TRACKER_FILE}" <<EOF_TRACKER
{
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "steps": {}
}
EOF_TRACKER
  fi
}

step_done() {
  local step="$1"

  python3 - "${TRACKER_FILE}" "${step}" <<'PY_STEP_DONE'
import json
import pathlib
import sys

tracker = pathlib.Path(sys.argv[1])
step = sys.argv[2]

if not tracker.exists():
    sys.exit(1)

data = json.loads(tracker.read_text())
status = data.get("steps", {}).get(step, {}).get("status")
sys.exit(0 if status == "done" else 1)
PY_STEP_DONE
}

mark_step_done() {
  local step="$1"

  python3 - "${TRACKER_FILE}" "${step}" <<'PY_MARK_DONE'
import datetime
import json
import pathlib
import sys

tracker = pathlib.Path(sys.argv[1])
step = sys.argv[2]

if tracker.exists():
    data = json.loads(tracker.read_text())
else:
    data = {"steps": {}}

data.setdefault("steps", {})[step] = {
    "status": "done",
    "completed_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}

tracker.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY_MARK_DONE
}

run_step() {
  local step="$1"
  shift

  if step_done "${step}"; then
    log "SKIP ${step}"
    return 0
  fi

  log "START ${step}"
  "$@"
  mark_step_done "${step}"
  log "DONE ${step}"
}

wait_until() {
  local description="$1"
  local timeout="$2"
  local interval="$3"
  local command="$4"

  local start now elapsed
  start="$(date +%s)"

  while true; do
    if bash -lc "${command}" >/dev/null 2>&1; then
      log "Ready: ${description}"
      return 0
    fi

    now="$(date +%s)"
    elapsed=$(( now - start ))

    if (( elapsed >= timeout )); then
      die "Timed out waiting for: ${description}"
    fi

    log "Waiting for: ${description} (${elapsed}s/${timeout}s)"
    sleep "${interval}"
  done
}

ensure_namespace() {
  local ns="$1"
  oc get namespace "${ns}" >/dev/null 2>&1 || oc create namespace "${ns}"
}

###############################################################################
# OLM helpers for optional MaaS observability operators
###############################################################################

split_candidates() {
  echo "$1" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$'
}

package_source_matches() {
  local package="$1"
  local source="$2"

  if [[ -z "${source}" ]]; then
    return 0
  fi

  local found_source
  found_source="$(oc get packagemanifest "${package}" -n openshift-marketplace -o jsonpath='{.status.catalogSource}' 2>/dev/null || true)"
  [[ "${found_source}" == "${source}" ]]
}

find_package_from_candidates() {
  local candidates="$1"
  local source="$2"

  local pkg
  while read -r pkg; do
    [[ -z "${pkg}" ]] && continue

    if oc get packagemanifest "${pkg}" -n openshift-marketplace >/dev/null 2>&1; then
      if package_source_matches "${pkg}" "${source}"; then
        echo "${pkg}"
        return 0
      fi
    fi
  done < <(split_candidates "${candidates}")

  return 1
}

default_channel_for_package() {
  local package="$1"
  oc get packagemanifest "${package}" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true
}

catalog_source_for_package() {
  local package="$1"
  oc get packagemanifest "${package}" -n openshift-marketplace -o jsonpath='{.status.catalogSource}' 2>/dev/null || true
}

ensure_operatorgroup() {
  local ns="$1"
  local name="$2"
  local mode="$3"

  ensure_namespace "${ns}"

  local existing_count
  existing_count="$(oc get operatorgroup -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  if [[ "${existing_count}" != "0" ]]; then
    local existing_name
    local existing_targets
    existing_name="$(oc get operatorgroup -n "${ns}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    existing_targets="$(oc get operatorgroup -n "${ns}" -o jsonpath='{range .items[0].spec.targetNamespaces[*]}{.}{" "}{end}' 2>/dev/null || true)"

    if [[ "${mode}" == "all" && -n "${existing_targets// /}" ]]; then
      die "OperatorGroup ${ns}/${existing_name} targets namespace(s) '${existing_targets}', but this operator requires AllNamespaces mode. Delete/recreate that OperatorGroup or use a clean namespace."
    fi

    if [[ "${mode}" != "all" && "${existing_targets}" != *"${ns}"* ]]; then
      die "OperatorGroup ${ns}/${existing_name} does not target ${ns}. Refusing to reuse it."
    fi

    log "OperatorGroup already exists in ${ns}; reusing ${existing_name} (mode=${mode})."
    return 0
  fi

  log "Creating OperatorGroup ${ns}/${name} mode=${mode}"

  if [[ "${mode}" == "all" ]]; then
    cat <<EOF_OPERATORGROUP | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${name}
  namespace: ${ns}
spec: {}
EOF_OPERATORGROUP
  else
    cat <<EOF_OPERATORGROUP | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  targetNamespaces:
  - ${ns}
EOF_OPERATORGROUP
  fi
}

current_csv_for_package_channel() {
  local package="$1"
  local channel="$2"

  oc get packagemanifest "${package}" -n openshift-marketplace     -o jsonpath="{range .status.channels[?(@.name==\"${channel}\")]}{.currentCSV}{end}" 2>/dev/null || true
}

csv_phase() {
  local ns="$1"
  local csv="$2"

  [[ -n "${csv}" ]] || return 0
  oc get csv "${csv}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

wait_for_operator_csv_succeeded() {
  local label="$1"
  local ns="$2"
  local package="$3"
  local channel="$4"
  local subscription_name="$5"
  local timeout="${6:-1800}"
  local interval="${7:-30}"

  local start now elapsed installed_csv current_csv installed_phase current_phase resolution_failed resolution_msg
  start="$(date +%s)"

  while true; do
    installed_csv="$(oc get subscription -n "${ns}" "${subscription_name}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    current_csv="$(current_csv_for_package_channel "${package}" "${channel}")"

    installed_phase="$(csv_phase "${ns}" "${installed_csv}")"
    current_phase="$(csv_phase "${ns}" "${current_csv}")"

    if [[ -n "${installed_csv}" && "${installed_phase}" == "Succeeded" ]]; then
      log "Ready: CSV Succeeded for ${label}: source=subscription.installedCSV, namespace=${ns}, csv=${installed_csv}, phase=${installed_phase}"
      return 0
    fi

    if [[ -n "${current_csv}" && "${current_phase}" == "Succeeded" ]]; then
      log "Ready: CSV Succeeded for ${label}: source=packagemanifest.currentCSV, namespace=${ns}, csv=${current_csv}, phase=${current_phase}"
      return 0
    fi

    now="$(date +%s)"
    elapsed=$(( now - start ))

    if (( elapsed >= timeout )); then
      resolution_failed="$(oc get subscription -n "${ns}" "${subscription_name}" -o jsonpath='{range .status.conditions[?(@.type=="ResolutionFailed")]}{.status}{end}' 2>/dev/null || true)"
      resolution_msg="$(oc get subscription -n "${ns}" "${subscription_name}" -o jsonpath='{range .status.conditions[?(@.type=="ResolutionFailed")]}{.reason}{": "}{.message}{end}' 2>/dev/null || true)"
      die "Timed out waiting for CSV Succeeded for ${label}. installedCSV=${installed_csv:-none}/${installed_phase:-unknown}; currentCSV=${current_csv:-none}/${current_phase:-unknown}; ResolutionFailed=${resolution_failed:-false}; ${resolution_msg}"
    fi

    resolution_failed="$(oc get subscription -n "${ns}" "${subscription_name}" -o jsonpath='{range .status.conditions[?(@.type=="ResolutionFailed")]}{.status}{end}' 2>/dev/null || true)"
    if [[ "${resolution_failed}" == "True" && -n "${current_csv}" ]]; then
      warn "Subscription ${ns}/${subscription_name} currently has ResolutionFailed, but currentCSV=${current_csv}/${current_phase:-unknown}; continuing to wait for the existing CSV instead of installedCSV."
    fi

    log "Waiting for CSV Succeeded for ${label}: installedCSV=${installed_csv:-none}/${installed_phase:-unknown}; currentCSV=${current_csv:-none}/${current_phase:-unknown} (${elapsed}s/${timeout}s)"
    sleep "${interval}"
  done
}

install_operator() {
  local label="$1"
  local ns="$2"
  local package_candidates="$3"
  local channel="$4"
  local source="$5"
  local subscription_name="$6"
  local operatorgroup_mode="$7"
  local approval="${8:-Automatic}"

  local package
  package="$(find_package_from_candidates "${package_candidates}" "${source}")" || {
    die "Could not find package for ${label}. Candidates=${package_candidates}, source=${source}"
  }

  if [[ -z "${channel}" ]]; then
    channel="$(default_channel_for_package "${package}")"
  fi
  [[ -n "${channel}" ]] || die "Could not determine channel for package ${package}"

  if [[ -z "${source}" ]]; then
    source="$(catalog_source_for_package "${package}")"
  fi

  # Idempotency rule: ask the cluster first.  If the package's current CSV is
  # already present and Succeeded in the intended namespace, the operator is
  # installed enough for this script and we must not re-apply a Subscription that
  # can put OLM into ResolutionFailed on already-installed AllNamespaces CSVs.
  local existing_csv existing_phase
  existing_csv="$(current_csv_for_package_channel "${package}" "${channel}")"
  existing_phase="$(csv_phase "${ns}" "${existing_csv}")"

  if [[ -n "${existing_csv}" && "${existing_phase}" == "Succeeded" ]]; then
    log "Ready: ${label} already installed: namespace=${ns}, package=${package}, channel=${channel}, csv=${existing_csv}"
    return 0
  fi

  ensure_operatorgroup "${ns}" "${subscription_name}-operatorgroup" "${operatorgroup_mode}"

  if oc get subscription "${subscription_name}" -n "${ns}" >/dev/null 2>&1; then
    log "Subscription ${ns}/${subscription_name} already exists; leaving it in place and waiting for CSV success."
  else
    log "Applying ${label} Subscription: package=${package}, channel=${channel}, source=${source}, namespace=${ns}, subscription=${subscription_name}"

    cat <<EOF_SUBSCRIPTION | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${subscription_name}
  namespace: ${ns}
spec:
  channel: ${channel}
  installPlanApproval: ${approval}
  name: ${package}
  source: ${source}
  sourceNamespace: openshift-marketplace
EOF_SUBSCRIPTION
  fi

  wait_for_operator_csv_succeeded "${label}" "${ns}" "${package}" "${channel}" "${subscription_name}" 1800 30
}

###############################################################################
# Discovery helpers
###############################################################################

detect_apps_domain() {
  if [[ -n "${MAAS_APPS_DOMAIN:-}" ]]; then
    echo "${MAAS_APPS_DOMAIN}"
    return 0
  fi

  local domain
  domain="$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}' 2>/dev/null || true)"
  [[ -n "${domain}" ]] || die "Could not auto-detect apps domain from ingresscontroller/default. Set MAAS_APPS_DOMAIN or MAAS_HOST."
  echo "${domain}"
}

maas_host() {
  if [[ -n "${MAAS_HOST:-}" ]]; then
    echo "${MAAS_HOST}"
    return 0
  fi

  echo "maas.$(detect_apps_domain)"
}

###############################################################################
# Step 0: Preflight
###############################################################################

preflight_check() {
  oc whoami >/dev/null

  local version
  version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
  log "OpenShift version: ${version:-unknown}"

  if [[ -n "${REQUIRED_OPENSHIFT_MINOR:-}" && "${version}" != ${REQUIRED_OPENSHIFT_MINOR}* ]]; then
    warn "Expected OpenShift minor ${REQUIRED_OPENSHIFT_MINOR}, detected ${version}. Continuing because this may still be compatible."
  fi

  local rhoai_csv
  rhoai_csv="$(oc get subscription -n "${RHOAI_OPERATOR_NAMESPACE}" rhods-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  [[ -n "${rhoai_csv}" ]] || die "RHOAI subscription installedCSV not found in ${RHOAI_OPERATOR_NAMESPACE}."

  if ! [[ "${rhoai_csv}" =~ ${REQUIRED_RHOAI_CSV_REGEX} ]]; then
    die "RHOAI CSV '${rhoai_csv}' does not match required regex '${REQUIRED_RHOAI_CSV_REGEX}'."
  fi

  log "RHOAI CSV verified: ${rhoai_csv}"

  wait_until "DSCInitialization ${DSCI_NAME} Ready" 600 15 \
    "test \"\$(oc get dscinitialization '${DSCI_NAME}' -o jsonpath='{.status.phase}' 2>/dev/null)\" = Ready"

  if [[ -n "${REQUIRED_RHCL_CSV:-}" ]]; then
    if ! oc get csv -A --no-headers | awk -v required="${REQUIRED_RHCL_CSV}" '$2 == required && $NF == "Succeeded" { found=1 } END { exit(found ? 0 : 1) }'; then
      die "Required RHCL CSV not found or not Succeeded: ${REQUIRED_RHCL_CSV}"
    fi
    log "RHCL CSV verified: ${REQUIRED_RHCL_CSV}"
  fi

  oc get kuadrant -n "${KUADRANT_NAMESPACE}" "${KUADRANT_NAME}" >/dev/null 2>&1 || die "Kuadrant ${KUADRANT_NAMESPACE}/${KUADRANT_NAME} not found."

  oc get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 || die "CloudNativePG CRD clusters.postgresql.cnpg.io not found."
  oc get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 || die "Gateway API CRD gateways.gateway.networking.k8s.io not found."
  oc get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1 || die "Gateway API CRD gatewayclasses.gateway.networking.k8s.io not found."

  if as_bool "${GPU_REQUIRED:-true}"; then
    if ! oc get nodes -o json | GPU_RESOURCE="${GPU_RESOURCE_NAME}" python3 -c '
import json
import os
import sys
resource = os.environ["GPU_RESOURCE"]
data = json.load(sys.stdin)
for node in data.get("items", []):
    alloc = node.get("status", {}).get("allocatable", {}) or {}
    if alloc.get(resource) not in (None, "0"):
        sys.exit(0)
sys.exit(1)
'; then
      die "No node advertises ${GPU_RESOURCE_NAME}."
    fi

    log "GPU resource verified: ${GPU_RESOURCE_NAME}"
  fi

  log "Preflight checks passed."
}

###############################################################################
# Step 1: Observability and monitoring
###############################################################################

configure_observability() {
  if as_bool "${ENABLE_USER_WORKLOAD_MONITORING:-true}"; then
    log "Configuring monitoring according to the referenced GitHub monitoring chart."
    log "This creates only cluster-monitoring-config and user-workload-monitoring-config."

    cat <<EOF_CLUSTER_MONITORING | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
    prometheusK8s:
      retention: ${CLUSTER_MONITORING_PROMETHEUS_RETENTION:-168h}
      volumeClaimTemplate:
        spec:
          storageClassName: ${CLUSTER_MONITORING_STORAGE_CLASS:-gp3-csi}
          volumeMode: Filesystem
          resources:
            requests:
              storage: ${CLUSTER_MONITORING_STORAGE_SIZE:-40Gi}
EOF_CLUSTER_MONITORING

    ensure_namespace openshift-user-workload-monitoring

    cat <<EOF_UWM | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    prometheus:
      retention: ${UWM_PROMETHEUS_RETENTION:-72h}
      volumeClaimTemplate:
        spec:
          storageClassName: ${UWM_PROMETHEUS_STORAGE_CLASS:-gp3-csi}
          volumeMode: Filesystem
          resources:
            requests:
              storage: ${UWM_PROMETHEUS_STORAGE_SIZE:-40Gi}
EOF_UWM
  else
    log "ENABLE_USER_WORKLOAD_MONITORING=false; skipping monitoring ConfigMaps."
  fi

  if as_bool "${MAAS_ENABLE_OBSERVABILITY:-true}"; then
    log "Configuring official RHOAI/MaaS observability prerequisites."

    if as_bool "${MAAS_INSTALL_CLUSTER_OBSERVABILITY_OPERATOR:-true}"; then
      ensure_namespace "${CLUSTER_OBSERVABILITY_OPERATOR_NAMESPACE}"
      if as_bool "${MAAS_LABEL_OBSERVABILITY_OPERATOR_NAMESPACES:-true}"; then
        oc label namespace "${CLUSTER_OBSERVABILITY_OPERATOR_NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite
      fi
      install_operator \
        "Cluster Observability Operator" \
        "${CLUSTER_OBSERVABILITY_OPERATOR_NAMESPACE}" \
        "${CLUSTER_OBSERVABILITY_OPERATOR_PACKAGE}" \
        "${CLUSTER_OBSERVABILITY_OPERATOR_CHANNEL}" \
        "${CLUSTER_OBSERVABILITY_OPERATOR_SOURCE}" \
        "${CLUSTER_OBSERVABILITY_OPERATOR_SUBSCRIPTION_NAME}" \
        "${CLUSTER_OBSERVABILITY_OPERATORGROUP_MODE:-all}"
    else
      log "MAAS_INSTALL_CLUSTER_OBSERVABILITY_OPERATOR=false; assuming Cluster Observability Operator is already installed."
    fi

    if as_bool "${MAAS_INSTALL_TEMPO_OPERATOR:-true}"; then
      ensure_namespace "${TEMPO_OPERATOR_NAMESPACE}"
      if as_bool "${MAAS_LABEL_OBSERVABILITY_OPERATOR_NAMESPACES:-true}"; then
        oc label namespace "${TEMPO_OPERATOR_NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite
      fi
      install_operator \
        "Tempo Operator" \
        "${TEMPO_OPERATOR_NAMESPACE}" \
        "${TEMPO_OPERATOR_PACKAGE}" \
        "${TEMPO_OPERATOR_CHANNEL}" \
        "${TEMPO_OPERATOR_SOURCE}" \
        "${TEMPO_OPERATOR_SUBSCRIPTION_NAME}" \
        "${TEMPO_OPERATOR_OPERATORGROUP_MODE:-all}"
    else
      log "MAAS_INSTALL_TEMPO_OPERATOR=false; assuming Tempo Operator is already installed."
    fi

    if as_bool "${MAAS_INSTALL_OPENTELEMETRY_OPERATOR:-true}"; then
      ensure_namespace "${OPENTELEMETRY_OPERATOR_NAMESPACE}"
      if as_bool "${MAAS_LABEL_OBSERVABILITY_OPERATOR_NAMESPACES:-true}"; then
        oc label namespace "${OPENTELEMETRY_OPERATOR_NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite
      fi
      install_operator \
        "Red Hat build of OpenTelemetry" \
        "${OPENTELEMETRY_OPERATOR_NAMESPACE}" \
        "${OPENTELEMETRY_OPERATOR_PACKAGE}" \
        "${OPENTELEMETRY_OPERATOR_CHANNEL}" \
        "${OPENTELEMETRY_OPERATOR_SOURCE}" \
        "${OPENTELEMETRY_OPERATOR_SUBSCRIPTION_NAME}" \
        "${OPENTELEMETRY_OPERATOR_OPERATORGROUP_MODE:-all}"
    else
      log "MAAS_INSTALL_OPENTELEMETRY_OPERATOR=false; assuming Red Hat build of OpenTelemetry is already installed."
    fi
  else
    log "MAAS_ENABLE_OBSERVABILITY=false; skipping official RHOAI/MaaS observability operators."
  fi

  if as_bool "${MAAS_ENABLE_KUADRANT_OBSERVABILITY:-true}"; then
    log "Enabling Kuadrant observability according to the official MaaS observability flow."
    oc patch kuadrant "${KUADRANT_NAME}" -n "${KUADRANT_NAMESPACE}" --type=merge -p '{"spec":{"observability":{"enable":true}}}'

    if as_bool "${MAAS_WAIT_FOR_KUADRANT_LIMITADOR_PODMONITOR:-true}"; then
      wait_until "Kuadrant Limitador PodMonitor" "${KUADRANT_LIMITADOR_PODMONITOR_WAIT_TIMEOUT_SECONDS:-600}" 15 \
        "oc get podmonitor '${KUADRANT_LIMITADOR_PODMONITOR_NAME:-kuadrant-limitador-monitor}' -n '${KUADRANT_NAMESPACE}' >/dev/null 2>&1"
    fi
  fi
}



###############################################################################
# Step 2: MaaS PostgreSQL via CloudNativePG
###############################################################################

create_maas_postgres() {
  if ! as_bool "${MAAS_DB_ENABLED:-true}"; then
    log "MAAS_DB_ENABLED=false; skipping."
    return 0
  fi

  ensure_namespace "${MAAS_DB_NAMESPACE}"

  local image_line=""
  if [[ -n "${MAAS_DB_IMAGE:-}" ]]; then
    image_line="  imageName: ${MAAS_DB_IMAGE}"
  fi

  cat <<EOF_CNPG | oc apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${MAAS_DB_CLUSTER_NAME}
  namespace: ${MAAS_DB_NAMESPACE}
spec:
  instances: ${MAAS_DB_INSTANCES}
${image_line}
  bootstrap:
    initdb:
      database: ${MAAS_DB_NAME}
      owner: ${MAAS_DB_USER}
  storage:
    size: ${MAAS_DB_STORAGE_SIZE}
    storageClass: ${MAAS_DB_STORAGE_CLASS}
  resources:
    requests:
      cpu: ${MAAS_DB_CPU_REQUEST}
      memory: ${MAAS_DB_MEMORY_REQUEST}
    limits:
      cpu: "${MAAS_DB_CPU_LIMIT}"
      memory: ${MAAS_DB_MEMORY_LIMIT}
EOF_CNPG

  wait_until "CNPG Cluster ${MAAS_DB_NAMESPACE}/${MAAS_DB_CLUSTER_NAME} Ready" 2400 30 \
    "oc get cluster.postgresql.cnpg.io -n '${MAAS_DB_NAMESPACE}' '${MAAS_DB_CLUSTER_NAME}' -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); conds=d.get(\"status\",{}).get(\"conditions\",[]) or []; phase=d.get(\"status\",{}).get(\"phase\",\"\"); ready=any(c.get(\"type\") in (\"Ready\",\"ClusterReady\") and c.get(\"status\")==\"True\" for c in conds); sys.exit(0 if ready or \"healthy\" in phase.lower() else 1)'"

  wait_until "CNPG app secret ${MAAS_DB_APP_SECRET_NAME}" 600 15 \
    "oc get secret -n '${MAAS_DB_NAMESPACE}' '${MAAS_DB_APP_SECRET_NAME}'"
}

create_maas_db_secret() {
  ensure_namespace "${MAAS_DB_CONFIG_SECRET_NAMESPACE}"

  local conn_url
  conn_url="$(
    MAAS_DB_NAMESPACE="${MAAS_DB_NAMESPACE}" \
    MAAS_DB_APP_SECRET_NAME="${MAAS_DB_APP_SECRET_NAME}" \
    MAAS_DB_SERVICE_NAME="${MAAS_DB_SERVICE_NAME}" \
    MAAS_DB_SERVICE_PORT="${MAAS_DB_SERVICE_PORT}" \
    MAAS_DB_NAME="${MAAS_DB_NAME}" \
    python3 - <<'PY_DB_URL'
import base64
import json
import os
import subprocess
import sys
from urllib.parse import quote

ns = os.environ["MAAS_DB_NAMESPACE"]
secret_name = os.environ["MAAS_DB_APP_SECRET_NAME"]
service = os.environ["MAAS_DB_SERVICE_NAME"]
port = os.environ["MAAS_DB_SERVICE_PORT"]
db = os.environ["MAAS_DB_NAME"]

raw = subprocess.check_output(["oc", "get", "secret", "-n", ns, secret_name, "-o", "json"], text=True)
secret = json.loads(raw)
data = secret.get("data", {}) or {}

def dec(key):
    value = data.get(key)
    if not value:
        return ""
    return base64.b64decode(value).decode()

uri = dec("uri")
if uri:
    if "sslmode=" not in uri:
        sep = "&" if "?" in uri else "?"
        uri = uri + sep + "sslmode=require"
    print(uri)
    sys.exit(0)

user = dec("username") or dec("user")
password = dec("password")
dbname = dec("dbname") or dec("database") or db
host = dec("host") or f"{service}.{ns}.svc.cluster.local"
secret_port = dec("port") or port

if not user or not password:
    print("Could not find username/password in CNPG app secret", file=sys.stderr)
    sys.exit(1)

print(f"postgresql://{quote(user)}:{quote(password)}@{host}:{secret_port}/{quote(dbname)}?sslmode=require")
PY_DB_URL
  )"

  [[ -n "${conn_url}" ]] || die "Could not build MaaS DB connection URL."

  oc create secret generic "${MAAS_DB_CONFIG_SECRET_NAME}" \
    -n "${MAAS_DB_CONFIG_SECRET_NAMESPACE}" \
    --from-literal=DB_CONNECTION_URL="${conn_url}" \
    --dry-run=client -o yaml | oc apply -f -

  log "Created/updated ${MAAS_DB_CONFIG_SECRET_NAMESPACE}/${MAAS_DB_CONFIG_SECRET_NAME}."
}

###############################################################################
# Step 3: Authorino TLS
###############################################################################

configure_authorino_tls() {
  if ! as_bool "${MAAS_CONFIGURE_AUTHORINO_TLS:-true}"; then
    log "MAAS_CONFIGURE_AUTHORINO_TLS=false; skipping."
    return 0
  fi

  oc annotate service "${AUTHORINO_SERVICE_NAME}" \
    -n "${AUTHORINO_NAMESPACE}" \
    "${AUTHORINO_SERVICE_CA_SECRET_ANNOTATION}=${AUTHORINO_SERVER_CERT_SECRET_NAME}" \
    --overwrite

  wait_until "Authorino serving cert secret" 600 15 \
    "oc get secret -n '${AUTHORINO_NAMESPACE}' '${AUTHORINO_SERVER_CERT_SECRET_NAME}'"

  oc patch authorino "${AUTHORINO_NAME}" -n "${AUTHORINO_NAMESPACE}" --type=merge --patch "
{
  \"spec\": {
    \"listener\": {
      \"tls\": {
        \"enabled\": true,
        \"certSecretRef\": {
          \"name\": \"${AUTHORINO_SERVER_CERT_SECRET_NAME}\"
        }
      }
    }
  }
}"

  oc -n "${AUTHORINO_NAMESPACE}" set env deployment/"${AUTHORINO_DEPLOYMENT_NAME}" \
    SSL_CERT_FILE="${AUTHORINO_SSL_CERT_FILE}" \
    REQUESTS_CA_BUNDLE="${AUTHORINO_REQUESTS_CA_BUNDLE}"

  oc rollout status deployment -n "${AUTHORINO_NAMESPACE}" "${AUTHORINO_DEPLOYMENT_NAME}" --timeout=600s
}

###############################################################################
# Step 4: GatewayClass, Gateway, Route
###############################################################################

configure_maas_gateway() {
  if ! as_bool "${MAAS_GATEWAY_ENABLED:-true}"; then
    log "MAAS_GATEWAY_ENABLED=false; skipping."
    return 0
  fi

  local host
  host="$(maas_host)"
  log "Using MaaS host: ${host}"

  local existing_gateway_class_controller
  if oc get gatewayclass "${MAAS_GATEWAY_CLASS_NAME}" >/dev/null 2>&1; then
    existing_gateway_class_controller="$(oc get gatewayclass "${MAAS_GATEWAY_CLASS_NAME}" -o jsonpath='{.spec.controllerName}')"
    if [[ "${existing_gateway_class_controller}" != "${MAAS_GATEWAY_CLASS_CONTROLLER}" ]]; then
      die "GatewayClass ${MAAS_GATEWAY_CLASS_NAME} already exists with controllerName=${existing_gateway_class_controller}, but MAAS_GATEWAY_CLASS_CONTROLLER=${MAAS_GATEWAY_CLASS_CONTROLLER}. GatewayClass spec.controllerName is immutable; update setup-maas.conf to match the existing RHOAI-managed GatewayClass or approve deletion/recreation."
    fi
    log "GatewayClass ${MAAS_GATEWAY_CLASS_NAME} already exists with controllerName=${existing_gateway_class_controller}; leaving it unchanged."
  else
    cat <<EOF_GATEWAYCLASS | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ${MAAS_GATEWAY_CLASS_NAME}
spec:
  controllerName: ${MAAS_GATEWAY_CLASS_CONTROLLER}
EOF_GATEWAYCLASS
  fi

  ensure_namespace "${MAAS_GATEWAY_NAMESPACE}"

  if as_bool "${MAAS_GATEWAY_USE_ROUTE:-true}"; then
    cat <<EOF_GATEWAY_CM | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${MAAS_GATEWAY_NAME}-config
  namespace: ${MAAS_GATEWAY_NAMESPACE}
data:
  service: |
    spec:
      type: ClusterIP
EOF_GATEWAY_CM

    cat <<EOF_GATEWAY | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${MAAS_GATEWAY_NAME}
  namespace: ${MAAS_GATEWAY_NAMESPACE}
  labels:
    opendatahub.io/managed: "false"
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: ${MAAS_GATEWAY_CLASS_NAME}
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: ${MAAS_GATEWAY_NAME}-config
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: ${host}
    allowedRoutes:
      namespaces:
        from: All
EOF_GATEWAY

    wait_until "MaaS Gateway service ${MAAS_GATEWAY_BACKEND_SERVICE}" 600 15 \
      "oc get service -n '${MAAS_GATEWAY_NAMESPACE}' '${MAAS_GATEWAY_BACKEND_SERVICE}'"

    cat <<EOF_ROUTE | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${MAAS_ROUTE_NAME}
  namespace: ${MAAS_ROUTE_NAMESPACE}
spec:
  host: ${host}
  port:
    targetPort: ${MAAS_GATEWAY_BACKEND_TARGET_PORT}
  tls:
    insecureEdgeTerminationPolicy: ${MAAS_ROUTE_INSECURE_POLICY}
    termination: ${MAAS_ROUTE_TLS_TERMINATION}
  to:
    kind: Service
    name: ${MAAS_GATEWAY_BACKEND_SERVICE}
    weight: 100
  wildcardPolicy: None
EOF_ROUTE
  else
    if as_bool "${MAAS_GATEWAY_CREATE_CERTIFICATE:-false}"; then
      cat <<EOF_GATEWAY_CERT | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${MAAS_GATEWAY_CERTIFICATE_NAME}
  namespace: ${MAAS_GATEWAY_NAMESPACE}
spec:
  dnsNames:
  - ${host}
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: ${MAAS_GATEWAY_CLUSTER_ISSUER}
  secretName: ${MAAS_GATEWAY_TLS_SECRET_NAME}
EOF_GATEWAY_CERT
    fi

    cat <<EOF_GATEWAY | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${MAAS_GATEWAY_NAME}
  namespace: ${MAAS_GATEWAY_NAMESPACE}
  labels:
    opendatahub.io/managed: "false"
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: ${MAAS_GATEWAY_CLASS_NAME}
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    hostname: ${host}
    tls:
      mode: Terminate
      certificateRefs:
      - group: ""
        kind: Secret
        name: ${MAAS_GATEWAY_TLS_SECRET_NAME}
    allowedRoutes:
      namespaces:
        from: All
EOF_GATEWAY
  fi

  oc annotate gateway "${MAAS_GATEWAY_NAME}" \
    -n "${MAAS_GATEWAY_NAMESPACE}" \
    security.opendatahub.io/authorino-tls-bootstrap="true" \
    --overwrite
}

###############################################################################
# Step 5: DSCI
###############################################################################

verify_or_patch_dsci() {
  oc get dscinitialization "${DSCI_NAME}" >/dev/null 2>&1 || die "DSCInitialization ${DSCI_NAME} not found."

  if as_bool "${MAAS_PATCH_DSCI_IF_NEEDED:-true}"; then
    oc patch dscinitialization "${DSCI_NAME}" --type=merge --patch "
{
  \"spec\": {
    \"applicationsNamespace\": \"${DSCI_APPLICATIONS_NAMESPACE}\",
    \"monitoring\": {
      \"managementState\": \"${DSCI_MONITORING_MANAGEMENT_STATE}\",
      \"namespace\": \"${DSCI_MONITORING_NAMESPACE}\",
      \"metrics\": {
        \"storage\": {
          \"size\": \"${DSCI_MONITORING_METRICS_STORAGE_SIZE}\"
        }
      }
    },
    \"trustedCABundle\": {
      \"managementState\": \"${DSCI_TRUSTED_CA_BUNDLE_MANAGEMENT_STATE}\"
    }
  }
}"
  fi

  if as_bool "${MAAS_FORCE_DSCI_RECONCILE_AFTER_OBSERVABILITY_PREREQS:-true}"; then
    log "Forcing DSCInitialization reconcile so RHOAI creates the official monitoring stack after observability prerequisites are installed."
    oc annotate dscinitialization "${DSCI_NAME}" \
      maas.opendatahub.io/force-reconcile-ts="$(date +%s)" \
      --overwrite
  fi

  wait_until "DSCInitialization ${DSCI_NAME} Ready" 600 15 \
    "test \"\$(oc get dscinitialization '${DSCI_NAME}' -o jsonpath='{.status.phase}' 2>/dev/null)\" = Ready"
}



###############################################################################
# Step 5b: RHOAI observability stack readiness
###############################################################################

cleanup_legacy_perses_proxy() {
  if ! as_bool "${MAAS_CLEANUP_LEGACY_PERSES_PROXY:-true}"; then
    return 0
  fi

  # Older troubleshooting used a temporary HTTP-to-HTTPS proxy deployment named
  # data-science-perses. The official stack uses a StatefulSet with the same
  # service name. Delete only the legacy Deployment/ConfigMap; keep the
  # official StatefulSet, Service, ConfigMap and PVCs.
  oc delete deployment data-science-perses -n "${DSCI_MONITORING_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
  oc delete configmap data-science-perses-proxy-config -n "${DSCI_MONITORING_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
}

wait_for_rhoai_observability_stack() {
  if ! as_bool "${MAAS_ENABLE_OBSERVABILITY:-true}"; then
    log "MAAS_ENABLE_OBSERVABILITY=false; skipping RHOAI observability stack wait."
    return 0
  fi

  if ! as_bool "${DASHBOARD_FLAG_OBSERVABILITY_DASHBOARD:-true}"; then
    log "DASHBOARD_FLAG_OBSERVABILITY_DASHBOARD=false; skipping RHOAI observability stack wait."
    return 0
  fi

  local ns="${DSCI_MONITORING_NAMESPACE}"
  local timeout="${RHOAI_OBSERVABILITY_STACK_WAIT_TIMEOUT_SECONDS:-1800}"
  local interval="${RHOAI_OBSERVABILITY_STACK_WAIT_INTERVAL_SECONDS:-15}"

  wait_until "RHOAI monitoring namespace ${ns}" "${timeout}" "${interval}" \
    "oc get namespace '${ns}' >/dev/null 2>&1"

  wait_until "RHOAI Perses StatefulSet ready" "${timeout}" "${interval}" \
    "test \"\$(oc get statefulset data-science-perses -n '${ns}' -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)\" -ge 1"

  cleanup_legacy_perses_proxy

  wait_until "RHOAI data-science-perses service" "${timeout}" "${interval}" \
    "oc get service data-science-perses -n '${ns}' >/dev/null 2>&1"

  wait_until "RHOAI Prometheus StatefulSet ready" "${timeout}" "${interval}" \
    "test \"\$(oc get statefulset prometheus-data-science-monitoringstack -n '${ns}' -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)\" -ge 1"

  wait_until "RHOAI Thanos Querier deployment available" "${timeout}" "${interval}" \
    "test \"\$(oc get deployment thanos-querier-data-science-thanos-querier -n '${ns}' -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)\" -ge 1"

  wait_until "RHOAI OpenTelemetry collector ready" "${timeout}" "${interval}" \
    "test \"\$(oc get statefulset data-science-collector-collector -n '${ns}' -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)\" -ge 1"

  wait_until "RHOAI Alertmanager ready" "${timeout}" "${interval}" \
    "test \"\$(oc get statefulset alertmanager-data-science-monitoringstack -n '${ns}' -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)\" -ge 1"

  wait_until "RHOAI Perses datasources available" "${timeout}" "${interval}" \
    "oc get persesdatasource cluster-prometheus-datasource -n '${ns}' >/dev/null 2>&1 && oc get persesdatasource data-science-prometheus-datasource -n '${ns}' >/dev/null 2>&1"
}

###############################################################################
# Step 6: DataScienceCluster
###############################################################################

create_dsc() {
  if ! as_bool "${MAAS_CREATE_DSC:-true}"; then
    log "MAAS_CREATE_DSC=false; skipping."
    return 0
  fi

  if [[ "${DSC_COMPONENT_KSERVE_RAW_DEPLOYMENT_SERVICE_CONFIG}" == "Headless" ]]; then
    die "Refusing to use kserve.rawDeploymentServiceConfig=Headless. Use Headed on OpenShift/OpenShift AI."
  fi

  cat <<EOF_DSC | oc apply -f -
apiVersion: ${DSC_API_VERSION}
kind: DataScienceCluster
metadata:
  name: ${DSC_NAME}
spec:
  components:
    aipipelines:
      managementState: ${DSC_COMPONENT_AIPIPELINES}
    dashboard:
      managementState: ${DSC_COMPONENT_DASHBOARD}
    feastoperator:
      managementState: ${DSC_COMPONENT_FEASTOPERATOR}
    kserve:
      managementState: ${DSC_COMPONENT_KSERVE}
      modelsAsService:
        managementState: ${DSC_COMPONENT_KSERVE_MODELS_AS_SERVICE}
      nim:
        managementState: ${DSC_COMPONENT_KSERVE_NIM}
      rawDeploymentServiceConfig: ${DSC_COMPONENT_KSERVE_RAW_DEPLOYMENT_SERVICE_CONFIG}
    kueue:
      managementState: ${DSC_COMPONENT_KUEUE}
    llamastackoperator:
      managementState: ${DSC_COMPONENT_LLAMASTACKOPERATOR}
    mlflowoperator:
      managementState: ${DSC_COMPONENT_MLFLOWOPERATOR}
    modelregistry:
      managementState: ${DSC_COMPONENT_MODELREGISTRY}
      registriesNamespace: ${DSC_COMPONENT_MODELREGISTRY_NAMESPACE}
    ray:
      managementState: ${DSC_COMPONENT_RAY}
    sparkoperator:
      managementState: ${DSC_COMPONENT_SPARKOPERATOR}
    trainer:
      managementState: ${DSC_COMPONENT_TRAINER}
    trainingoperator:
      managementState: ${DSC_COMPONENT_TRAININGOPERATOR}
    trustyai:
      managementState: ${DSC_COMPONENT_TRUSTYAI}
      eval:
        lmeval:
          permitCodeExecution: ${DSC_TRUSTYAI_LMEVAL_PERMIT_CODE_EXECUTION}
          permitOnline: ${DSC_TRUSTYAI_LMEVAL_PERMIT_ONLINE}
    workbenches:
      managementState: ${DSC_COMPONENT_WORKBENCHES}
      workbenchNamespace: ${DSC_COMPONENT_WORKBENCHES_NAMESPACE}
EOF_DSC

  wait_until "DataScienceCluster ${DSC_NAME} Ready" 2400 30 \
    "test \"\$(oc get datasciencecluster '${DSC_NAME}' -o jsonpath='{range .status.conditions[?(@.type==\"Ready\")]}{.status}{end}' 2>/dev/null)\" = True"
}

###############################################################################
# Step 7: Dashboard flags
###############################################################################

configure_dashboard() {
  if ! as_bool "${MAAS_CONFIGURE_DASHBOARD:-true}"; then
    log "MAAS_CONFIGURE_DASHBOARD=false; skipping."
    return 0
  fi

  ensure_namespace "${ODH_DASHBOARD_CONFIG_NAMESPACE}"

  cat <<EOF_DASHBOARD | oc apply -f -
apiVersion: opendatahub.io/v1alpha
kind: OdhDashboardConfig
metadata:
  name: ${ODH_DASHBOARD_CONFIG_NAME}
  namespace: ${ODH_DASHBOARD_CONFIG_NAMESPACE}
spec:
  dashboardConfig:
    modelAsService: ${DASHBOARD_FLAG_MODEL_AS_SERVICE}
    genAiStudio: ${DASHBOARD_FLAG_GEN_AI_STUDIO}
    maasAuthPolicies: ${DASHBOARD_FLAG_MAAS_AUTH_POLICIES}
    observabilityDashboard: ${DASHBOARD_FLAG_OBSERVABILITY_DASHBOARD}
    vLLMDeploymentOnMaaS: ${DASHBOARD_FLAG_VLLM_DEPLOYMENT_ON_MAAS}
EOF_DASHBOARD

  if as_bool "${DASHBOARD_RESTART_AFTER_CONFIG:-true}"; then
    if oc get deployment -n "${DASHBOARD_DEPLOYMENT_NAMESPACE}" "${DASHBOARD_DEPLOYMENT_NAME}" >/dev/null 2>&1; then
      oc rollout restart deployment -n "${DASHBOARD_DEPLOYMENT_NAMESPACE}" "${DASHBOARD_DEPLOYMENT_NAME}"
      oc rollout status deployment -n "${DASHBOARD_DEPLOYMENT_NAMESPACE}" "${DASHBOARD_DEPLOYMENT_NAME}" --timeout=600s
    else
      warn "Dashboard deployment ${DASHBOARD_DEPLOYMENT_NAMESPACE}/${DASHBOARD_DEPLOYMENT_NAME} not found yet; skipping restart."
    fi
  fi
}

###############################################################################
# Step 8: MaaS components readiness
###############################################################################

wait_for_maas_components() {
  if as_bool "${MAAS_WAIT_FOR_CRDS:-true}"; then
    for crd in \
      tenants.maas.opendatahub.io \
      maasmodelrefs.maas.opendatahub.io \
      maassubscriptions.maas.opendatahub.io \
      maasauthpolicies.maas.opendatahub.io \
      externalmodels.maas.opendatahub.io
    do
      wait_until "CRD ${crd}" "${MAAS_CRD_WAIT_TIMEOUT_SECONDS}" 30 "oc get crd ${crd}"
    done
  fi

  wait_until "MaaS namespace ${MAAS_NAMESPACE}" "${MAAS_READY_TIMEOUT_SECONDS}" "${MAAS_READY_INTERVAL_SECONDS}" \
    "oc get namespace '${MAAS_NAMESPACE}'"

  wait_until "MaaS Tenant ${MAAS_TENANT_NAME} Ready" "${MAAS_READY_TIMEOUT_SECONDS}" "${MAAS_READY_INTERVAL_SECONDS}" \
    "test \"\$(oc get tenant -n '${MAAS_NAMESPACE}' '${MAAS_TENANT_NAME}' -o jsonpath='{range .status.conditions[?(@.type==\"Ready\")]}{.status}{end}' 2>/dev/null)\" = True"

  wait_until "MaaS API deployment available" "${MAAS_READY_TIMEOUT_SECONDS}" "${MAAS_READY_INTERVAL_SECONDS}" \
    "test \"\$(oc get deployment -n '${RHOAI_APPLICATIONS_NAMESPACE}' '${MAAS_API_DEPLOYMENT_NAME}' -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)\" != \"\" && test \"\$(oc get deployment -n '${RHOAI_APPLICATIONS_NAMESPACE}' '${MAAS_API_DEPLOYMENT_NAME}' -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)\" -ge 1"
}


configure_maas_tenant_telemetry() {
  if ! as_bool "${MAAS_ENABLE_TENANT_TELEMETRY:-true}"; then
    log "MAAS_ENABLE_TENANT_TELEMETRY=false; skipping MaaS tenant telemetry patch."
    return 0
  fi

  local capture_org="${MAAS_TELEMETRY_CAPTURE_ORGANIZATION:-true}"
  local capture_user="${MAAS_TELEMETRY_CAPTURE_USER:-true}"
  local capture_group="${MAAS_TELEMETRY_CAPTURE_GROUP:-false}"
  local capture_model_usage="${MAAS_TELEMETRY_CAPTURE_MODEL_USAGE:-true}"

  log "Enabling MaaS tenant telemetry: organization=${capture_org}, user=${capture_user}, group=${capture_group}, modelUsage=${capture_model_usage}"

  oc patch tenants.maas.opendatahub.io "${MAAS_TENANT_NAME}" -n "${MAAS_NAMESPACE}" \
    --type merge \
    -p "{
      \"spec\": {
        \"telemetry\": {
          \"enabled\": true,
          \"metrics\": {
            \"captureOrganization\": ${capture_org},
            \"captureUser\": ${capture_user},
            \"captureGroup\": ${capture_group},
            \"captureModelUsage\": ${capture_model_usage}
          }
        }
      }
    }"

  wait_until "MaaS Tenant telemetry enabled" "${MAAS_TENANT_TELEMETRY_WAIT_TIMEOUT_SECONDS:-600}" 15 \
    "test \"\$(oc get tenant '${MAAS_TENANT_NAME}' -n '${MAAS_NAMESPACE}' -o jsonpath='{.spec.telemetry.enabled}' 2>/dev/null)\" = true"

  if as_bool "${MAAS_WAIT_FOR_TELEMETRY_POLICY:-true}"; then
    wait_until "MaaS TelemetryPolicy ${MAAS_TELEMETRY_POLICY_NAMESPACE}/${MAAS_TELEMETRY_POLICY_NAME}" "${MAAS_TENANT_TELEMETRY_WAIT_TIMEOUT_SECONDS:-600}" 15 \
      "oc get telemetrypolicy '${MAAS_TELEMETRY_POLICY_NAME}' -n '${MAAS_TELEMETRY_POLICY_NAMESPACE}' >/dev/null 2>&1"
  fi

  if as_bool "${MAAS_WAIT_FOR_KUADRANT_LIMITADOR_PODMONITOR:-true}"; then
    wait_until "Kuadrant Limitador PodMonitor" "${KUADRANT_LIMITADOR_PODMONITOR_WAIT_TIMEOUT_SECONDS:-600}" 15 \
      "oc get podmonitor '${KUADRANT_LIMITADOR_PODMONITOR_NAME:-kuadrant-limitador-monitor}' -n '${KUADRANT_NAMESPACE}' >/dev/null 2>&1"
  fi
}


authpolicy_condition_status() {
  local ns="$1"
  local name="$2"
  local condition="$3"

  oc get authpolicy "${name}" -n "${ns}" \
    -o jsonpath="{range .status.conditions[?(@.type==\"${condition}\")]}{.status}{end}" 2>/dev/null || true
}

authpolicy_condition_reason() {
  local ns="$1"
  local name="$2"
  local condition="$3"

  oc get authpolicy "${name}" -n "${ns}" \
    -o jsonpath="{range .status.conditions[?(@.type==\"${condition}\")]}{.reason}{end}" 2>/dev/null || true
}

restart_kuadrant_operator_pod() {
  local deployment="${KUADRANT_OPERATOR_DEPLOYMENT:-kuadrant-operator-controller-manager}"

  log "Restarting Kuadrant operator pod by deleting current pod(s) for deployment/${deployment}."

  local pods
  pods="$(oc get pods -n "${KUADRANT_NAMESPACE}" -o name 2>/dev/null | grep "^pod/${deployment}" || true)"

  if [[ -n "${pods}" ]]; then
    echo "${pods}" | xargs -r oc delete -n "${KUADRANT_NAMESPACE}" --wait=false
  else
    warn "No Kuadrant operator pod found by name prefix ${deployment}; falling back to rollout restart."
    oc rollout restart "deployment/${deployment}" -n "${KUADRANT_NAMESPACE}"
  fi

  oc rollout status "deployment/${deployment}" -n "${KUADRANT_NAMESPACE}" --timeout="${KUADRANT_OPERATOR_ROLLOUT_TIMEOUT:-300s}"
}

reconcile_kuadrant_authpolicies() {
  if ! as_bool "${MAAS_RECONCILE_KUADRANT_AUTHPOLICIES:-true}"; then
    log "MAAS_RECONCILE_KUADRANT_AUTHPOLICIES=false; skipping."
    return 0
  fi

  local maas_policy_ns="${MAAS_API_AUTHPOLICY_NAMESPACE:-redhat-ods-applications}"
  local maas_policy_name="${MAAS_API_AUTHPOLICY_NAME:-maas-api-auth-policy}"
  local gateway_policy_ns="${MAAS_GATEWAY_AUTHPOLICY_NAMESPACE:-openshift-ingress}"
  local gateway_policy_name="${MAAS_GATEWAY_AUTHPOLICY_NAME:-gateway-default-auth}"
  local timeout="${MAAS_AUTHPOLICY_WAIT_TIMEOUT_SECONDS:-600}"
  local interval="${MAAS_AUTHPOLICY_WAIT_INTERVAL_SECONDS:-15}"

  wait_until "MaaS API AuthPolicy exists" "${timeout}" "${interval}" \
    "oc get authpolicy '${maas_policy_name}' -n '${maas_policy_ns}' >/dev/null 2>&1"

  wait_until "MaaS Gateway AuthPolicy exists" "${timeout}" "${interval}" \
    "oc get authpolicy '${gateway_policy_name}' -n '${gateway_policy_ns}' >/dev/null 2>&1"

  local maas_accepted
  local maas_reason
  local gateway_accepted
  local gateway_reason

  maas_accepted="$(authpolicy_condition_status "${maas_policy_ns}" "${maas_policy_name}" "Accepted")"
  maas_reason="$(authpolicy_condition_reason "${maas_policy_ns}" "${maas_policy_name}" "Accepted")"
  gateway_accepted="$(authpolicy_condition_status "${gateway_policy_ns}" "${gateway_policy_name}" "Accepted")"
  gateway_reason="$(authpolicy_condition_reason "${gateway_policy_ns}" "${gateway_policy_name}" "Accepted")"

  log "MaaS API AuthPolicy Accepted=${maas_accepted:-unknown}, reason=${maas_reason:-unknown}"
  log "Gateway AuthPolicy Accepted=${gateway_accepted:-unknown}, reason=${gateway_reason:-unknown}"

  if [[ "${maas_accepted}" != "True" || "${gateway_accepted}" != "True" || "${maas_reason}" == "MissingDependency" || "${gateway_reason}" == "MissingDependency" ]]; then
    warn "Kuadrant AuthPolicy is not accepted yet; restarting Kuadrant operator to rediscover Gateway provider."
    restart_kuadrant_operator_pod

    oc annotate authpolicy "${maas_policy_name}" -n "${maas_policy_ns}" \
      maas-debug/reconcile-ts="$(date +%s)" --overwrite

    oc annotate authpolicy "${gateway_policy_name}" -n "${gateway_policy_ns}" \
      maas-debug/reconcile-ts="$(date +%s)" --overwrite
  fi

  wait_until "MaaS API AuthPolicy Accepted" "${timeout}" "${interval}" \
    "test \"\$(oc get authpolicy '${maas_policy_name}' -n '${maas_policy_ns}' -o jsonpath='{range .status.conditions[?(@.type==\"Accepted\")]}{.status}{end}' 2>/dev/null)\" = True"

  wait_until "MaaS API AuthPolicy Enforced" "${timeout}" "${interval}" \
    "test \"\$(oc get authpolicy '${maas_policy_name}' -n '${maas_policy_ns}' -o jsonpath='{range .status.conditions[?(@.type==\"Enforced\")]}{.status}{end}' 2>/dev/null)\" = True"

  wait_until "Gateway default AuthPolicy Accepted" "${timeout}" "${interval}" \
    "test \"\$(oc get authpolicy '${gateway_policy_name}' -n '${gateway_policy_ns}' -o jsonpath='{range .status.conditions[?(@.type==\"Accepted\")]}{.status}{end}' 2>/dev/null)\" = True"

  log "Kuadrant AuthPolicies are accepted/enforced for MaaS."
}


validate_maas_api_health() {
  if ! as_bool "${MAAS_VALIDATE_API_HEALTH:-true}"; then
    log "MAAS_VALIDATE_API_HEALTH=false; skipping."
    return 0
  fi

  local host url start now elapsed
  host="$(maas_host)"
  url="https://${host}${MAAS_HEALTH_ENDPOINT_PATH}"
  start="$(date +%s)"

  while true; do
    if curl -k -fsS "${url}" >/dev/null 2>&1; then
      log "Ready: MaaS API health endpoint ${url}"
      return 0
    fi

    now="$(date +%s)"
    elapsed=$(( now - start ))

    if (( elapsed >= MAAS_HEALTH_TIMEOUT_SECONDS )); then
      warn "MaaS API health endpoint did not respond successfully: ${url}"
      return 0
    fi

    log "Waiting for MaaS API health endpoint: ${url} (${elapsed}s/${MAAS_HEALTH_TIMEOUT_SECONDS}s)"
    sleep 30
  done
}

###############################################################################
# Step 9: Optional subscriptions/policies
###############################################################################

maybe_create_default_subscriptions() {
  if as_bool "${MAAS_CREATE_DEFAULT_SUBSCRIPTIONS:-false}" || as_bool "${MAAS_CREATE_DEFAULT_AUTH_POLICIES:-false}"; then
    die "Default MaaSSubscription/MaaSAuthPolicy creation is intentionally disabled in this script version. Create them manually after publishing a model."
  fi

  log "Default MaaS subscriptions/auth policies are disabled; nothing to create."
}

###############################################################################
# Step 10: Validation summary
###############################################################################

validation_summary() {
  if ! as_bool "${MAAS_PRINT_VALIDATION_SUMMARY:-true}"; then
    return 0
  fi

  local host
  host="$(maas_host)"

  echo
  echo "=== MaaS validation summary ==="
  echo
  echo "MaaS URL: https://${host}${MAAS_API_BASE_PATH}"

  echo
  echo "--- DSCI ---"
  oc get dscinitialization "${DSCI_NAME}" || true

  echo
  echo "--- DSC ---"
  oc get datasciencecluster "${DSC_NAME}" || true
  oc get datasciencecluster "${DSC_NAME}" -o jsonpath='{range .status.conditions[?(@.type=="KserveLLMInferenceServiceWideEPDependencies")]}{.type}{" | "}{.status}{" | "}{.reason}{" | "}{.message}{"\n"}{end}' 2>/dev/null || true

  echo
  echo "--- LWS / WideEP dependency ---"
  local lws_namespace="${LWS_NAMESPACE:-openshift-lws-operator}"
  local lws_subscription_name="${LWS_SUBSCRIPTION_NAME:-leader-worker-set}"
  local lws_instance_name="${LWS_INSTANCE_NAME:-cluster}"
  oc get subscription -n "${lws_namespace}" "${lws_subscription_name}" 2>/dev/null || true
  oc get csv -n "${lws_namespace}" | grep -E 'NAME|leader-worker-set' || true
  oc get leaderworkersetoperator -n "${lws_namespace}" "${lws_instance_name}" 2>/dev/null || true
  oc get deployment -n "${lws_namespace}" lws-controller-manager 2>/dev/null || true

  echo
  echo "--- CNPG MaaS DB ---"
  oc get cluster.postgresql.cnpg.io -n "${MAAS_DB_NAMESPACE}" "${MAAS_DB_CLUSTER_NAME}" || true
  oc get secret -n "${MAAS_DB_CONFIG_SECRET_NAMESPACE}" "${MAAS_DB_CONFIG_SECRET_NAME}" || true

  echo
  echo "--- Gateway / Route ---"
  oc get gateway -n "${MAAS_GATEWAY_NAMESPACE}" "${MAAS_GATEWAY_NAME}" || true
  if as_bool "${MAAS_GATEWAY_USE_ROUTE:-true}"; then
    oc get route -n "${MAAS_ROUTE_NAMESPACE}" "${MAAS_ROUTE_NAME}" || true
  fi

  echo
  echo "--- Authorino TLS ---"
  oc get service -n "${AUTHORINO_NAMESPACE}" "${AUTHORINO_SERVICE_NAME}" -o jsonpath='{.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}{"\n"}' 2>/dev/null || true
  oc get secret -n "${AUTHORINO_NAMESPACE}" "${AUTHORINO_SERVER_CERT_SECRET_NAME}" || true

  echo
  echo "--- MaaS namespace / tenant ---"
  oc get namespace "${MAAS_NAMESPACE}" || true
  oc get tenant -n "${MAAS_NAMESPACE}" "${MAAS_TENANT_NAME}" || true

  echo
  echo "--- MaaS CR counts ---"
  oc get maasmodelref,maassubscription,maasauthpolicy,externalmodel -A 2>/dev/null || true

  echo
  echo "--- Official RHOAI observability stack ---"
  oc get subscription -n "${CLUSTER_OBSERVABILITY_OPERATOR_NAMESPACE}" "${CLUSTER_OBSERVABILITY_OPERATOR_SUBSCRIPTION_NAME}" 2>/dev/null || true
  oc get subscription -n "${TEMPO_OPERATOR_NAMESPACE:-openshift-tempo-operator}" "${TEMPO_OPERATOR_SUBSCRIPTION_NAME:-tempo-product}" 2>/dev/null || true
  oc get subscription -n "${OPENTELEMETRY_OPERATOR_NAMESPACE:-openshift-opentelemetry-operator}" "${OPENTELEMETRY_OPERATOR_SUBSCRIPTION_NAME:-opentelemetry-product}" 2>/dev/null || true
  oc get pods,svc,pvc -n "${DSCI_MONITORING_NAMESPACE}" 2>/dev/null | grep -E 'NAME|data-science-perses|prometheus-data-science|thanos-querier-data-science|data-science-collector|alertmanager-data-science' || true
  oc get podmonitor -n "${KUADRANT_NAMESPACE}" "${KUADRANT_LIMITADOR_PODMONITOR_NAME:-kuadrant-limitador-monitor}" 2>/dev/null || true
  oc get telemetrypolicy -n "${MAAS_TELEMETRY_POLICY_NAMESPACE:-openshift-ingress}" "${MAAS_TELEMETRY_POLICY_NAME:-maas-telemetry}" 2>/dev/null || true
  oc get tenant -n "${MAAS_NAMESPACE}" "${MAAS_TENANT_NAME}" -o jsonpath='{.spec.telemetry}' 2>/dev/null || true
  echo

  echo
  echo "Tracker file: ${TRACKER_FILE}"
}

###############################################################################
# Main
###############################################################################

main() {
  init_tracker

  run_step "maas_preflight_checked" preflight_check
  run_step "maas_observability_configured" configure_observability
  run_step "maas_postgres_created" create_maas_postgres
  run_step "maas_db_secret_created" create_maas_db_secret
  run_step "maas_authorino_tls_configured" configure_authorino_tls
  run_step "maas_gateway_configured" configure_maas_gateway
  run_step "maas_dsci_verified_or_patched" verify_or_patch_dsci
  run_step "maas_dsc_created" create_dsc
  run_step "maas_dashboard_configured" configure_dashboard
  run_step "maas_rhoai_observability_stack_ready" wait_for_rhoai_observability_stack
  run_step "maas_components_ready" wait_for_maas_components
  run_step "maas_tenant_telemetry_configured" configure_maas_tenant_telemetry
  run_step "maas_authpolicies_reconciled" reconcile_kuadrant_authpolicies
  run_step "maas_api_health_validated" validate_maas_api_health
  run_step "maas_default_subscriptions_handled" maybe_create_default_subscriptions
  run_step "maas_validation_complete" validation_summary
}

main "$@"
