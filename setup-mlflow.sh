#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/setup-mlflow.conf"
TRACKER_FILE="${SCRIPT_DIR}/setup-mlflow.tracker.json"
RESET_REQUESTED="false"

for arg in "$@"; do
  case "${arg}" in
    config=*) CONFIG_FILE="${arg#config=}" ;;
    reset=true|RESET=true) RESET_REQUESTED="true" ;;
    reset=false|RESET=false) RESET_REQUESTED="false" ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Supported arguments: config=/path/to/setup-mlflow.conf reset=true" >&2
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
sys.exit(0 if data.get("steps", {}).get(step, {}).get("status") == "done" else 1)
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

split_csv() {
  echo "$1" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$'
}

###############################################################################
# Preflight
###############################################################################

preflight_check() {
  oc whoami >/dev/null

  local rhoai_csv
  rhoai_csv="$(oc get subscription -n "${RHOAI_OPERATOR_NAMESPACE}" rhods-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  [[ -n "${rhoai_csv}" ]] || die "RHOAI subscription installedCSV not found in ${RHOAI_OPERATOR_NAMESPACE}."

  if ! [[ "${rhoai_csv}" =~ ${REQUIRED_RHOAI_CSV_REGEX} ]]; then
    die "RHOAI CSV '${rhoai_csv}' does not match required regex '${REQUIRED_RHOAI_CSV_REGEX}'."
  fi

  log "RHOAI CSV verified: ${rhoai_csv}"

  oc get datasciencecluster "${DSC_NAME}" >/dev/null 2>&1 || die "DataScienceCluster ${DSC_NAME} not found. Run setup-maas.sh first."
  wait_until "DataScienceCluster ${DSC_NAME} Ready" 900 15     "test \"$(oc get datasciencecluster '${DSC_NAME}' -o jsonpath='{range .status.conditions[?(@.type==\"Ready\")]}{.status}{end}' 2>/dev/null)\" = True"

  oc get dscinitialization "${DSCI_NAME}" >/dev/null 2>&1 || die "DSCInitialization ${DSCI_NAME} not found."
  wait_until "DSCInitialization ${DSCI_NAME} Ready" 600 15     "test \"$(oc get dscinitialization '${DSCI_NAME}' -o jsonpath='{.status.phase}' 2>/dev/null)\" = Ready"

  oc get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 || die "CloudNativePG CRD clusters.postgresql.cnpg.io not found."
  oc get crd objectbucketclaims.objectbucket.io >/dev/null 2>&1 || die "ObjectBucketClaim CRD objectbucketclaims.objectbucket.io not found. ODF/MCG must be installed."
  oc get storageclass "${MLFLOW_OBC_STORAGE_CLASS}" >/dev/null 2>&1 || die "StorageClass ${MLFLOW_OBC_STORAGE_CLASS} not found. ODF/MCG must be ready."

  log "Preflight checks passed."
}

###############################################################################
# Enable MLflow Operator component
###############################################################################

enable_mlflow_operator_component() {
  if ! as_bool "${MLFLOW_ENABLE_OPERATOR_COMPONENT:-true}"; then
    log "MLFLOW_ENABLE_OPERATOR_COMPONENT=false; skipping."
    return 0
  fi

  log "Enabling RHOAI MLflow Operator component in DataScienceCluster ${DSC_NAME}."

  oc patch datasciencecluster "${DSC_NAME}" --type=merge     -p '{"spec":{"components":{"mlflowoperator":{"managementState":"Managed"}}}}'

  wait_until "DataScienceCluster ${DSC_NAME} Ready after MLflow operator enablement" 1200 20     "test \"$(oc get datasciencecluster '${DSC_NAME}' -o jsonpath='{range .status.conditions[?(@.type==\"Ready\")]}{.status}{end}' 2>/dev/null)\" = True"

  wait_until "MLflow CRD mlflows.mlflow.opendatahub.io" 900 15     "oc get crd mlflows.mlflow.opendatahub.io >/dev/null 2>&1"
}

###############################################################################
# PostgreSQL backend store via CloudNativePG
###############################################################################

