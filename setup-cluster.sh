#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/setup-cluster.conf"
TRACKER_FILE="${SCRIPT_DIR}/setup-cluster.tracker.json"

RESET_REQUESTED="false"

for arg in "$@"; do
  case "${arg}" in
    config=*)
      CONFIG_FILE="${arg#config=}"
      ;;
    reset=true|RESET=true)
      RESET_REQUESTED="true"
      ;;
    reset=false|RESET=false)
      RESET_REQUESTED="false"
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Supported arguments: config=/path/to/setup-cluster.conf reset=true" >&2
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

  python3 - "${TRACKER_FILE}" "${step}" <<'PY'
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
PY
}

mark_step_done() {
  local step="$1"

  python3 - "${TRACKER_FILE}" "${step}" <<'PY'
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
PY
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

  local start
  local now
  local elapsed
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
  found_source="$(oc get packagemanifest "${package}" -n "${DEFAULT_OPERATOR_SOURCE_NAMESPACE}" -o jsonpath='{.status.catalogSource}' 2>/dev/null || true)"
  [[ "${found_source}" == "${source}" ]]
}

find_package_from_candidates() {
  local candidates="$1"
  local source="$2"

  local pkg
  while read -r pkg; do
    [[ -z "${pkg}" ]] && continue

    if oc get packagemanifest "${pkg}" -n "${DEFAULT_OPERATOR_SOURCE_NAMESPACE}" >/dev/null 2>&1; then
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
  oc get packagemanifest "${package}" -n "${DEFAULT_OPERATOR_SOURCE_NAMESPACE}" -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true
}

catalog_source_for_package() {
  local package="$1"
  oc get packagemanifest "${package}" -n "${DEFAULT_OPERATOR_SOURCE_NAMESPACE}" -o jsonpath='{.status.catalogSource}' 2>/dev/null || true
}

installed_csv_for_subscription() {
  local ns="$1"
  local sub="$2"
  oc get subscription -n "${ns}" "${sub}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true
}

csv_succeeded_for_subscription() {
  local ns="$1"
  local sub="$2"

  local csv
  csv="$(installed_csv_for_subscription "${ns}" "${sub}")"
  [[ -n "${csv}" ]] || return 1

  [[ "$(oc get csv -n "${ns}" "${csv}" -o jsonpath='{.status.phase}' 2>/dev/null || true)" == "Succeeded" ]]
}

wait_for_subscription_csv_succeeded() {
  local ns="$1"
  local sub="$2"
  local label="$3"
  local timeout="${4:-${OPERATOR_WAIT_TIMEOUT_SECONDS}}"
  local interval="${5:-30}"
  local required_csv="${6:-}"

  local start
  local now
  local elapsed
  local summary

  start="$(date +%s)"

  while true; do
    local rc
    set +e
    summary="$(
      NS="${ns}" SUB="${sub}" LABEL="${label}" REQUIRED_CSV="${required_csv}" python3 - <<'PYWAIT'
import json
import os
import subprocess
import sys

ns = os.environ["NS"]
sub = os.environ["SUB"]
required_csv = os.environ.get("REQUIRED_CSV", "")

def oc_json(args):
    try:
        out = subprocess.check_output(["oc"] + args, stderr=subprocess.DEVNULL, text=True)
        return json.loads(out)
    except Exception:
        return None

def oc_text(args):
    try:
        return subprocess.check_output(["oc"] + args, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ""

def csv_phase(namespace, name):
    if not namespace or not name:
        return ""
    return oc_text(["get", "csv", "-n", namespace, name, "-o", "jsonpath={.status.phase}"])

def csv_reason(namespace, name):
    if not namespace or not name:
        return ""
    return oc_text(["get", "csv", "-n", namespace, name, "-o", "jsonpath={.status.reason}"])

def succeeded(namespace, name, source):
    phase = csv_phase(namespace, name)
    if phase == "Succeeded":
        print(f"READY|{source}|{namespace}|{name}|{phase}|")
        sys.exit(0)
    return phase

sub_obj = oc_json(["get", "subscription", "-n", ns, sub, "-o", "json"])
installed = ""
package_name = sub

if sub_obj:
    installed = (((sub_obj.get("status") or {}).get("installedCSV")) or "")
    package_name = (((sub_obj.get("spec") or {}).get("name")) or sub)

# 1) Normal path: subscription.status.installedCSV.
if installed:
    succeeded(ns, installed, "subscription.installedCSV")

# 2) Exact required/starting CSV in the subscription namespace.
if required_csv:
    succeeded(ns, required_csv, "requiredCSV.namespace")

# 3) RHCL-specific exact cluster-wide guard.
# OLM sometimes exposes copied CSVs across managed namespaces. For the RHCL pin,
# exact CSV anywhere is enough to avoid waiting forever, because the next guard
# validates the installed RHCL CSV name anyway.
if required_csv == "rhcl-operator.v1.3.3":
    all_csv = oc_json(["get", "csv", "-A", "-o", "json"])
    if all_csv:
        for item in all_csv.get("items", []):
            name = item.get("metadata", {}).get("name", "")
            namespace = item.get("metadata", {}).get("namespace", "")
            phase = (item.get("status") or {}).get("phase", "")
            if name == required_csv and phase == "Succeeded":
                print(f"READY|requiredCSV.anyNamespace|{namespace}|{name}|{phase}|")
                sys.exit(0)

# 4) Fallback: any Succeeded CSV in namespace that appears to match package/subscription.
csvs = oc_json(["get", "csv", "-n", ns, "-o", "json"])
if csvs:
    candidates = []
    for item in csvs.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        phase = (item.get("status") or {}).get("phase", "")
        if phase != "Succeeded":
            continue

        lowered = name.lower()
        pkg = package_name.lower()
        s = sub.lower()

        if pkg in lowered or s in lowered or lowered.startswith(pkg + ".") or lowered.startswith(s + "."):
            candidates.append(name)

    if candidates:
        name = sorted(candidates)[-1]
        print(f"READY|matchingCSV.namespace|{ns}|{name}|Succeeded|")
        sys.exit(0)

# Not ready. Print a compact status line.
phase = csv_phase(ns, installed) if installed else ""
reason = csv_reason(ns, installed) if installed else ""
print(f"WAIT|installedCSV|{ns}|{installed or 'none'}|{phase or 'unknown'}|{reason or 'none'}")
sys.exit(1)
PYWAIT
    )"
    rc=$?
    set -e

    if [[ ${rc} -eq 0 && "${summary}" == READY* ]]; then
      IFS='|' read -r _ source ready_ns ready_csv ready_phase _ <<< "${summary}"
      log "Ready: CSV Succeeded for ${label}: source=${source}, namespace=${ready_ns}, csv=${ready_csv}, phase=${ready_phase}"
      return 0
    fi

    now="$(date +%s)"
    elapsed=$(( now - start ))

    if (( elapsed >= timeout )); then
      warn "Timed out waiting for CSV Succeeded for ${label}"
      warn "Last status: ${summary}"
      echo
      echo "=== Subscription ${ns}/${sub} ==="
      oc get subscription -n "${ns}" "${sub}" -o yaml 2>/dev/null || true
      echo
      echo "=== CSVs in ${ns} ==="
      oc get csv -n "${ns}" 2>/dev/null || true
      echo
      echo "=== InstallPlans in ${ns} ==="
      oc get installplan -n "${ns}" 2>/dev/null || true
      echo
      echo "=== Related CSVs across all namespaces ==="
      oc get csv -A 2>/dev/null | grep -E 'rhcl-operator|authorino-operator|dns-operator|limitador-operator|cert-manager-operator' || true
      die "Timed out waiting for: CSV Succeeded for ${label}"
    fi

    log "Waiting for CSV Succeeded for ${label}: ${summary} (${elapsed}s/${timeout}s)"
    sleep "${interval}"
  done
}


###############################################################################
# OperatorGroup helpers
#
# Important:
# - Do not delete an existing compatible OperatorGroup just because its name
#   differs from what this script would create.
# - If an incompatible OperatorGroup exists, fail loudly unless the config
#   explicitly allows replacement.
###############################################################################

operatorgroup_mode_for_object() {
  local ns="$1"
  local og="$2"

  local targets
  targets="$(oc get operatorgroup -n "${ns}" "${og}" -o jsonpath='{.spec.targetNamespaces}' 2>/dev/null || true)"

  if [[ -z "${targets}" || "${targets}" == "[]" ]]; then
    echo "all"
  elif [[ "${targets}" == "[\"${ns}\"]" || "${targets}" == "${ns}" ]]; then
    echo "own"
  else
    echo "other"
  fi
}