create_mlflow_postgres() {
  if ! as_bool "${MLFLOW_DB_ENABLED:-true}"; then
    log "MLFLOW_DB_ENABLED=false; skipping PostgreSQL."
    return 0
  fi

  ensure_namespace "${MLFLOW_DB_NAMESPACE}"

  local image_line=""
  if [[ -n "${MLFLOW_DB_IMAGE:-}" ]]; then
    image_line="  imageName: ${MLFLOW_DB_IMAGE}"
  fi

  cat <<EOF_CNPG | oc apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${MLFLOW_DB_CLUSTER_NAME}
  namespace: ${MLFLOW_DB_NAMESPACE}
spec:
  instances: ${MLFLOW_DB_INSTANCES}
${image_line}
  bootstrap:
    initdb:
      database: ${MLFLOW_DB_NAME}
      owner: ${MLFLOW_DB_USER}
  storage:
    size: ${MLFLOW_DB_STORAGE_SIZE}
    storageClass: ${MLFLOW_DB_STORAGE_CLASS}
  resources:
    requests:
      cpu: ${MLFLOW_DB_CPU_REQUEST}
      memory: ${MLFLOW_DB_MEMORY_REQUEST}
    limits:
      cpu: "${MLFLOW_DB_CPU_LIMIT}"
      memory: ${MLFLOW_DB_MEMORY_LIMIT}
EOF_CNPG

  wait_until "CNPG Cluster ${MLFLOW_DB_NAMESPACE}/${MLFLOW_DB_CLUSTER_NAME} Ready" 2400 30     "oc get cluster.postgresql.cnpg.io -n '${MLFLOW_DB_NAMESPACE}' '${MLFLOW_DB_CLUSTER_NAME}' -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); conds=d.get(\"status\",{}).get(\"conditions\",[]) or []; phase=d.get(\"status\",{}).get(\"phase\",\"\"); ready=any(c.get(\"type\") in (\"Ready\",\"ClusterReady\") and c.get(\"status\")==\"True\" for c in conds); sys.exit(0 if ready or \"healthy\" in phase.lower() else 1)'"

  wait_until "CNPG app secret ${MLFLOW_DB_CLUSTER_NAME}-app" 600 15     "oc get secret -n '${MLFLOW_DB_NAMESPACE}' '${MLFLOW_DB_CLUSTER_NAME}-app' >/dev/null 2>&1"

  wait_until "CNPG CA secret ${MLFLOW_DB_NAMESPACE}/${MLFLOW_DB_CA_SECRET_NAME}" 600 15     "oc get secret -n '${MLFLOW_DB_NAMESPACE}' '${MLFLOW_DB_CA_SECRET_NAME}' >/dev/null 2>&1"
}