find_compatible_operatorgroup() {
  local ns="$1"
  local desired_mode="$2"

  local og
  while read -r og; do
    [[ -z "${og}" ]] && continue

    local name
    name="${og##*/}"

    local mode
    mode="$(operatorgroup_mode_for_object "${ns}" "${name}")"

    if [[ "${mode}" == "${desired_mode}" ]]; then
      echo "${name}"
      return 0
    fi
  done < <(oc get operatorgroup -n "${ns}" -o name 2>/dev/null || true)

  return 1
}

delete_operatorgroups_in_namespace() {
  local ns="$1"

  oc get operatorgroup -n "${ns}" -o name 2>/dev/null | while read -r og; do
    [[ -z "${og}" ]] && continue
    log "Deleting incompatible OperatorGroup ${og} in namespace ${ns}"
    oc delete -n "${ns}" "${og}" --ignore-not-found
  done
}

ensure_operatorgroup() {
  local ns="$1"
  local name="$2"
  local desired_mode="$3"

  ensure_namespace "${ns}"

  local existing
  existing="$(find_compatible_operatorgroup "${ns}" "${desired_mode}" || true)"

  if [[ -n "${existing}" ]]; then
    log "Using existing compatible OperatorGroup ${ns}/${existing} mode=${desired_mode}"
    return 0
  fi

  local existing_count
  existing_count="$(oc get operatorgroup -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  if [[ "${existing_count}" != "0" ]]; then
    if as_bool "${OPERATORGROUP_REPLACE_INCOMPATIBLE:-false}"; then
      warn "Replacing incompatible OperatorGroup(s) in ${ns} because OPERATORGROUP_REPLACE_INCOMPATIBLE=true"
      delete_operatorgroups_in_namespace "${ns}"
    else
      oc get operatorgroup -n "${ns}" || true
      die "Namespace ${ns} has existing incompatible OperatorGroup(s). Refusing to delete them. Set OPERATORGROUP_REPLACE_INCOMPATIBLE=true only if you explicitly want replacement."
    fi
  fi

  log "Creating OperatorGroup ${ns}/${name} mode=${desired_mode}"

  if [[ "${desired_mode}" == "all" ]]; then
    cat <<EOF_OG | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${name}
  namespace: ${ns}
spec: {}
EOF_OG
  else
    cat <<EOF_OG | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  targetNamespaces:
  - ${ns}
EOF_OG
  fi
}

ensure_ownnamespace_operatorgroup() {
  local ns="$1"
  local name="$2"
  ensure_operatorgroup "${ns}" "${name}" "own"
}

ensure_allnamespace_operatorgroup() {
  local ns="$1"
  local name="$2"
  ensure_operatorgroup "${ns}" "${name}" "all"
}

###############################################################################
# OLM helpers
###############################################################################

install_operator() {
  local label="$1"
  local ns="$2"
  local package_candidates="$3"
  local channel="$4"
  local source="$5"
  local subscription_name="$6"
  local operatorgroup_mode="$7"
  local starting_csv="${8:-}"
  local approval="${9:-${OPERATOR_INSTALLPLAN_APPROVAL:-Automatic}}"

  ensure_namespace "${ns}"

  if [[ "${operatorgroup_mode}" == "all" ]]; then
    ensure_allnamespace_operatorgroup "${ns}" "${subscription_name}-operatorgroup"
  else
    ensure_ownnamespace_operatorgroup "${ns}" "${subscription_name}-operatorgroup"
  fi

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

  local existing_csv
  existing_csv="$(installed_csv_for_subscription "${ns}" "${subscription_name}")"

  if [[ -n "${existing_csv}" ]]; then
    local existing_phase
    existing_phase="$(oc get csv -n "${ns}" "${existing_csv}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    log "${label} subscription already exists: installedCSV=${existing_csv}, phase=${existing_phase}"
  fi

  log "Applying ${label} Subscription: package=${package}, channel=${channel}, source=${source}, namespace=${ns}, subscription=${subscription_name}, approval=${approval}, startingCSV=${starting_csv:-none}"

  if [[ -n "${starting_csv}" ]]; then
    cat <<EOF_SUB | oc apply -f -
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
  sourceNamespace: ${DEFAULT_OPERATOR_SOURCE_NAMESPACE}
  startingCSV: ${starting_csv}
EOF_SUB
  else
    cat <<EOF_SUB | oc apply -f -
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
  sourceNamespace: ${DEFAULT_OPERATOR_SOURCE_NAMESPACE}
EOF_SUB
  fi

  if csv_succeeded_for_subscription "${ns}" "${subscription_name}"; then
    local ready_csv
    ready_csv="$(installed_csv_for_subscription "${ns}" "${subscription_name}")"
    log "Ready: CSV already Succeeded for ${label}: ${ready_csv}"
    return 0
  fi

  if [[ "${approval}" == "Manual" ]]; then
    log "Manual approval requested for ${label}; checking for matching InstallPlan."

    if approve_installplan_for_subscription "${ns}" "${subscription_name}" "${starting_csv}" "${label}"; then
      log "InstallPlan approval completed for ${label}"
    else
      warn "No matching InstallPlan was approved for ${label}; continuing to CSV readiness check."
    fi
  fi

  if csv_succeeded_for_subscription "${ns}" "${subscription_name}"; then
    local ready_csv
    ready_csv="$(installed_csv_for_subscription "${ns}" "${subscription_name}")"
    log "Ready: CSV Succeeded for ${label}: ${ready_csv}"
    return 0
  fi

  wait_for_subscription_csv_succeeded "${ns}" "${subscription_name}" "${label}" "${OPERATOR_WAIT_TIMEOUT_SECONDS}" 30 "${starting_csv}"
}

approve_installplan_for_subscription() {
  local ns="$1"
  local sub="$2"
  local required_csv="$3"
  local label="$4"

  local start
  local now
  start="$(date +%s)"

  while true; do
    local ip
    ip="$(
      oc get installplan -n "${ns}" -o json 2>/dev/null | \
      REQUIRED_CSV="${required_csv}" SUB_NAME="${sub}" python3 -c '
import json
import os
import sys

required = os.environ.get("REQUIRED_CSV", "")
data = json.load(sys.stdin)

for item in data.get("items", []):
    csvs = item.get("spec", {}).get("clusterServiceVersionNames", []) or []
    approved = item.get("spec", {}).get("approved", False)
    phase = item.get("status", {}).get("phase", "")
    if approved or phase in ("Complete", "Failed"):
        continue

    if required:
        if required in csvs:
            print(item["metadata"]["name"])
            sys.exit(0)
    elif csvs:
        print(item["metadata"]["name"])
        sys.exit(0)

sys.exit(1)
' || true
    )"

    if [[ -n "${ip}" ]]; then
      log "Approving InstallPlan ${ns}/${ip} for ${label}"
      oc get installplan -n "${ns}" "${ip}" -o jsonpath='{.spec.clusterServiceVersionNames}{"\n"}' || true
      oc patch installplan -n "${ns}" "${ip}" --type=merge -p '{"spec":{"approved":true}}'
      return 0
    fi

    if csv_succeeded_for_subscription "${ns}" "${sub}"; then
      local ready_csv
      ready_csv="$(installed_csv_for_subscription "${ns}" "${sub}")"
      log "No InstallPlan approval needed for ${label}; CSV already Succeeded: ${ready_csv}"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= OPERATOR_WAIT_TIMEOUT_SECONDS )); then
      warn "Timed out waiting for InstallPlan for ${label} subscription ${ns}/${sub}; no InstallPlan may be needed if the CSV is already installed."
      return 1
    fi

    log "Waiting for matching InstallPlan for ${label}"
    sleep 10
  done
}

find_csv_matching_regex_in_packagemanifest() {
  local package="$1"
  local channel="$2"
  local regex="$3"

  local tmp
  tmp="$(mktemp)"
  oc get packagemanifest "${package}" -n "${DEFAULT_OPERATOR_SOURCE_NAMESPACE}" -o json > "${tmp}"

  CHANNEL="${channel}" REGEX="${regex}" python3 - "${tmp}" <<'PY'
import json
import os
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())