create_mlflow_db_secret() {
  ensure_namespace "${MLFLOW_NAMESPACE}"

  local conn_url
  conn_url="$(
    MLFLOW_DB_NAMESPACE="${MLFLOW_DB_NAMESPACE}"     MLFLOW_DB_CLUSTER_NAME="${MLFLOW_DB_CLUSTER_NAME}"     MLFLOW_DB_NAME="${MLFLOW_DB_NAME}"     MLFLOW_DB_USER="${MLFLOW_DB_USER}"     MLFLOW_DB_SERVICE_PORT="${MLFLOW_DB_SERVICE_PORT}"     MLFLOW_DB_SSLMODE="${MLFLOW_DB_SSLMODE}"     python3 - <<'PY_DB_URL'
import base64
import json
import os
import subprocess
import sys
from urllib.parse import quote

ns = os.environ["MLFLOW_DB_NAMESPACE"]
cluster = os.environ["MLFLOW_DB_CLUSTER_NAME"]
db = os.environ["MLFLOW_DB_NAME"]
port = os.environ["MLFLOW_DB_SERVICE_PORT"]
sslmode = os.environ.get("MLFLOW_DB_SSLMODE", "require")
secret_name = f"{cluster}-app"

raw = subprocess.check_output(["oc", "get", "secret", "-n", ns, secret_name, "-o", "json"], text=True)
secret = json.loads(raw)
data = secret.get("data", {}) or {}

def dec(key):
    value = data.get(key)
    return base64.b64decode(value).decode() if value else ""

uri = dec("uri")
if uri:
    if sslmode and "sslmode=" not in uri:
        sep = "&" if "?" in uri else "?"
        uri = uri + sep + "sslmode=" + quote(sslmode)
    print(uri)
    sys.exit(0)

user = dec("username") or dec("user") or os.environ["MLFLOW_DB_USER"]
password = dec("password")
dbname = dec("dbname") or dec("database") or db
host = dec("host") or f"{cluster}-rw.{ns}.svc.cluster.local"
secret_port = dec("port") or port

if not user or not password:
    print("Could not find username/password in CNPG app secret", file=sys.stderr)
    sys.exit(1)

url = f"postgresql://{quote(user)}:{quote(password)}@{host}:{secret_port}/{quote(dbname)}"
if sslmode:
    url += "?sslmode=" + quote(sslmode)
print(url)
PY_DB_URL
  )"

  [[ -n "${conn_url}" ]] || die "Could not build MLflow PostgreSQL backend URI."

  oc create secret generic "${MLFLOW_DB_SECRET_NAME}"     -n "${MLFLOW_NAMESPACE}"     --from-literal="${MLFLOW_DB_SECRET_KEY}=${conn_url}"     --dry-run=client -o yaml | oc apply -f -

  log "Created/updated ${MLFLOW_NAMESPACE}/${MLFLOW_DB_SECRET_NAME} with key ${MLFLOW_DB_SECRET_KEY}."
}

###############################################################################
# Trust CNPG PostgreSQL CA in RHOAI trusted bundle
###############################################################################