channel = os.environ.get("CHANNEL", "")
regex = re.compile(os.environ["REGEX"])

channels = data.get("status", {}).get("channels", []) or []
wanted = []

for ch in channels:
    if channel and ch.get("name") != channel:
        continue
    wanted.append(ch)

if not wanted:
    wanted = channels

matches = []
for ch in wanted:
    current = ch.get("currentCSV", "")
    if current and regex.search(current):
        matches.append(current)

    for entry in ch.get("entries", []) or []:
        name = entry.get("name", "")
        if name and regex.search(name):
            matches.append(name)

seen = []
for m in matches:
    if m not in seen:
        seen.append(m)

if not seen:
    sys.exit(1)

print(seen[-1])
PY

  local rc=$?
  rm -f "${tmp}"
  return "${rc}"
}

create_managed_instance_for_kind() {
  local kind="$1"
  local name="$2"
  local namespace="$3"
  local timeout="$4"

  wait_until "${kind} CRD available" "${timeout}" 10 \
    "oc get crd -o json | KIND='${kind}' python3 -c 'import json,os,sys; data=json.load(sys.stdin); kind=os.environ[\"KIND\"]; sys.exit(0 if any(i.get(\"spec\",{}).get(\"names\",{}).get(\"kind\")==kind for i in data.get(\"items\",[])) else 1)'"

  local tmp
  tmp="$(mktemp)"
  oc get crd -o json > "${tmp}"

  local gv
  gv="$(
    KIND="${kind}" python3 - "${tmp}" <<'PYDISCOVER'
import json
import os
import pathlib
import sys

kind = os.environ["KIND"]
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())

for item in data.get("items", []):
    spec = item.get("spec", {}) or {}
    names = spec.get("names", {}) or {}

    if names.get("kind") != kind:
        continue

    group = spec.get("group", "")
    versions = spec.get("versions", []) or []

    # Prefer storage version, then any served version.
    for prefer_storage in (True, False):
        for version in versions:
            if not version.get("served"):
                continue
            if prefer_storage and not version.get("storage"):
                continue

            version_name = version.get("name", "")
            if group and version_name:
                print(group + "/" + version_name)
                sys.exit(0)

sys.exit(1)
PYDISCOVER
  )"

  rm -f "${tmp}"

  [[ -n "${gv}" ]] || die "Could not discover apiVersion for kind ${kind}"

  log "Creating/applying ${kind} ${namespace}/${name} using apiVersion ${gv}"

  cat <<EOF_CR | oc apply -f -
apiVersion: ${gv}
kind: ${kind}
metadata:
  name: ${name}
  namespace: ${namespace}
spec:
  managementState: Managed
EOF_CR
}


detect_storageclass() {
  if [[ -n "${ODF_MCG_STORAGE_CLASS:-}" ]]; then
    echo "${ODF_MCG_STORAGE_CLASS}"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  oc get storageclass -o json > "${tmp}"

  python3 - "${tmp}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
items = data.get("items", []) or []

for item in items:
    ann = item.get("metadata", {}).get("annotations", {}) or {}
    if ann.get("storageclass.kubernetes.io/is-default-class") == "true":
        print(item["metadata"]["name"])
        sys.exit(0)

if items:
    print(items[0]["metadata"]["name"])
    sys.exit(0)

sys.exit(1)
PY
  local rc=$?
  rm -f "${tmp}"
  return "${rc}"
}

###############################################################################
# Cluster bootstrap
###############################################################################

login_to_cluster() {
  if [[ -z "${API_ENDPOINT:-}" ]]; then
    warn "API_ENDPOINT is empty; assuming existing oc session."
    oc whoami >/dev/null
    return 0
  fi

  local tls_flag=""
  if as_bool "${INSECURE_SKIP_TLS_VERIFY:-false}"; then
    tls_flag="--insecure-skip-tls-verify=true"
  fi

  log "Logging in to ${API_ENDPOINT} as ${KUBEADMIN_USER}"
  oc login "${API_ENDPOINT}" \
    -u "${KUBEADMIN_USER}" \
    -p "${KUBEADMIN_PASSWORD}" \
    ${tls_flag}
}

configure_htpasswd_admin() {
  if ! as_bool "${CONFIGURE_HTPASSWD:-true}"; then
    log "CONFIGURE_HTPASSWD=false; skipping."
    return 0
  fi

  ensure_namespace "${OPENSHIFT_CONFIG_NAMESPACE}"

  [[ -n "${HTPASSWD_PATH:-}" ]] || die "HTPASSWD_PATH is empty. Set it in setup-cluster.conf."
  [[ -f "${HTPASSWD_PATH}" ]] || die "HTPASSWD_PATH file does not exist: ${HTPASSWD_PATH}. This script will not generate or overwrite htpasswd passwords."

  log "Applying existing htpasswd file only: ${HTPASSWD_PATH}"
  log "No htpasswd users or passwords will be generated, changed, or overwritten by this script."

  if [[ -n "${ADMIN_USER:-}" ]]; then
    if grep -q "^${ADMIN_USER}:" "${HTPASSWD_PATH}"; then
      log "Confirmed ADMIN_USER=${ADMIN_USER} exists in ${HTPASSWD_PATH}"
    else
      warn "ADMIN_USER=${ADMIN_USER} was not found in ${HTPASSWD_PATH}. The secret will still be applied, but this user may not be able to log in."
    fi
  fi

  oc -n "${OPENSHIFT_CONFIG_NAMESPACE}" create secret generic "${SECRET_NAME}" \
    --from-file=htpasswd="${HTPASSWD_PATH}" \
    --dry-run=client -o yaml | oc apply -f -

  cat > /tmp/oauth-htpasswd-patch.json <<EOF_OAUTH
{
  "spec": {
    "identityProviders": [
      {
        "name": "${IDP_NAME}",
        "mappingMethod": "claim",
        "type": "HTPasswd",
        "htpasswd": {
          "fileData": {
            "name": "${SECRET_NAME}"
          }
        }
      }
    ]
  }
}
EOF_OAUTH

  oc patch oauth cluster --type=merge --patch-file /tmp/oauth-htpasswd-patch.json
  rm -f /tmp/oauth-htpasswd-patch.json

  if [[ -n "${GROUP_NAME:-}" && -n "${ADMIN_USER:-}" ]]; then
    oc adm groups new "${GROUP_NAME}" "${ADMIN_USER}" >/dev/null 2>&1 || true
    oc adm groups add-users "${GROUP_NAME}" "${ADMIN_USER}" >/dev/null 2>&1 || true
    oc adm policy add-cluster-role-to-group cluster-admin "${GROUP_NAME}"
    log "Cluster-admin group configured: user=${ADMIN_USER}, group=${GROUP_NAME}"
  else
    warn "GROUP_NAME or ADMIN_USER is empty; skipping cluster-admin group binding."
  fi
}