trust_mlflow_db_ca() {
  if ! as_bool "${MLFLOW_DB_TRUST_CNPG_CA:-true}"; then
    log "MLFLOW_DB_TRUST_CNPG_CA=false; skipping MLflow DB CA trust setup."
    return 0
  fi

  local ca_secret="${MLFLOW_DB_CA_SECRET_NAME:-${MLFLOW_DB_CLUSTER_NAME}-ca}"
  local ca_key="${MLFLOW_DB_CA_SECRET_KEY:-ca.crt}"
  local trusted_cm="${MLFLOW_RHOAI_TRUSTED_CA_CONFIGMAP:-odh-trusted-ca-bundle}"
  local timeout="${MLFLOW_RHOAI_TRUSTED_CA_WAIT_TIMEOUT_SECONDS:-600}"
  local interval="${MLFLOW_RHOAI_TRUSTED_CA_WAIT_INTERVAL_SECONDS:-15}"

  wait_until "CNPG MLflow CA secret ${MLFLOW_DB_NAMESPACE}/${ca_secret}" 600 15     "oc get secret '${ca_secret}' -n '${MLFLOW_DB_NAMESPACE}' >/dev/null 2>&1"

  log "Adding CNPG MLflow DB CA ${MLFLOW_DB_NAMESPACE}/${ca_secret}:${ca_key} to DSCInitialization ${DSCI_NAME} trustedCABundle.customCABundle."

  local patch_file
  patch_file="$(mktemp)"

  DSCI_NAME_ENV="${DSCI_NAME}"   MLFLOW_DB_NAMESPACE_ENV="${MLFLOW_DB_NAMESPACE}"   MLFLOW_DB_CA_SECRET_NAME_ENV="${ca_secret}"   MLFLOW_DB_CA_SECRET_KEY_ENV="${ca_key}"   python3 - <<'PY_TRUST_CA' > "${patch_file}"
import base64
import json
import os
import subprocess
import sys

dsci_name = os.environ["DSCI_NAME_ENV"]
ns = os.environ["MLFLOW_DB_NAMESPACE_ENV"]
secret_name = os.environ["MLFLOW_DB_CA_SECRET_NAME_ENV"]
secret_key = os.environ["MLFLOW_DB_CA_SECRET_KEY_ENV"]

secret_raw = subprocess.check_output(
    ["oc", "get", "secret", secret_name, "-n", ns, "-o", "json"],
    text=True,
)
secret = json.loads(secret_raw)

try:
    ca = base64.b64decode(secret["data"][secret_key]).decode().strip()
except KeyError as exc:
    print(f"Secret {ns}/{secret_name} does not contain key {secret_key}: {exc}", file=sys.stderr)
    sys.exit(1)

try:
    current = subprocess.check_output(
        ["oc", "get", "dsci", dsci_name, "-o", "jsonpath={.spec.trustedCABundle.customCABundle}"],
        text=True,
        stderr=subprocess.DEVNULL,
    )
except subprocess.CalledProcessError:
    current = ""

current = current or ""

if ca in current:
    combined = current
elif current.strip():
    combined = current.rstrip() + "\n\n" + ca + "\n"
else:
    combined = ca + "\n"

print(json.dumps({
    "spec": {
        "trustedCABundle": {
            "managementState": "Managed",
            "customCABundle": combined,
        }
    }
}))
PY_TRUST_CA

  oc patch dsci "${DSCI_NAME}" --type=merge --patch-file "${patch_file}"
  rm -f "${patch_file}"

  wait_until "DSCInitialization ${DSCI_NAME} Ready after MLflow DB CA trust patch" 600 15     "test \"$(oc get dscinitialization '${DSCI_NAME}' -o jsonpath='{.status.phase}' 2>/dev/null)\" = Ready"

  log "Waiting for ${MLFLOW_NAMESPACE}/${trusted_cm} to contain the MLflow DB CA."

  local ca_file bundle_file start now elapsed
  ca_file="$(mktemp)"
  bundle_file="$(mktemp)"

  oc get secret "${ca_secret}" -n "${MLFLOW_DB_NAMESPACE}" -o jsonpath="{.data.ca\.crt}" | base64 -d > "${ca_file}"

  start="$(date +%s)"

  while true; do
    if oc get configmap "${trusted_cm}" -n "${MLFLOW_NAMESPACE}" -o json >/dev/null 2>&1; then
      oc get configmap "${trusted_cm}" -n "${MLFLOW_NAMESPACE}" -o json | python3 -c '
import json
import sys
data = (json.load(sys.stdin).get("data", {}) or {})
print("\n".join(str(v) for v in data.values()))
' > "${bundle_file}" || true

      if python3 - "${ca_file}" "${bundle_file}" <<'PY_CONTAINS'
import pathlib
import sys

ca = pathlib.Path(sys.argv[1]).read_text().strip()
bundle = pathlib.Path(sys.argv[2]).read_text()

sys.exit(0 if ca and ca in bundle else 1)
PY_CONTAINS
      then
        rm -f "${ca_file}" "${bundle_file}"
        log "Ready: ${MLFLOW_NAMESPACE}/${trusted_cm} contains the MLflow DB CA."
        break
      fi
    fi

    now="$(date +%s)"
    elapsed=$(( now - start ))

    if (( elapsed >= timeout )); then
      rm -f "${ca_file}" "${bundle_file}"
      die "Timed out waiting for ${MLFLOW_NAMESPACE}/${trusted_cm} to contain MLflow DB CA"
    fi

    log "Waiting for: ${MLFLOW_NAMESPACE}/${trusted_cm} to contain MLflow DB CA (${elapsed}s/${timeout}s)"
    sleep "${interval}"
  done

  if as_bool "${MLFLOW_RESTART_EXISTING_AFTER_CA_UPDATE:-true}"; then
    if oc get deployment -n "${MLFLOW_NAMESPACE}" "${MLFLOW_NAME}" >/dev/null 2>&1; then
      log "Restarting existing MLflow deployment so init containers rebuild the combined CA bundle."
      oc rollout restart deployment -n "${MLFLOW_NAMESPACE}" "${MLFLOW_NAME}"
      oc rollout status deployment -n "${MLFLOW_NAMESPACE}" "${MLFLOW_NAME}" --timeout=600s || warn "MLflow rollout did not complete yet; wait_for_mlflow will continue checking."
    fi
  fi
}