detect_master_region() {
  local master_node
  master_node="$(
    oc get nodes -l node-role.kubernetes.io/master= -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  )"

  if [[ -z "${master_node}" ]]; then
    master_node="$(
      oc get nodes -l node-role.kubernetes.io/control-plane= -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
    )"
  fi

  [[ -n "${master_node}" ]] || die "Could not find a master/control-plane node"

  local master_region
  master_region="$(
    oc get node "${master_node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/region}' 2>/dev/null || true
  )"

  local master_zone
  master_zone="$(
    oc get node "${master_node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || true
  )"

  if [[ -z "${master_region}" && -n "${master_zone}" ]]; then
    master_region="$(echo "${master_zone}" | sed -E 's/[a-z]$//')"
  fi

  if [[ -z "${master_region}" ]]; then
    local provider_id
    provider_id="$(
      oc get node "${master_node}" -o jsonpath='{.spec.providerID}' 2>/dev/null || true
    )"

    if [[ "${provider_id}" =~ aws:///([a-z]{2}-[a-z]+-[0-9])[a-z]/.* ]]; then
      master_region="${BASH_REMATCH[1]}"
    fi
  fi

  [[ -n "${master_region}" ]] || die "Could not detect region from master/control-plane node ${master_node}"

  log "Detected master/control-plane node=${master_node}, region=${master_region}, zone=${master_zone:-unknown}" >&2
  echo "${master_region}"
}

discover_worker_machinesets_in_region() {
  local region="$1"

  local tmp
  tmp="$(mktemp)"
  oc get machineset -n "${MACHINESET_NAMESPACE}" -o json > "${tmp}"

  MASTER_REGION="${region}" python3 - "${tmp}" <<'PY'
import json
import os
import sys

region = os.environ["MASTER_REGION"]

with open(sys.argv[1]) as f:
    data = json.load(f)

matches = []

for item in data.get("items", []):
    name = item.get("metadata", {}).get("name", "")

    labels = item.get("metadata", {}).get("labels", {}) or {}

    spec = item.get("spec", {}) or {}
    tmpl = spec.get("template", {}) or {}
    tmpl_labels = tmpl.get("metadata", {}).get("labels", {}) or {}

    provider = tmpl.get("spec", {}).get("providerSpec", {}).get("value", {}) or {}
    placement = provider.get("placement", {}) or {}
    az = placement.get("availabilityZone", "") or ""

    role = (
        labels.get("machine.openshift.io/cluster-api-machine-role")
        or tmpl_labels.get("machine.openshift.io/cluster-api-machine-role")
        or ""
    )

    looks_worker = role == "worker" or "-worker-" in name or name.endswith("-worker")
    in_region = az.startswith(region) if az else True

    if looks_worker and in_region:
        matches.append(name)

for name in matches:
    print(name)
PY

  local rc=$?
  rm -f "${tmp}"
  return "${rc}"
}

scale_worker_machinesets() {
  if ! as_bool "${SCALE_WORKER_MACHINESETS:-true}"; then
    log "SCALE_WORKER_MACHINESETS=false; skipping."
    return 0
  fi

  local target="${WORKER_MACHINESET_TARGET_REPLICAS}"
  local preferred="${WORKER_MACHINESET_PREFERRED_INSTANCE_TYPE:-}"

  local master_region
  master_region="$(detect_master_region)"

  log "Discovering worker MachineSets in same region: ${master_region}"

  local machinesets
  machinesets="$(discover_worker_machinesets_in_region "${master_region}" || true)"

  if [[ -z "${machinesets}" ]]; then
    warn "No same-region worker MachineSets found. Falling back to all MachineSets with '-worker-' in the name."
    machinesets="$(
      oc get machineset -n "${MACHINESET_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -- '-worker-' || true
    )"
  fi

  [[ -n "${machinesets}" ]] || die "No worker-like MachineSets found in namespace ${MACHINESET_NAMESPACE}"

  log "Selected worker MachineSets:"
  while read -r ms; do
    [[ -z "${ms}" ]] && continue
    log "  - ${ms}"
  done <<< "${machinesets}"

  while read -r ms; do
    [[ -z "${ms}" ]] && continue

    if [[ -n "${preferred}" ]]; then
      local instance_type
      instance_type="$(
        oc get machineset -n "${MACHINESET_NAMESPACE}" "${ms}" \
          -o jsonpath='{.spec.template.spec.providerSpec.value.instanceType}' 2>/dev/null || true
      )"

      if [[ -n "${instance_type}" && "${instance_type}" != "${preferred}" ]]; then
        log "Patching MachineSet ${ms} instanceType ${instance_type} -> ${preferred}"
        oc patch machineset -n "${MACHINESET_NAMESPACE}" "${ms}" --type=json \
          -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/providerSpec/value/instanceType\",\"value\":\"${preferred}\"}]" || true
      fi
    fi

    log "Scaling MachineSet ${ms} to ${target}"
    oc scale machineset -n "${MACHINESET_NAMESPACE}" "${ms}" --replicas="${target}"
  done <<< "${machinesets}"

  local ms_list
  ms_list="$(echo "${machinesets}" | paste -sd ' ' -)"

  wait_until "selected worker MachineSets have desired replicas" \
    "${WORKER_MACHINESET_WAIT_TIMEOUT_SECONDS}" \
    "${WORKER_MACHINESET_WAIT_INTERVAL_SECONDS}" \
    "for ms in ${ms_list}; do ready=\$(oc get machineset -n '${MACHINESET_NAMESPACE}' \"\$ms\" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0); test \"\${ready:-0}\" -ge '${target}' || exit 1; done"
}

###############################################################################
# Operator steps
###############################################################################

install_cert_manager() {
  if ! as_bool "${CERT_MANAGER_ENABLED:-true}"; then
    log "CERT_MANAGER_ENABLED=false; skipping."
    return 0
  fi

  install_operator \
    "${CERT_MANAGER_DISPLAY_NAME_HINT}" \
    "${CERT_MANAGER_NAMESPACE}" \
    "${CERT_MANAGER_PACKAGE_CANDIDATES}" \
    "${CERT_MANAGER_CHANNEL}" \
    "${CERT_MANAGER_SOURCE}" \
    "${CERT_MANAGER_SUBSCRIPTION_NAME}" \
    "own"
}

configure_cert_manager_cluster_trust() {
  if ! as_bool "${CERT_MANAGER_CLUSTER_TRUST_ENABLED:-true}"; then
    log "CERT_MANAGER_CLUSTER_TRUST_ENABLED=false; skipping."
    return 0
  fi

  local api_host
  api_host="${CERT_MANAGER_API_HOST:-}"
  if [[ -z "${api_host}" ]]; then
    api_host="$(oc whoami --show-server | sed -E 's#https://([^:]+).*#\1#')"
  fi

  [[ -n "${api_host}" ]] || die "Could not determine API hostname for OpenShift API serving certificate."

  log "Configuring repo-style cert-manager CA/trust/API certificate for API host: ${api_host}"

  cat <<EOF_CERT_MANAGER_TRUST | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CERT_MANAGER_SELFSIGNED_ISSUER_NAME:-selfsigned-issuer}
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_MANAGER_CA_CERTIFICATE_NAME:-selfsigned-ca}
  namespace: ${CERT_MANAGER_CA_NAMESPACE:-cert-manager}
spec:
  isCA: true
  commonName: ${CERT_MANAGER_CA_COMMON_NAME:-selfsigned-ca}
  secretName: ${CERT_MANAGER_CA_SECRET_NAME:-cert-manager-ca}
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: ${CERT_MANAGER_SELFSIGNED_ISSUER_NAME:-selfsigned-issuer}
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CERT_MANAGER_CA_ISSUER_NAME:-ca-issuer}
spec:
  ca:
    secretName: ${CERT_MANAGER_CA_SECRET_NAME:-cert-manager-ca}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_MANAGER_API_CERTIFICATE_NAME:-openshift-api}
  namespace: openshift-config
spec:
  dnsNames:
    - ${api_host}
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: ${CERT_MANAGER_CA_ISSUER_NAME:-ca-issuer}
  secretName: ${CERT_MANAGER_API_SECRET_NAME:-openshift-api}
EOF_CERT_MANAGER_TRUST

  oc wait --for=condition=Ready "clusterissuer/${CERT_MANAGER_SELFSIGNED_ISSUER_NAME:-selfsigned-issuer}" --timeout="${CERT_MANAGER_CERT_WAIT_TIMEOUT:-300s}"
  oc wait --for=condition=Ready "certificate/${CERT_MANAGER_CA_CERTIFICATE_NAME:-selfsigned-ca}" -n "${CERT_MANAGER_CA_NAMESPACE:-cert-manager}" --timeout="${CERT_MANAGER_CERT_WAIT_TIMEOUT:-300s}"
  oc wait --for=condition=Ready "clusterissuer/${CERT_MANAGER_CA_ISSUER_NAME:-ca-issuer}" --timeout="${CERT_MANAGER_CERT_WAIT_TIMEOUT:-300s}"
  oc wait --for=condition=Ready "certificate/${CERT_MANAGER_API_CERTIFICATE_NAME:-openshift-api}" -n openshift-config --timeout="${CERT_MANAGER_CERT_WAIT_TIMEOUT:-300s}"

  local ca_tmp
  ca_tmp="$(mktemp)"
  oc get secret "${CERT_MANAGER_CA_SECRET_NAME:-cert-manager-ca}" -n "${CERT_MANAGER_CA_NAMESPACE:-cert-manager}" -o jsonpath='{.data.ca\.crt}' | base64 -d > "${ca_tmp}"

  oc create configmap "${CERT_MANAGER_USER_CA_BUNDLE_NAME:-user-ca-bundle}" \
    -n openshift-config \
    --from-file=ca-bundle.crt="${ca_tmp}" \
    --dry-run=client -o yaml | oc apply -f -

  rm -f "${ca_tmp}"

  oc patch proxy/cluster --type=merge -p "{\"spec\":{\"trustedCA\":{\"name\":\"${CERT_MANAGER_USER_CA_BUNDLE_NAME:-user-ca-bundle}\"}}}"

  oc patch apiserver cluster --type=merge -p "{\"spec\":{\"servingCerts\":{\"namedCertificates\":[{\"names\":[\"${api_host}\"],\"servingCertificate\":{\"name\":\"${CERT_MANAGER_API_SECRET_NAME:-openshift-api}\"}}]}}}"

  wait_until "Core OpenShift operators stable after API serving certificate patch" 1200 15 \
    "for co in kube-apiserver authentication openshift-apiserver console; do available=\$(oc get co \"\$co\" -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null); progressing=\$(oc get co \"\$co\" -o jsonpath='{.status.conditions[?(@.type==\"Progressing\")].status}' 2>/dev/null); degraded=\$(oc get co \"\$co\" -o jsonpath='{.status.conditions[?(@.type==\"Degraded\")].status}' 2>/dev/null); test \"\$available\" = True -a \"\$progressing\" = False -a \"\$degraded\" = False || exit 1; done"

  log "Configured cert-manager cluster trust and OpenShift API named certificate."
}

install_rhcl_pinned() {
  if ! as_bool "${RHCL_ENABLED:-true}"; then
    log "RHCL_ENABLED=false; skipping."
    return 0
  fi

  ensure_namespace "${RHCL_OPERATOR_NAMESPACE}"
  ensure_allnamespace_operatorgroup "${RHCL_OPERATOR_NAMESPACE}" "${RHCL_SUBSCRIPTION_NAME}-operatorgroup"

  local package
  package="$(find_package_from_candidates "${RHCL_PACKAGE_CANDIDATES}" "${RHCL_SOURCE}")" || {
    die "Could not find package for ${RHCL_DISPLAY_NAME_HINT}. Candidates=${RHCL_PACKAGE_CANDIDATES}, source=${RHCL_SOURCE}"
  }

  local channel="${RHCL_CHANNEL}"
  if [[ -z "${channel}" ]]; then
    channel="$(default_channel_for_package "${package}")"
  fi
  [[ -n "${channel}" ]] || die "Could not determine RHCL channel for package ${package}"

  local source="${RHCL_SOURCE}"
  if [[ -z "${source}" ]]; then
    source="$(catalog_source_for_package "${package}")"
  fi

  local starting_csv
  starting_csv="$(find_csv_matching_regex_in_packagemanifest "${package}" "${channel}" "${RHCL_REQUIRED_CSV_REGEX}")" || {
    die "Could not find RHCL CSV matching regex '${RHCL_REQUIRED_CSV_REGEX}' in package=${package}, channel=${channel}. Refusing to install unpinned RHCL."
  }

  log "Installing RHCL pinned through RHCL subscription only."
  log "Authorino will NOT be installed directly by this script."
  log "RHCL/OLM dependency resolution is expected to install Authorino/DNS/Limitador as needed."
  log "RHCL package=${package}, channel=${channel}, csv=${starting_csv}, source=${source}"

  install_operator \
    "${RHCL_DISPLAY_NAME_HINT}" \
    "${RHCL_OPERATOR_NAMESPACE}" \
    "${package}" \
    "${channel}" \
    "${source}" \
    "${RHCL_SUBSCRIPTION_NAME}" \
    "all" \
    "${starting_csv}" \
    "${RHCL_INSTALLPLAN_APPROVAL}"

  local installed_csv
  installed_csv="$(installed_csv_for_subscription "${RHCL_OPERATOR_NAMESPACE}" "${RHCL_SUBSCRIPTION_NAME}")"

  if ! [[ "${installed_csv}" =~ ${RHCL_REQUIRED_CSV_REGEX} ]]; then
    die "Installed RHCL CSV '${installed_csv}' does not match required regex '${RHCL_REQUIRED_CSV_REGEX}'."
  fi

  log "RHCL pinned version validated: ${installed_csv}"

  if as_bool "${RHCL_VALIDATE_DEPENDENCY_CSVS:-true}"; then
    log "Dependency CSV visibility check. This script did not install these directly."
    oc get csv -A 2>/dev/null | grep -E 'authorino-operator|dns-operator|limitador-operator|rhcl-operator' || true
  fi

  if as_bool "${CREATE_KUADRANT_INSTANCE:-true}"; then
    ensure_namespace "${KUADRANT_NAMESPACE}"

    wait_until "Kuadrant CRD exists" "${CRD_WAIT_TIMEOUT_SECONDS}" 10 \
      "oc get crd kuadrants.kuadrant.io"

    cat <<EOF_KUADRANT | oc apply -f -
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: ${KUADRANT_INSTANCE_NAME}
  namespace: ${KUADRANT_NAMESPACE}
spec: {}
EOF_KUADRANT
  fi
}

install_lws() {
  if ! as_bool "${LWS_ENABLED:-true}"; then
    log "LWS_ENABLED=false; skipping."
    return 0
  fi

  install_operator \
    "${LWS_DISPLAY_NAME_HINT}" \
    "${LWS_NAMESPACE}" \
    "${LWS_PACKAGE_CANDIDATES}" \
    "${LWS_CHANNEL}" \
    "${LWS_SOURCE}" \
    "${LWS_SUBSCRIPTION_NAME}" \
    "own"

  if as_bool "${CREATE_LWS_INSTANCE:-true}"; then
    create_managed_instance_for_kind "LeaderWorkerSetOperator" "${LWS_INSTANCE_NAME}" "${LWS_NAMESPACE}" "${CRD_WAIT_TIMEOUT_SECONDS}" || {
      warn "Could not create LeaderWorkerSetOperator instance dynamically. Check provided APIs for LWS operator."
      return 0
    }
  fi
}

install_jobset() {
  if ! as_bool "${JOBSET_ENABLED:-true}"; then
    log "JOBSET_ENABLED=false; skipping."
    return 0
  fi

  install_operator \
    "${JOBSET_DISPLAY_NAME_HINT}" \
    "${JOBSET_NAMESPACE}" \
    "${JOBSET_PACKAGE_CANDIDATES}" \
    "${JOBSET_CHANNEL}" \
    "${JOBSET_SOURCE}" \
    "${JOBSET_SUBSCRIPTION_NAME}" \
    "own"

  if as_bool "${CREATE_JOBSET_INSTANCE:-true}"; then
    create_managed_instance_for_kind "JobSetOperator" "${JOBSET_INSTANCE_NAME}" "${JOBSET_NAMESPACE}" "${CRD_WAIT_TIMEOUT_SECONDS}" || {
      warn "Could not create JobSetOperator instance dynamically. Check provided APIs for JobSet operator."
      return 0
    }
  fi
}

install_pipelines() {
  if ! as_bool "${PIPELINES_ENABLED:-true}"; then
    log "PIPELINES_ENABLED=false; skipping."
    return 0
  fi

  install_operator \
    "${PIPELINES_DISPLAY_NAME_HINT}" \
    "${PIPELINES_NAMESPACE}" \
    "${PIPELINES_PACKAGE_CANDIDATES}" \
    "${PIPELINES_CHANNEL}" \
    "${PIPELINES_SOURCE}" \
    "${PIPELINES_SUBSCRIPTION_NAME}" \
    "all"
}