###############################################################################
# S3 artifact storage via ODF/NooBaa ObjectBucketClaim
###############################################################################

create_mlflow_object_bucket() {
  if ! as_bool "${MLFLOW_S3_ENABLED:-true}"; then
    log "MLFLOW_S3_ENABLED=false; skipping S3/ObjectBucketClaim."
    return 0
  fi

  ensure_namespace "${MLFLOW_OBC_NAMESPACE}"

  cat <<EOF_OBC | oc apply -f -
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${MLFLOW_OBC_NAME}
  namespace: ${MLFLOW_OBC_NAMESPACE}
spec:
  generateBucketName: ${MLFLOW_OBC_GENERATE_BUCKET_NAME}
  storageClassName: ${MLFLOW_OBC_STORAGE_CLASS}
EOF_OBC

  wait_until "ObjectBucketClaim ${MLFLOW_OBC_NAMESPACE}/${MLFLOW_OBC_NAME} Bound" "${MLFLOW_OBC_WAIT_TIMEOUT_SECONDS}" "${MLFLOW_OBC_WAIT_INTERVAL_SECONDS}"     "test \"$(oc get obc '${MLFLOW_OBC_NAME}' -n '${MLFLOW_OBC_NAMESPACE}' -o jsonpath='{.status.phase}' 2>/dev/null)\" = Bound"

  wait_until "OBC Secret ${MLFLOW_OBC_NAME}" 300 10     "oc get secret -n '${MLFLOW_OBC_NAMESPACE}' '${MLFLOW_OBC_NAME}' >/dev/null 2>&1"

  wait_until "OBC ConfigMap ${MLFLOW_OBC_NAME}" 300 10     "oc get configmap -n '${MLFLOW_OBC_NAMESPACE}' '${MLFLOW_OBC_NAME}' >/dev/null 2>&1"
}

create_mlflow_s3_secret() {
  ensure_namespace "${MLFLOW_NAMESPACE}"

  local access_key secret_key bucket endpoint region
  access_key="$(oc get secret "${MLFLOW_OBC_NAME}" -n "${MLFLOW_OBC_NAMESPACE}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)"
  secret_key="$(oc get secret "${MLFLOW_OBC_NAME}" -n "${MLFLOW_OBC_NAMESPACE}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)"
  bucket="$(oc get configmap "${MLFLOW_OBC_NAME}" -n "${MLFLOW_OBC_NAMESPACE}" -o jsonpath='{.data.BUCKET_NAME}')"
  region="${MLFLOW_S3_REGION:-us-east-1}"

  if [[ -n "${MLFLOW_S3_ENDPOINT_URL:-}" ]]; then
    endpoint="${MLFLOW_S3_ENDPOINT_URL}"
  else
    local host port scheme
    host="$(oc get configmap "${MLFLOW_OBC_NAME}" -n "${MLFLOW_OBC_NAMESPACE}" -o jsonpath='{.data.BUCKET_HOST}')"
    port="$(oc get configmap "${MLFLOW_OBC_NAME}" -n "${MLFLOW_OBC_NAMESPACE}" -o jsonpath='{.data.BUCKET_PORT}')"
    scheme="https"
    [[ "${port}" == "80" ]] && scheme="http"
    endpoint="${scheme}://${host}:${port}"
  fi

  [[ -n "${bucket}" ]] || die "Could not determine OBC bucket name."
  [[ -n "${endpoint}" ]] || die "Could not determine S3 endpoint."

  oc create secret generic "${MLFLOW_S3_SECRET_NAME}"     -n "${MLFLOW_NAMESPACE}"     --from-literal=AWS_ACCESS_KEY_ID="${access_key}"     --from-literal=AWS_SECRET_ACCESS_KEY="${secret_key}"     --from-literal=AWS_DEFAULT_REGION="${region}"     --from-literal=AWS_REGION="${region}"     --from-literal=AWS_EC2_METADATA_DISABLED="true"     --from-literal=MLFLOW_S3_ENDPOINT_URL="${endpoint}"     --from-literal=AWS_S3_ENDPOINT="${endpoint}"     --from-literal=AWS_S3_BUCKET="${bucket}"     --dry-run=client -o yaml | oc apply -f -

  log "Created/updated ${MLFLOW_NAMESPACE}/${MLFLOW_S3_SECRET_NAME}; bucket=${bucket}; endpoint=${endpoint}."
}