install_odf_noobaa() {
  if ! as_bool "${ODF_ENABLED:-true}"; then
    log "ODF_ENABLED=false; skipping."
    return 0
  fi

  install_operator \
    "${ODF_DISPLAY_NAME_HINT}" \
    "${ODF_NAMESPACE}" \
    "${ODF_PACKAGE_CANDIDATES}" \
    "${ODF_CHANNEL}" \
    "${ODF_SOURCE}" \
    "${ODF_SUBSCRIPTION_NAME}" \
    "own"

  if as_bool "${NOOBAA_ENABLED:-true}"; then
    wait_until "NooBaa CRD exists" "${CRD_WAIT_TIMEOUT_SECONDS}" 10 \
      "oc get crd noobaas.noobaa.io"

    local sc
    sc="$(detect_storageclass)" || die "Could not detect StorageClass for NooBaa"
    log "Using StorageClass for NooBaa: ${sc}"

    cat <<EOF_NOOBAA | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: NooBaa
metadata:
  name: ${NOOBAA_NAME}
  namespace: ${ODF_NAMESPACE}
spec:
  dbResources:
    requests:
      cpu: "${NOOBAA_DB_CPU_REQUEST}"
      memory: "${NOOBAA_DB_MEMORY_REQUEST}"
  coreResources:
    requests:
      cpu: "${NOOBAA_CORE_CPU_REQUEST}"
      memory: "${NOOBAA_CORE_MEMORY_REQUEST}"
  pvPool:
    numVolumes: 1
    resources:
      requests:
        storage: ${NOOBAA_PV_SIZE}
    storageClass: ${sc}
EOF_NOOBAA

    wait_until "NooBaa Ready" "${CR_WAIT_TIMEOUT_SECONDS}" 30 \
      "test \"\$(oc get noobaa -n '${ODF_NAMESPACE}' '${NOOBAA_NAME}' -o jsonpath='{.status.phase}' 2>/dev/null)\" = Ready"

    log "Ensuring NooBaa ObjectBucketClaim StorageClass exists"

    cat <<EOF_NOOBAA_SC | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openshift-storage.noobaa.io
provisioner: openshift-storage.noobaa.io/obc
parameters:
  bucketclass: noobaa-default-bucket-class
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF_NOOBAA_SC

    wait_until "StorageCluster CRD exists" "${CRD_WAIT_TIMEOUT_SECONDS}" 10 \
      "oc get crd storageclusters.ocs.openshift.io"

    log "Ensuring ODF StorageCluster wrapper exists for standalone MCG"

    cat <<EOF_STORAGECLUSTER | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ${ODF_STORAGECLUSTER_NAME:-ocs-storagecluster}
  namespace: ${ODF_NAMESPACE}
spec:
  resourceProfile: ${ODF_STORAGECLUSTER_RESOURCE_PROFILE:-lean}
  multiCloudGateway:
    reconcileStrategy: standalone
    dbStorageClassName: ${sc}
EOF_STORAGECLUSTER

    log "Forcing StorageCluster reconcile after NooBaa is Ready"

    oc annotate storagecluster "${ODF_STORAGECLUSTER_NAME:-ocs-storagecluster}" \
      -n "${ODF_NAMESPACE}" \
      force-reconcile="$(date +%s)" \
      --overwrite

    log "Validating standalone MCG readiness through NooBaa, BackingStore, and OBC StorageClass."

    wait_until "NooBaa Ready" "${CR_WAIT_TIMEOUT_SECONDS}" 30 \
      "test \"\$(oc get noobaa -n '${ODF_NAMESPACE}' noobaa -o jsonpath='{.status.phase}' 2>/dev/null)\" = Ready"

    wait_until "NooBaa default BackingStore Ready" "${CR_WAIT_TIMEOUT_SECONDS}" 30 \
      "test \"\$(oc get backingstore -n '${ODF_NAMESPACE}' noobaa-default-backing-store -o jsonpath='{.status.phase}' 2>/dev/null)\" = Ready"

    wait_until "NooBaa OBC StorageClass exists" "${CR_WAIT_TIMEOUT_SECONDS}" 15 \
      "oc get storageclass openshift-storage.noobaa.io >/dev/null 2>&1"

    if as_bool "${NOOBAA_CREATE_TEST_OBC:-false}"; then
      log "Creating test ObjectBucketClaim ${NOOBAA_TEST_OBC_NAME:-first-bucket}"

      cat <<EOF_TEST_OBC | oc apply -f -
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${NOOBAA_TEST_OBC_NAME:-first-bucket}
  namespace: ${ODF_NAMESPACE}
spec:
  generateBucketName: ${NOOBAA_TEST_OBC_NAME:-first-bucket}
  storageClassName: openshift-storage.noobaa.io
EOF_TEST_OBC

      wait_until "ObjectBucketClaim ${NOOBAA_TEST_OBC_NAME:-first-bucket} Bound" "${CR_WAIT_TIMEOUT_SECONDS}" 15 \
        "test \"\$(oc get objectbucketclaim -n '${ODF_NAMESPACE}' '${NOOBAA_TEST_OBC_NAME:-first-bucket}' -o jsonpath='{.status.phase}' 2>/dev/null)\" = Bound"
    fi
  fi

  if as_bool "${ODF_ENABLE_CONSOLE_PLUGIN:-true}"; then
    local tmp
    tmp="$(mktemp)"

    oc get console.operator.openshift.io cluster -o json > "${tmp}" || {
      warn "Could not read console.operator.openshift.io cluster; skipping ODF console plugin patch."
      rm -f "${tmp}"
      return 0
    }

    PLUGIN_NAME="${ODF_CONSOLE_PLUGIN_NAME}" python3 - "${tmp}" <<'PY_CONSOLE_PLUGIN' > /tmp/console-plugin-patch.json
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
name = os.environ["PLUGIN_NAME"]
obj = json.loads(path.read_text())
plugins = obj.get("spec", {}).get("plugins", []) or []

if name not in plugins:
    plugins.append(name)

print(json.dumps({"spec": {"plugins": plugins}}))
PY_CONSOLE_PLUGIN

    rm -f "${tmp}"
    oc patch console.operator.openshift.io cluster --type=merge --patch-file /tmp/console-plugin-patch.json || true
    rm -f /tmp/console-plugin-patch.json
  fi
}



enable_odf_console_plugin() {
  if ! as_bool "${ODF_ENABLE_CONSOLE_PLUGIN:-true}"; then
    log "ODF_ENABLE_CONSOLE_PLUGIN=false; skipping."
    return 0
  fi

  local plugin
  plugin="${ODF_CONSOLE_PLUGIN_NAME:-odf-console}"

  wait_until "ConsolePlugin ${plugin} exists" "${CR_WAIT_TIMEOUT_SECONDS:-2400}" 15 \
    "oc get consoleplugin '${plugin}' >/dev/null 2>&1"

  log "Enabling OpenShift Console plugin: ${plugin}"

  local plugins_json
  plugins_json="$(
    oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null | PLUGIN="${plugin}" python3 -c '
import json
import os
import sys

plugin = os.environ["PLUGIN"]
raw = sys.stdin.read().strip()
plugins = json.loads(raw) if raw else []
if plugin not in plugins:
    plugins.append(plugin)
print(json.dumps(plugins))
'
  )"

  oc patch console.operator.openshift.io cluster --type=merge -p "{\"spec\":{\"plugins\":${plugins_json}}}"

  wait_until "OpenShift Console plugin ${plugin} configured" 600 15 \
    "oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' | grep -q '\"'${plugin}'\"'"

  log "Enabled OpenShift Console plugin: ${plugin}"
}

install_cnpg() {
  if ! as_bool "${CNPG_ENABLED:-true}"; then
    log "CNPG_ENABLED=false; skipping."
    return 0
  fi

  if [[ "${CNPG_PACKAGE_CANDIDATES}" == *"cloud-native-postgresql"* ]]; then
    die "Refusing to install cloud-native-postgresql because that resolves to EDB Postgres for Kubernetes on this cluster. Use cloudnative-pg."
  fi

  log "Installing CloudNativePG through OLM using package=${CNPG_PACKAGE_CANDIDATES}, channel=${CNPG_CHANNEL}, source=${CNPG_SOURCE}"
  log "This follows the referenced openshift-setup cloudnative-pg chart values: cloudnative-pg / stable-v1 / certified-operators."

  install_operator \
    "${CNPG_DISPLAY_NAME_HINT}" \
    "${CNPG_NAMESPACE}" \
    "${CNPG_PACKAGE_CANDIDATES}" \
    "${CNPG_CHANNEL}" \
    "${CNPG_SOURCE}" \
    "${CNPG_SUBSCRIPTION_NAME}" \
    "all"

  wait_until "CloudNativePG Cluster CRD exists" "${CRD_WAIT_TIMEOUT_SECONDS}" 10 \
    "oc get crd clusters.postgresql.cnpg.io"

  log "CloudNativePG operator installed through OLM and CNPG Cluster CRD is available."
}