mlflow_bucket_name() {
  oc get configmap "${MLFLOW_OBC_NAME}" -n "${MLFLOW_OBC_NAMESPACE}" -o jsonpath='{.data.BUCKET_NAME}'
}

###############################################################################
# MLflow CR
###############################################################################

apply_mlflow_cr() {
  ensure_namespace "${MLFLOW_NAMESPACE}"

  local bucket artifact_path destination
  bucket="$(mlflow_bucket_name)"
  artifact_path="${MLFLOW_ARTIFACT_PATH#/}"

  if [[ -n "${artifact_path}" ]]; then
    destination="s3://${bucket}/${artifact_path}"
  else
    destination="s3://${bucket}"
  fi

  log "Applying MLflow CR ${MLFLOW_NAMESPACE}/${MLFLOW_NAME}; artifactsDestination=${destination}; replicas=${MLFLOW_REPLICAS}."

  cat <<EOF_MLFLOW | oc apply -f -
apiVersion: ${MLFLOW_API_VERSION}
kind: MLflow
metadata:
  name: ${MLFLOW_NAME}
  namespace: ${MLFLOW_NAMESPACE}
spec:
  replicas: ${MLFLOW_REPLICAS}
  backendStoreUriFrom:
    name: ${MLFLOW_DB_SECRET_NAME}
    key: ${MLFLOW_DB_SECRET_KEY}
  artifactsDestination: "${destination}"
  serveArtifacts: ${MLFLOW_SERVE_ARTIFACTS}
  envFrom:
    - secretRef:
        name: ${MLFLOW_S3_SECRET_NAME}
EOF_MLFLOW
}

mlflow_cr_status_ready() {
  local raw
  raw="$(oc get mlflow "${MLFLOW_NAME}" -n "${MLFLOW_NAMESPACE}" -o json 2>/dev/null || true)"
  [[ -n "${raw}" ]] || return 1

  python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

conds = data.get("status", {}).get("conditions", []) or []
for condition in conds:
    if condition.get("type") in ("Ready", "Available", "ReconcileComplete") and condition.get("status") == "True":
        sys.exit(0)

phase = str(data.get("status", {}).get("phase", "")).lower()
if phase in ("ready", "available", "running"):
    sys.exit(0)

sys.exit(1)
' <<< "${raw}"
}

mlflow_workload_ready() {
  local raw
  raw="$(oc get deployment,statefulset,pod -n "${MLFLOW_NAMESPACE}" -o json 2>/dev/null || true)"
  [[ -n "${raw}" ]] || return 1

  python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

items = [
    item for item in data.get("items", [])
    if "mlflow" in item.get("metadata", {}).get("name", "").lower()
]

if not items:
    sys.exit(1)

for item in items:
    kind = item.get("kind", "")
    status = item.get("status", {}) or {}

    if kind in ("Deployment", "StatefulSet"):
        desired = item.get("spec", {}).get("replicas", 1) or 1
        available = status.get("availableReplicas", status.get("readyReplicas", 0)) or 0
        if available >= desired:
            sys.exit(0)

    if kind == "Pod" and status.get("phase") == "Running":
        container_statuses = status.get("containerStatuses", []) or []
        if container_statuses and all(container.get("ready") for container in container_statuses):
            sys.exit(0)

sys.exit(1)
' <<< "${raw}"
}

wait_for_mlflow() {
  wait_until "MLflow CR ${MLFLOW_NAMESPACE}/${MLFLOW_NAME} exists" 300 10     "oc get mlflow '${MLFLOW_NAME}' -n '${MLFLOW_NAMESPACE}' >/dev/null 2>&1"

  local start now elapsed
  start="$(date +%s)"

  while true; do
    if mlflow_cr_status_ready || mlflow_workload_ready; then
      log "Ready: MLflow control plane"
      return 0
    fi

    now="$(date +%s)"
    elapsed=$(( now - start ))

    if (( elapsed >= MLFLOW_WAIT_TIMEOUT_SECONDS )); then
      warn "MLflow did not report ready before timeout; printing current state."
      oc get mlflow "${MLFLOW_NAME}" -n "${MLFLOW_NAMESPACE}" -o yaml || true
      oc get pods,deploy,statefulset,svc,route -n "${MLFLOW_NAMESPACE}" | grep -Ei 'NAME|mlflow' || true
      die "Timed out waiting for MLflow control plane"
    fi

    log "Waiting for: MLflow control plane (${elapsed}s/${MLFLOW_WAIT_TIMEOUT_SECONDS}s)"
    sleep "${MLFLOW_WAIT_INTERVAL_SECONDS}"
  done
}

restart_dashboard() {
  if ! as_bool "${DASHBOARD_RESTART_AFTER_MLFLOW:-true}"; then
    log "DASHBOARD_RESTART_AFTER_MLFLOW=false; skipping dashboard restart."
    return 0
  fi

  if oc get deployment -n "${DASHBOARD_DEPLOYMENT_NAMESPACE}" "${DASHBOARD_DEPLOYMENT_NAME}" >/dev/null 2>&1; then
    oc rollout restart deployment -n "${DASHBOARD_DEPLOYMENT_NAMESPACE}" "${DASHBOARD_DEPLOYMENT_NAME}"
    oc rollout status deployment -n "${DASHBOARD_DEPLOYMENT_NAMESPACE}" "${DASHBOARD_DEPLOYMENT_NAME}" --timeout=600s
  else
    warn "Dashboard deployment ${DASHBOARD_DEPLOYMENT_NAMESPACE}/${DASHBOARD_DEPLOYMENT_NAME} not found; skipping restart."
  fi
}

###############################################################################
# Optional project MLflowConfig
###############################################################################

configure_project_mlflow_configs() {
  if ! as_bool "${MLFLOW_CREATE_PROJECT_CONFIGS:-false}"; then
    log "MLFLOW_CREATE_PROJECT_CONFIGS=false; skipping project MLflowConfig resources."
    return 0
  fi

  local project

  while read -r project; do
    [[ -z "${project}" ]] && continue

    ensure_namespace "${project}"

    local access_key secret_key bucket endpoint region root_path
    access_key="$(oc get secret "${MLFLOW_OBC_NAME}" -n "${MLFLOW_OBC_NAMESPACE}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)"
    secret_key="$(oc get secret "${MLFLOW_OBC_NAME}" -n "${MLFLOW_OBC_NAMESPACE}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)"
    bucket="$(mlflow_bucket_name)"
    endpoint="${MLFLOW_S3_ENDPOINT_URL:-http://s3.openshift-storage.svc:80}"
    region="${MLFLOW_S3_REGION:-us-east-1}"
    root_path="${MLFLOW_PROJECT_ARTIFACT_ROOT_PATH%/}/${project}"

    oc create secret generic "${MLFLOW_PROJECT_ARTIFACT_SECRET_NAME}"       -n "${project}"       --from-literal=AWS_ACCESS_KEY_ID="${access_key}"       --from-literal=AWS_SECRET_ACCESS_KEY="${secret_key}"       --from-literal=AWS_S3_BUCKET="${bucket}"       --from-literal=AWS_S3_ENDPOINT="${endpoint}"       --from-literal=AWS_DEFAULT_REGION="${region}"       --dry-run=client -o yaml | oc apply -f -

    oc annotate secret "${MLFLOW_PROJECT_ARTIFACT_SECRET_NAME}" -n "${project}"       opendatahub.io/connection-type-protocol="s3" --overwrite

    cat <<EOF_PROJECT_CONFIG | oc apply -f -