install_nfd() {
  if ! as_bool "${NFD_ENABLED:-true}"; then
    log "NFD_ENABLED=false; skipping."
    return 0
  fi

  install_operator \
    "${NFD_DISPLAY_NAME_HINT}" \
    "${NFD_NAMESPACE}" \
    "${NFD_PACKAGE_CANDIDATES}" \
    "${NFD_CHANNEL}" \
    "${NFD_SOURCE}" \
    "${NFD_SUBSCRIPTION_NAME}" \
    "own"

  if as_bool "${CREATE_NFD_INSTANCE:-true}"; then
    wait_until "NodeFeatureDiscovery CRD exists" "${CRD_WAIT_TIMEOUT_SECONDS}" 10 \
      "oc get crd nodefeaturediscoveries.nfd.openshift.io"

    cat <<EOF_NFD | oc apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: ${NFD_INSTANCE_NAME}
  namespace: ${NFD_NAMESPACE}
spec:
  operand:
    imagePullPolicy: IfNotPresent
  workerConfig:
    configData: |
      core:
        sleepInterval: 60s
      sources:
        pci:
          deviceClassWhitelist:
            - "02"
            - "03"
            - "0200"
            - "0207"
            - "0300"
            - "0302"
          deviceLabelFields:
            - vendor
EOF_NFD
  fi
}

install_nvidia() {
  if ! as_bool "${NVIDIA_ENABLED:-true}"; then
    log "NVIDIA_ENABLED=false; skipping."
    return 0
  fi

  install_operator \
    "${NVIDIA_DISPLAY_NAME_HINT}" \
    "${NVIDIA_NAMESPACE}" \
    "${NVIDIA_PACKAGE_CANDIDATES}" \
    "${NVIDIA_CHANNEL}" \
    "${NVIDIA_SOURCE}" \
    "${NVIDIA_SUBSCRIPTION_NAME}" \
    "own"

  if as_bool "${CREATE_NVIDIA_CLUSTER_POLICY:-true}"; then
    wait_until "NVIDIA ClusterPolicy CRD exists" "${CRD_WAIT_TIMEOUT_SECONDS}" 10 \
      "oc get crd clusterpolicies.nvidia.com"

    cat <<EOF_NVIDIA | oc apply -f -
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: ${NVIDIA_CLUSTER_POLICY_NAME}
spec:
  operator:
    defaultRuntime: crio
    use_ocp_driver_toolkit: true
  daemonsets: {}
  driver:
    enabled: true
  toolkit:
    enabled: true
  devicePlugin:
    enabled: true
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
  gfd:
    enabled: true
  migManager:
    enabled: true
  nodeStatusExporter:
    enabled: true
  validator:
    plugin:
      env:
      - name: WITH_WORKLOAD
        value: "true"
EOF_NVIDIA
  fi
}

select_gpu_source_machineset() {
  if [[ -n "${GPU_MACHINESET_SOURCE_NAME:-}" ]]; then
    echo "${GPU_MACHINESET_SOURCE_NAME}"
    return 0
  fi

  local master_region
  master_region="$(detect_master_region)"

  local tmp
  tmp="$(mktemp)"
  oc get machineset -n "${MACHINESET_NAMESPACE}" -o json > "${tmp}"

  MASTER_REGION="${master_region}" PREFERRED="${WORKER_MACHINESET_PREFERRED_INSTANCE_TYPE:-}" python3 - "${tmp}" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
items = data.get("items", []) or []
preferred = os.environ.get("PREFERRED", "")
region = os.environ.get("MASTER_REGION", "")

candidates = []

for item in items:
    name = item.get("metadata", {}).get("name", "")
    labels = item.get("metadata", {}).get("labels", {}) or {}
    tmpl = item.get("spec", {}).get("template", {}) or {}
    tmpl_labels = tmpl.get("metadata", {}).get("labels", {}) or {}
    provider = tmpl.get("spec", {}).get("providerSpec", {}).get("value", {}) or {}
    az = (provider.get("placement", {}) or {}).get("availabilityZone", "") or ""
    role = labels.get("machine.openshift.io/cluster-api-machine-role") or tmpl_labels.get("machine.openshift.io/cluster-api-machine-role") or ""

    looks_worker = role == "worker" or "-worker-" in name or name.endswith("-worker")
    in_region = az.startswith(region) if az and region else True

    if looks_worker and in_region:
        candidates.append(item)

if preferred:
    for item in candidates:
        provider = item.get("spec", {}).get("template", {}).get("spec", {}).get("providerSpec", {}).get("value", {})
        if provider.get("instanceType") == preferred:
            print(item["metadata"]["name"])
            sys.exit(0)

if candidates:
    print(candidates[0]["metadata"]["name"])
    sys.exit(0)

sys.exit(1)
PY

  local rc=$?
  rm -f "${tmp}"
  return "${rc}"
}