apiVersion: mlflow.kubeflow.org/v1
kind: MLflowConfig
metadata:
  name: mlflow
  namespace: ${project}
spec:
  artifactRootSecret: ${MLFLOW_PROJECT_ARTIFACT_SECRET_NAME}
  artifactRootPath: ${root_path}
EOF_PROJECT_CONFIG

    log "Configured project MLflowConfig for namespace ${project}."
  done < <(split_csv "${MLFLOW_PROJECT_NAMES}")
}

###############################################################################
# Validation summary
###############################################################################

validation_summary() {
  if ! as_bool "${MLFLOW_PRINT_VALIDATION_SUMMARY:-true}"; then
    return 0
  fi

  echo
  echo "=== MLflow validation summary ==="
  echo

  echo "--- DataScienceCluster MLflow component ---"
  oc get datasciencecluster "${DSC_NAME}" -o jsonpath='{.spec.components.mlflowoperator.managementState}{"\n"}' 2>/dev/null || true

  echo
  echo "--- MLflow CR ---"
  oc get mlflow -n "${MLFLOW_NAMESPACE}" "${MLFLOW_NAME}" -o wide 2>/dev/null || oc get mlflow -n "${MLFLOW_NAMESPACE}" "${MLFLOW_NAME}" 2>/dev/null || true
  oc get mlflow -n "${MLFLOW_NAMESPACE}" "${MLFLOW_NAME}" -o jsonpath='{.status}{"\n"}' 2>/dev/null || true

  echo
  echo "--- MLflow pods/services ---"
  oc get pods,svc,route -n "${MLFLOW_NAMESPACE}" | grep -Ei 'NAME|mlflow' || true

  echo
  echo "--- MLflow PostgreSQL ---"
  oc get cluster.postgresql.cnpg.io -n "${MLFLOW_DB_NAMESPACE}" "${MLFLOW_DB_CLUSTER_NAME}" || true
  oc get secret -n "${MLFLOW_NAMESPACE}" "${MLFLOW_DB_SECRET_NAME}" || true
  oc get secret -n "${MLFLOW_DB_NAMESPACE}" "${MLFLOW_DB_CA_SECRET_NAME}" || true

  echo
  echo "--- MLflow DB CA trust ---"
  oc get configmap -n "${MLFLOW_NAMESPACE}" "${MLFLOW_RHOAI_TRUSTED_CA_CONFIGMAP}" || true

  echo
  echo "--- MLflow S3 / OBC ---"
  oc get obc -n "${MLFLOW_OBC_NAMESPACE}" "${MLFLOW_OBC_NAME}" || true
  oc get secret -n "${MLFLOW_NAMESPACE}" "${MLFLOW_S3_SECRET_NAME}" || true
  oc get configmap -n "${MLFLOW_OBC_NAMESPACE}" "${MLFLOW_OBC_NAME}" -o jsonpath='bucket={.data.BUCKET_NAME}{"\n"}host={.data.BUCKET_HOST}{"\n"}port={.data.BUCKET_PORT}{"\n"}' 2>/dev/null || true

  echo
  echo "Tracker file: ${TRACKER_FILE}"
}

###############################################################################
# Main
###############################################################################

main() {
  init_tracker

  run_step "mlflow_preflight_checked" preflight_check
  run_step "mlflow_operator_component_enabled" enable_mlflow_operator_component
  run_step "mlflow_postgres_created" create_mlflow_postgres
  run_step "mlflow_db_secret_created" create_mlflow_db_secret
  run_step "mlflow_db_ca_trusted" trust_mlflow_db_ca
  run_step "mlflow_object_bucket_created" create_mlflow_object_bucket
  run_step "mlflow_s3_secret_created" create_mlflow_s3_secret
  run_step "mlflow_cr_applied" apply_mlflow_cr
  run_step "mlflow_ready" wait_for_mlflow
  run_step "mlflow_project_configs_handled" configure_project_mlflow_configs
  run_step "mlflow_dashboard_restarted" restart_dashboard
  run_step "mlflow_validation_complete" validation_summary
}

main "$@"