create_gpu_machineset() {
  if ! as_bool "${GPU_MACHINESET_ENABLED:-false}"; then
    log "GPU_MACHINESET_ENABLED=false; skipping."
    return 0
  fi

  local source_ms
  source_ms="$(select_gpu_source_machineset)" || die "Could not select source MachineSet for GPU clone."

  local gpu_ms="${GPU_MACHINESET_NAME:-}"
  if [[ -z "${gpu_ms}" ]]; then
    gpu_ms="${source_ms}-gpu"
  fi

  log "Creating/updating GPU MachineSet ${gpu_ms} from source ${source_ms}"

  local tmp
  tmp="$(mktemp)"
  oc get machineset -n "${MACHINESET_NAMESPACE}" "${source_ms}" -o json > "${tmp}"

  GPU_MS="${gpu_ms}" \
  GPU_REPLICAS="${GPU_MACHINESET_REPLICAS}" \
  GPU_INSTANCE_TYPE="${GPU_MACHINESET_INSTANCE_TYPE}" \
  GPU_ROOT_VOLUME_SIZE_GB="${GPU_MACHINESET_ROOT_VOLUME_SIZE_GB}" \
  GPU_NODE_ISOLATION_ENABLED="${GPU_NODE_ISOLATION_ENABLED}" \
  GPU_NODE_SELECTOR_LABEL_KEY="${GPU_NODE_SELECTOR_LABEL_KEY}" \
  GPU_NODE_SELECTOR_LABEL_VALUE="${GPU_NODE_SELECTOR_LABEL_VALUE}" \
  GPU_NODE_ROLE_LABEL_KEY="${GPU_NODE_ROLE_LABEL_KEY}" \
  GPU_NODE_ROLE_LABEL_VALUE="${GPU_NODE_ROLE_LABEL_VALUE}" \
  GPU_NODE_TAINT_KEY="${GPU_NODE_TAINT_KEY}" \
  GPU_NODE_TAINT_VALUE="${GPU_NODE_TAINT_VALUE}" \
  GPU_NODE_TAINT_EFFECT="${GPU_NODE_TAINT_EFFECT}" \
  python3 - "${tmp}" <<'PY' | oc apply -f -
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
obj = json.loads(path.read_text())

name = os.environ["GPU_MS"]

for k in ["uid", "resourceVersion", "generation", "creationTimestamp", "managedFields"]:
    obj.get("metadata", {}).pop(k, None)

obj["metadata"]["name"] = name
obj["metadata"]["namespace"] = "openshift-machine-api"

labels = obj["metadata"].setdefault("labels", {})
labels["machine.openshift.io/cluster-api-machineset"] = name

obj["spec"]["replicas"] = int(os.environ["GPU_REPLICAS"])

selector = obj["spec"].setdefault("selector", {}).setdefault("matchLabels", {})
selector["machine.openshift.io/cluster-api-machineset"] = name

tmpl_meta = obj["spec"].setdefault("template", {}).setdefault("metadata", {})
tmpl_labels = tmpl_meta.setdefault("labels", {})
tmpl_labels["machine.openshift.io/cluster-api-machineset"] = name

if os.environ.get("GPU_NODE_ISOLATION_ENABLED", "false").lower() == "true":
    tmpl_labels[os.environ["GPU_NODE_SELECTOR_LABEL_KEY"]] = os.environ["GPU_NODE_SELECTOR_LABEL_VALUE"]

    role_key = os.environ.get("GPU_NODE_ROLE_LABEL_KEY", "")
    if role_key:
        tmpl_labels[role_key] = os.environ.get("GPU_NODE_ROLE_LABEL_VALUE", "")

    obj["spec"].setdefault("template", {}).setdefault("spec", {})["taints"] = [{
        "key": os.environ["GPU_NODE_TAINT_KEY"],
        "value": os.environ["GPU_NODE_TAINT_VALUE"],
        "effect": os.environ["GPU_NODE_TAINT_EFFECT"],
    }]

provider = obj["spec"]["template"]["spec"]["providerSpec"]["value"]
provider["instanceType"] = os.environ["GPU_INSTANCE_TYPE"]

if provider.get("blockDevices"):
    provider["blockDevices"][0].setdefault("ebs", {})["volumeSize"] = int(os.environ["GPU_ROOT_VOLUME_SIZE_GB"])

print(json.dumps(obj, indent=2))
PY

  rm -f "${tmp}"

  wait_until "GPU MachineSet ${gpu_ms} has Ready replica" \
    "${GPU_MACHINESET_WAIT_TIMEOUT_SECONDS}" \
    "${GPU_MACHINESET_WAIT_INTERVAL_SECONDS}" \
    "test \"\$(oc get machineset -n '${MACHINESET_NAMESPACE}' '${gpu_ms}' -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)\" = '${GPU_MACHINESET_REPLICAS}'"

  wait_until "GPU node advertises nvidia.com/gpu" \
    "${GPU_DRIVER_WAIT_TIMEOUT_SECONDS}" \
    "${GPU_DRIVER_WAIT_INTERVAL_SECONDS}" \
    "oc get nodes -o json | python3 -c '
import json,sys
data=json.load(sys.stdin)
for node in data.get(\"items\", []):
    alloc = node.get(\"status\", {}).get(\"allocatable\", {})
    if alloc.get(\"nvidia.com/gpu\") not in (None, \"0\"):
        sys.exit(0)
sys.exit(1)
'"
}

install_servicemesh3() {
  if ! as_bool "${SERVICEMESH3_ENABLED:-true}"; then
    log "SERVICEMESH3_ENABLED=false; skipping."
    return 0
  fi

  install_operator \
    "${SERVICEMESH3_DISPLAY_NAME_HINT}" \
    "${SERVICEMESH3_NAMESPACE}" \
    "${SERVICEMESH3_PACKAGE_CANDIDATES}" \
    "${SERVICEMESH3_CHANNEL}" \
    "${SERVICEMESH3_SOURCE}" \
    "${SERVICEMESH3_SUBSCRIPTION_NAME}" \
    "all"
}

install_rhoai_operator_only() {
  if ! as_bool "${RHOAI_ENABLED:-true}"; then
    log "RHOAI_ENABLED=false; skipping."
    return 0
  fi

  if as_bool "${RHOAI_CREATE_DSCI:-false}" || as_bool "${RHOAI_CREATE_DSC:-false}"; then
    die "Baseline guardrail violation: RHOAI_CREATE_DSCI and RHOAI_CREATE_DSC must both be false."
  fi

  if as_bool "${MAAS_ENABLED:-false}" \
    || as_bool "${MAAS_CREATE_CRUNCHY_DATABASE:-false}" \
    || as_bool "${MAAS_CREATE_GATEWAY:-false}" \
    || as_bool "${MAAS_CREATE_HTTPROUTE:-false}" \
    || as_bool "${MAAS_CREATE_AUTHPOLICY:-false}" \
    || as_bool "${MAAS_CREATE_DASHBOARD_ROUTE_REPAIR:-false}"; then
    die "Baseline guardrail violation: MaaS flags must be false. MaaS belongs in setup-maas.sh."
  fi

  ensure_namespace "${RHOAI_NAMESPACE}"
  ensure_namespace "${RHOAI_APPLICATIONS_NAMESPACE}"
  ensure_allnamespace_operatorgroup "${RHOAI_NAMESPACE}" "${RHOAI_SUBSCRIPTION_NAME}-operatorgroup"

  install_operator \
    "${RHOAI_DISPLAY_NAME_HINT}" \
    "${RHOAI_NAMESPACE}" \
    "${RHOAI_PACKAGE_CANDIDATES}" \
    "${RHOAI_CHANNEL}" \
    "${RHOAI_SOURCE}" \
    "${RHOAI_SUBSCRIPTION_NAME}" \
    "all" \
    "${RHOAI_STARTING_CSV:-}"

  local csv
  csv="$(installed_csv_for_subscription "${RHOAI_NAMESPACE}" "${RHOAI_SUBSCRIPTION_NAME}")"
  log "RHOAI installed CSV: ${csv}"

  if [[ -n "${RHOAI_REQUIRED_CSV_REGEX:-}" ]]; then
    if ! [[ "${csv}" =~ ${RHOAI_REQUIRED_CSV_REGEX} ]]; then
      die "RHOAI CSV '${csv}' does not match required regex '${RHOAI_REQUIRED_CSV_REGEX}'"
    fi
  fi

  log "RHOAI 3.4 operator baseline installed. No DSCI, DSC, or MaaS resources were created."
}

###############################################################################
# Verification
###############################################################################

verify_baseline() {
  log "Verification summary"

  echo
  echo "=== Current user ==="
  oc whoami || true

  echo
  echo "=== Cluster version ==="
  oc get clusterversion || true

  echo
  echo "=== Worker MachineSets ==="
  oc get machineset -n "${MACHINESET_NAMESPACE}" || true

  echo
  echo "=== GPU nodes/resources ==="
  oc get nodes -L "${GPU_NODE_SELECTOR_LABEL_KEY:-nvidia.com/gpu.present}" || true
  oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu || true

  echo
  echo "=== Key operator subscriptions ==="
  for ns in \
    "${CERT_MANAGER_NAMESPACE}" \
    "${RHCL_OPERATOR_NAMESPACE}" \
    "${LWS_NAMESPACE}" \
    "${JOBSET_NAMESPACE}" \
    "${ODF_NAMESPACE}" \
    "${CNPG_NAMESPACE}" \
    "${NFD_NAMESPACE}" \
    "${NVIDIA_NAMESPACE}" \
    "${RHOAI_NAMESPACE}"
  do
    echo
    echo "--- ${ns} ---"
    oc get operatorgroup,subscription,csv -n "${ns}" 2>/dev/null || true
  done

  echo
  echo "=== RHCL / dependency CSV visibility ==="
  oc get csv -A 2>/dev/null | grep -E 'rhcl-operator|authorino-operator|dns-operator|limitador-operator' || true


  echo
  echo "=== CloudNativePG CRDs ==="
  oc get crd | grep -E 'postgresql.cnpg.io|cloudnativepg' || true

  echo
  echo "=== JobSet CRDs / instance ==="
  oc get crd | grep -i jobset || true
  oc get jobsetoperator -A 2>/dev/null || true

  echo
  echo "=== LWS CRDs / instance ==="
  oc get crd | grep -i leader || true
  oc get leaderworkersetoperator -A 2>/dev/null || true

  echo
  echo "=== RHOAI baseline CR check; these should be empty ==="
  oc get dscinitialization 2>/dev/null || true
  oc get datasciencecluster 2>/dev/null || true

  echo
  echo "=== MaaS resource check; these should be empty ==="
  oc get tenants.maas.opendatahub.io -A 2>/dev/null || true
  oc get maasmodelrefs.maas.opendatahub.io -A 2>/dev/null || true
  oc get maassubscriptions.maas.opendatahub.io -A 2>/dev/null || true
  oc get externalmodels.maas.opendatahub.io -A 2>/dev/null || true

  echo
  echo "Tracker file: ${TRACKER_FILE}"
}

###############################################################################
# Main
###############################################################################

main() {
  init_tracker

  run_step "cluster_logged_in" login_to_cluster
  run_step "htpasswd_admin_configured" configure_htpasswd_admin
  run_step "worker_machinesets_scaled" scale_worker_machinesets

  run_step "cert_manager_operator_installed" install_cert_manager
  run_step "cert_manager_cluster_trust_configured" configure_cert_manager_cluster_trust
  run_step "rhcl_133_operator_installed" install_rhcl_pinned
  run_step "lws_operator_installed" install_lws
  run_step "jobset_operator_installed" install_jobset
  run_step "pipelines_operator_installed" install_pipelines
  run_step "odf_noobaa_installed" install_odf_noobaa
  run_step "odf_console_plugin_enabled" enable_odf_console_plugin
  run_step "cnpg_operator_installed" install_cnpg
  run_step "nfd_installed" install_nfd
  run_step "nvidia_gpu_operator_installed" install_nvidia
  run_step "gpu_machineset_created" create_gpu_machineset
  run_step "servicemesh3_operator_installed" install_servicemesh3
  run_step "rhoai_34_operator_baseline_installed" install_rhoai_operator_only

  verify_baseline
}

main "$@"
