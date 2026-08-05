#!/usr/bin/env bash
#
# clone-namespace.sh
#
# Clone an OpenShift project (namespace) into a new one.
#
# Usage:
#   ./clone-namespace.sh -s <source-namespace> -n <new-namespace> [-r <old:new,...>] [-v <pvc1,...>] [-x] [-p] [-h]
#
# Flags:
#   -s <namespace>       Source namespace to clone from (required)
#   -n <namespace>       New namespace to create/clone into (required)
#   -r <old:new,...>     Rename PVC claimName references in Deployments (e.g. -r "dokumen-vol:dokumen-vol-reg")
#   -v <pvc1,pvc2,...>   Filter to process/clone only specific PVC names
#   -p                   Also attempt to clone PVC *data* via CSI VolumeSnapshot
#                        (default: PVCs are recreated empty, same size/class)
#   -x                   Skip PVC creation entirely (useful if you pre-create PVCs manually)
#   -h                   Show this help and exit
#
# Examples:
#   ./clone-namespace.sh -s jac -n jac-clone
#   ./clone-namespace.sh -s jac -n jac-clone -r "dokumen-vol:dokumen-vol-reg"
#   ./clone-namespace.sh -s jac -n jac-clone -x -r "dokumen-vol:my-custom-pvc"
#
# What it does:
#   - Creates the new project (if it doesn't already exist)
#   - Exports deployment, service, configmap, secret, rolebinding, role,
#     serviceaccount, route, pvc, networkpolicy, resourcequota, limitrange, hpa
#   - Strips cluster-generated fields (uid, resourceVersion, creationTimestamp, etc.)
#   - Skips auto-generated service-account-token secrets (OCP regenerates these)
#   - Strips PVC volumeName/status so a NEW volume gets provisioned
#     (prevents "two claims bound to the same volume" errors)
#   - Rewrites `namespace: <old>` -> `namespace: <new>` in every manifest
#   - Rewrites route hosts from <old>.apps... -> <new>.apps... so they don't clash
#   - Rewrites PVC claimName references if -r is specified
#   - Applies PVCs first, then everything else
#
# What it does NOT do:
#   - Copy actual PVC *data* by default (you get empty volumes of the same
#     size/class). Pass -p to attempt CSI VolumeSnapshot-based cloning
#     instead (requires a CSI driver + VolumeSnapshotClass that supports
#     snapshots in your cluster).
#   - Handle Operator-managed resources (Subscription/CSV/OperatorGroup) or
#     ImageStreams referencing the old namespace - review those manually.
#
# Requirements: oc CLI logged in with permission to read <source> and
# create/apply into <new>. yq (https://github.com/mikefarah/yq) is used if
# present for safer YAML editing; falls back to sed otherwise.

set -euo pipefail

usage() {
  sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'
}

SRC_NS=""
NEW_NS=""
WITH_PVC_DATA=false
SKIP_PVC=false
PVC_FILTER=""
PVC_RENAME_MAP=""

while getopts ":s:n:v:r:pxh" opt; do
  case "$opt" in
    s) SRC_NS="$OPTARG" ;;
    n) NEW_NS="$OPTARG" ;;
    v) PVC_FILTER="$OPTARG" ;;
    r) PVC_RENAME_MAP="$OPTARG" ;;
    p) WITH_PVC_DATA=true ;;
    x) SKIP_PVC=true ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$SRC_NS" || -z "$NEW_NS" ]]; then
  echo "Error: both -s <source-namespace> and -n <new-namespace> are required." >&2
  echo >&2
  usage
  exit 1
fi

if [[ "$SRC_NS" == "$NEW_NS" ]]; then
  echo "Source and new namespace must differ."
  exit 1
fi

WORKDIR="$(mktemp -d "clone-${SRC_NS}-to-${NEW_NS}.XXXXXX")"
echo "Working directory: $WORKDIR"

HAS_YQ=false
if command -v yq >/dev/null 2>&1; then
  HAS_YQ=true
  echo "yq found - using it for YAML cleanup."
fi

HAS_PY=false
if ! $HAS_YQ && command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  HAS_PY=true
  echo "python3+PyYAML found - using it for YAML cleanup."
fi

if ! $HAS_YQ && ! $HAS_PY; then
  echo "Neither yq nor python3+PyYAML found - falling back to awk/sed (works, but less robust)."
fi

# Objects that are auto-injected into every OCP project and should never be
# exported/reapplied.
EXCLUDED_NAMES="kube-root-ca.crt openshift-service-ca.crt"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

has_objects() {
  local file="$1"
  [[ ! -s "$file" ]] && return 1

  if $HAS_YQ; then
    local count
    count=$(yq eval '
      if .kind == "List" then
        (.items // []) | length
      elif .items then
        (.items // []) | length
      else
        1
      end
    ' "$file" 2>/dev/null || echo 0)
    [[ "$count" -gt 0 ]] && return 0 || return 1
  elif $HAS_PY; then
    python3 - "$file" <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        docs = list(yaml.safe_load_all(f))
    total = 0
    for doc in docs:
        if not doc:
            continue
        if isinstance(doc, dict):
            if doc.get("kind") == "List" or "items" in doc:
                items = doc.get("items") or []
                total += len(items)
            else:
                total += 1
        elif isinstance(doc, list):
            total += len(doc)
    sys.exit(0 if total > 0 else 1)
except Exception:
    sys.exit(1)
PYEOF
  else
    if awk '/^items:/ { in_items=1; next } in_items && /^[[:space:]]*- / { found=1; exit } END { exit (found ? 0 : 1) }' "$file"; then
      return 0
    fi
    if grep -E '^kind:' "$file" | grep -qv 'kind:[[:space:]]*List'; then
      return 0
    fi
    return 1
  fi
}


strip_common_fields_yq() {
  # $1 = input file, $2 = output file
  local excl_jq_array
  excl_jq_array=$(printf '"%s",' $EXCLUDED_NAMES)
  excl_jq_array="[${excl_jq_array%,}]"

  yq eval "
    (${excl_jq_array}) as \$excluded |
    del(.items[] | select(
      (.metadata.ownerReferences // []) | length > 0
    )) |
    del(.items[] | select(.metadata.name as \$n | \$excluded | contains([\$n]))) |
    del(.items[] | select(.kind == \"Service\" and .spec.clusterIP != \"None\") | .spec.clusterIP) |
    del(.items[] | select(.kind == \"Service\" and .spec.clusterIP != \"None\") | .spec.clusterIPs) |
    del(.items[] | select(.kind == \"Service\") | .spec.healthCheckNodePort) |
    del(.items[] | select(.kind == \"ServiceAccount\").secrets[] | select(.name | (contains(\"-token-\") or contains(\"-dockercfg-\")))) |
    del(.items[] | select(.kind == \"ServiceAccount\").imagePullSecrets[] | select(.name | contains(\"-dockercfg-\"))) |
    del(.items[].metadata.uid) |
    del(.items[].metadata.resourceVersion) |
    del(.items[].metadata.creationTimestamp) |
    del(.items[].metadata.generation) |
    del(.items[].metadata.selfLink) |
    del(.items[].metadata.managedFields) |
    del(.items[].status)
  " "$1" > "$2.tmp"
  sed -e "s/namespace: ${SRC_NS}$/namespace: ${NEW_NS}/" \
      -e "s#${SRC_NS}\.apps#${NEW_NS}.apps#g" \
      "$2.tmp" > "$2"
  rm -f "$2.tmp"
}

strip_common_fields_py() {
  # $1 = input file, $2 = output file
  SRC_NS="$SRC_NS" NEW_NS="$NEW_NS" EXCLUDED_NAMES="$EXCLUDED_NAMES" \
    python3 - "$1" "$2.tmp" <<'PYEOF'
import os, sys, yaml

inp, outp = sys.argv[1], sys.argv[2]
src_ns = os.environ["SRC_NS"]
excluded = set(os.environ["EXCLUDED_NAMES"].split())

with open(inp) as f:
    doc = yaml.safe_load(f) or {}

items = doc.get("items", []) or []
kept = []
for item in items:
    meta = item.get("metadata", {}) or {}
    name = meta.get("name", "")
    kind = item.get("kind", "?")
    if meta.get("ownerReferences"):
        print(f"   Skipping {kind}/{name}: owned by a controller/operator", file=sys.stderr)
        continue
    if name in excluded:
        print(f"   Skipping {kind}/{name}: auto-generated by OpenShift", file=sys.stderr)
        continue
    for field in ("uid", "resourceVersion", "creationTimestamp", "generation",
                  "selfLink", "managedFields"):
        meta.pop(field, None)
    item["metadata"] = meta
    item.pop("status", None)

    if kind == "Service":
        spec = item.get("spec", {}) or {}
        if spec.get("clusterIP") != "None":
            spec.pop("clusterIP", None)
            spec.pop("clusterIPs", None)
        spec.pop("healthCheckNodePort", None)
        item["spec"] = spec

    if kind == "ServiceAccount":
        secrets = item.get("secrets", []) or []
        item["secrets"] = [s for s in secrets if not ("-token-" in s.get("name", "") or "-dockercfg-" in s.get("name", ""))]
        if not item["secrets"]:
            item.pop("secrets", None)

        image_pull = item.get("imagePullSecrets", []) or []
        item["imagePullSecrets"] = [s for s in image_pull if not ("-dockercfg-" in s.get("name", ""))]
        if not item["imagePullSecrets"]:
            item.pop("imagePullSecrets", None)

    kept.append(item)

doc["items"] = kept
with open(outp, "w") as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
  sed -e "s/namespace: ${SRC_NS}$/namespace: ${NEW_NS}/" \
      -e "s#${SRC_NS}\.apps#${NEW_NS}.apps#g" \
      "$2.tmp" > "$2"
  rm -f "$2.tmp"
}

strip_common_fields_awk() {
  # $1 = input file, $2 = output file
  # Filters whole items (not just fields) so a partially-stripped
  # ownerReferences block can never slip through - buffer each item
  # (delimited by top-level `- ` markers under items:) and drop it
  # entirely if it has ownerReferences or a name in EXCLUDED_NAMES.
  local excl_pattern
  excl_pattern=$(echo "$EXCLUDED_NAMES" | sed 's/\./\\./g' | sed 's/ /|/g')

  awk -v excl="$excl_pattern" '
    function flush() {
      if (buf != "" && !skip) printf "%s", buf
      buf=""; skip=0
    }
    /^items:/ { print; in_items=1; next }
    in_items && /^[a-zA-Z]/ { flush(); in_items=0; print; next }
    in_items && /^- / {
      flush()
      buf = $0 "\n"
      next
    }
    in_items {
      buf = buf $0 "\n"
      if ($0 ~ /ownerReferences:/) skip=1
      if (excl != "" && $0 ~ ("name: (" excl ")$")) skip=1
      next
    }
    { print }
    END { if (in_items) flush() }
  ' "$1" \
  | sed -e '/resourceVersion:/d' \
        -e '/[[:space:]]uid:/d' \
        -e '/selfLink:/d' \
        -e '/creationTimestamp:/d' \
        -e '/generation:/d' \
        -e '/[[:space:]]*clusterIPs:/d' \
        -e '/[[:space:]]*clusterIP:[[:space:]]*[0-9]/d' \
        -e '/[[:space:]]*- [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/d' \
        -e '/[[:space:]]*healthCheckNodePort:/d' \
        -e '/[[:space:]]*- name:.*-token-/d' \
        -e '/[[:space:]]*- name:.*-dockercfg-/d' \
        -e "s/namespace: ${SRC_NS}$/namespace: ${NEW_NS}/" \
        -e "s#${SRC_NS}\.apps#${NEW_NS}.apps#g" \
  > "$2"
}

clean_yaml() {
  # $1 = input file, $2 = output file
  if $HAS_YQ; then
    strip_common_fields_yq "$1" "$2"
  elif $HAS_PY; then
    strip_common_fields_py "$1" "$2"
  else
    strip_common_fields_awk "$1" "$2"
  fi
}

strip_pvc_binding() {
  # $1 = input file, $2 = output file - removes volumeName/status/bind
  # annotations so PVCs get a fresh PV via normal dynamic provisioning
  # instead of trying to rebind to the source's already-bound PV.
  if $HAS_YQ; then
    yq eval '
      del(.items[].spec.volumeName) |
      del(.items[].status) |
      del(.items[].metadata.annotations."pv.kubernetes.io/bind-completed") |
      del(.items[].metadata.annotations."pv.kubernetes.io/bound-by-controller")
    ' "$1" > "$2"
  elif $HAS_PY; then
    python3 - "$1" "$2" <<'PYEOF'
import sys, yaml
inp, outp = sys.argv[1], sys.argv[2]
with open(inp) as f:
    doc = yaml.safe_load(f) or {}
for item in doc.get("items", []) or []:
    item.get("spec", {}).pop("volumeName", None)
    item.pop("status", None)
    ann = item.get("metadata", {}).get("annotations", {}) or {}
    ann.pop("pv.kubernetes.io/bind-completed", None)
    ann.pop("pv.kubernetes.io/bound-by-controller", None)
    if "metadata" in item:
        item["metadata"]["annotations"] = ann
with open(outp, "w") as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
  else
    sed -e '/volumeName:/d' \
        -e '/pv.kubernetes.io\/bind-completed/d' \
        -e '/pv.kubernetes.io\/bound-by-controller/d' \
        "$1" > "$2"
    echo "   (awk/sed fallback: 'status:' block not removed - harmless, oc apply ignores it on create)"
  fi
}

# ---------------------------------------------------------------------------
# 0. Ensure target project exists
# ---------------------------------------------------------------------------

if ! oc get project "$NEW_NS" >/dev/null 2>&1; then
  echo ">> Creating project $NEW_NS"
  oc new-project "$NEW_NS" >/dev/null
else
  echo ">> Project $NEW_NS already exists, reusing it."
fi

# ---------------------------------------------------------------------------
# 1. Export + clean plain resources
# ---------------------------------------------------------------------------

RESOURCES="deployment service configmap rolebinding role serviceaccount route networkpolicy resourcequota limitrange horizontalpodautoscaler"

for res in $RESOURCES; do
  count=$(oc get "$res" -n "$SRC_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" == "0" ]]; then
    continue
  fi
  echo ">> Exporting $res ($count found)"
  oc get "$res" -n "$SRC_NS" -o yaml > "$WORKDIR/raw-$res.yaml"
  clean_yaml "$WORKDIR/raw-$res.yaml" "$WORKDIR/cleaned-$res.yaml"
done

# ---------------------------------------------------------------------------
# 2. Secrets - skip auto-generated service-account-token secrets
# ---------------------------------------------------------------------------

sec_count=$(oc get secret -n "$SRC_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$sec_count" != "0" ]]; then
  echo ">> Exporting secrets (excluding service-account-token type)"
  oc get secret -n "$SRC_NS" -o yaml > "$WORKDIR/raw-secret.yaml"
  if $HAS_YQ; then
    yq eval 'del(.items[] | select(.type == "kubernetes.io/service-account-token"))' \
      "$WORKDIR/raw-secret.yaml" > "$WORKDIR/raw-secret-filtered.yaml"
  elif $HAS_PY; then
    python3 - "$WORKDIR/raw-secret.yaml" "$WORKDIR/raw-secret-filtered.yaml" <<'PYEOF'
import sys, yaml
inp, outp = sys.argv[1], sys.argv[2]
with open(inp) as f:
    doc = yaml.safe_load(f) or {}
doc["items"] = [i for i in (doc.get("items", []) or [])
                if i.get("type") != "kubernetes.io/service-account-token"]
with open(outp, "w") as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
  else
    awk '
      function flush() { if (buf != "" && !skip) printf "%s", buf; buf=""; skip=0 }
      /^items:/ { print; in_items=1; next }
      in_items && /^[a-zA-Z]/ { flush(); in_items=0; print; next }
      in_items && /^- / { flush(); buf = $0 "\n"; next }
      in_items {
        buf = buf $0 "\n"
        if ($0 ~ /type: kubernetes\.io\/service-account-token/) skip=1
        next
      }
      { print }
      END { if (in_items) flush() }
    ' "$WORKDIR/raw-secret.yaml" > "$WORKDIR/raw-secret-filtered.yaml"
  fi
  clean_yaml "$WORKDIR/raw-secret-filtered.yaml" "$WORKDIR/cleaned-secret.yaml"
fi

filter_existing_pvcs() {
  # $1 = cleaned PVC file in List format (in place) - removes any item whose
  # name already exists as a PVC in $NEW_NS. Once a PVC is bound, its
  # spec (including volumeName) is immutable, so re-applying an already
  # existing PVC with volumeName stripped fails with a "spec is immutable"
  # error. Existing PVCs are left untouched; only new ones get created.
  local existing
  existing=$(oc get pvc -n "$NEW_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  [[ -z "$existing" ]] && return 0

  echo "   Checking for PVCs that already exist in $NEW_NS..."
  local tmp="$1.filtered"

  if $HAS_YQ; then
    local arr
    arr=$(printf '"%s",' $existing)
    arr="[${arr%,}]"
    yq eval "del(.items[] | select(.metadata.name as \$n | (${arr}) | contains([\$n])))" \
      "$1" > "$tmp"
  elif $HAS_PY; then
    EXISTING_PVCS="$existing" python3 - "$1" "$tmp" <<'PYEOF'
import os, sys, yaml
existing = set(os.environ["EXISTING_PVCS"].split())
inp, outp = sys.argv[1], sys.argv[2]
with open(inp) as f:
    doc = yaml.safe_load(f) or {}
kept = []
for item in doc.get("items", []) or []:
    name = item.get("metadata", {}).get("name", "")
    if name in existing:
        print(f"   Skipping PVC/{name}: already exists in {os.environ.get('NEW_NS','target')} "
              f"(bound PVC spec is immutable - leaving it untouched)", file=sys.stderr)
        continue
    kept.append(item)
doc["items"] = kept
with open(outp, "w") as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
  else
    local excl_pattern
    excl_pattern=$(echo "$existing" | sed 's/\./\\./g' | sed 's/ /|/g')
    awk -v excl="$excl_pattern" -v newns="$NEW_NS" '
      function flush() {
        if (buf != "") {
          if (skip) print "   Skipping PVC (already exists in " newns ") - leaving it untouched" > "/dev/stderr"
          else printf "%s", buf
        }
        buf=""; skip=0
      }
      /^items:/ { print; in_items=1; next }
      in_items && /^[a-zA-Z]/ { flush(); in_items=0; print; next }
      in_items && /^- / { flush(); buf = $0 "\n"; next }
      in_items {
        buf = buf $0 "\n"
        if (excl != "" && $0 ~ ("name: (" excl ")$")) skip=1
        next
      }
      { print }
      END { if (in_items) flush() }
    ' "$1" > "$tmp"
  fi
  mv "$tmp" "$1"
}

# ---------------------------------------------------------------------------
# 3. PVCs - strip binding info so a fresh PV gets provisioned
# ---------------------------------------------------------------------------

if $SKIP_PVC; then
  echo ">> -x set: skipping PVC export and creation completely."
  echo "   (Assuming PVCs are created manually in $NEW_NS before running Deployments)"
else
  pvc_count=$(oc get pvc -n "$SRC_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$pvc_count" != "0" ]]; then
    echo ">> Exporting PVCs ($pvc_count found)"
    oc get pvc -n "$SRC_NS" -o yaml > "$WORKDIR/raw-pvc.yaml"

  if $WITH_PVC_DATA; then
    echo "   -p set: attempting VolumeSnapshot-based PVC data clone"
    echo "   NOTE: requires a working CSI VolumeSnapshotClass in this cluster."
    pvc_names=$(oc get pvc -n "$SRC_NS" -o jsonpath='{.items[*].metadata.name}')
    : > "$WORKDIR/cleaned-pvc.yaml"
    SNAP_CLASS="${SNAPSHOT_CLASS:-}"
    if [[ -z "$SNAP_CLASS" ]]; then
      SNAP_CLASS=$(oc get volumesnapshotclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi
    if [[ -z "$SNAP_CLASS" ]]; then
      echo "   WARNING: No VolumeSnapshotClass found in cluster!"
      echo "   Falling back to creating empty PVCs of the same size/storageClass."
      echo "   To copy data manually between running pods, use: oc rsync -n $SRC_NS <src-pod>:/path/ -n $NEW_NS <new-pod>:/path/"
      strip_pvc_binding "$WORKDIR/raw-pvc.yaml" "$WORKDIR/raw-pvc-stripped.yaml"
      clean_yaml "$WORKDIR/raw-pvc-stripped.yaml" "$WORKDIR/cleaned-pvc.yaml"
      filter_existing_pvcs "$WORKDIR/cleaned-pvc.yaml"
    else
      echo "   Using VolumeSnapshotClass: $SNAP_CLASS"
      for pvc in $pvc_names; do
        if oc get pvc "$pvc" -n "$NEW_NS" >/dev/null 2>&1; then
          echo "   Skipping $pvc: already exists in $NEW_NS (bound PVC spec is immutable - leaving it untouched)"
          continue
        fi
        snap_name="${pvc}-snap-$(date +%s)"
        echo "   Snapshotting $pvc in $SRC_NS -> $snap_name"
        oc apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${snap_name}
  namespace: ${SRC_NS}
spec:
  volumeSnapshotClassName: ${SNAP_CLASS}
  source:
    persistentVolumeClaimName: ${pvc}
EOF
        echo "   Waiting for snapshot $snap_name to be ready..."
        if oc wait --for=jsonpath='{.status.readyToUse}'=true \
          volumesnapshot/"$snap_name" -n "$SRC_NS" --timeout=180s; then

          vsc_name=$(oc get volumesnapshot "$snap_name" -n "$SRC_NS" -o jsonpath='{.status.boundVolumeSnapshotContentName}' 2>/dev/null || true)

          if [[ -n "$vsc_name" ]]; then
            echo "   Binding snapshot $snap_name to $NEW_NS via VolumeSnapshotContent $vsc_name"
            oc apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${snap_name}
  namespace: ${NEW_NS}
spec:
  source:
    volumeSnapshotContentName: ${vsc_name}
EOF
          else
            echo "   WARNING: Could not retrieve boundVolumeSnapshotContentName for $snap_name."
          fi
        else
          echo "   WARNING: snapshot $snap_name did not become ready in time; check manually."
        fi

        size=$(oc get pvc "$pvc" -n "$SRC_NS" -o jsonpath='{.spec.resources.requests.storage}')
        sc=$(oc get pvc "$pvc" -n "$SRC_NS" -o jsonpath='{.spec.storageClassName}')
        am=$(oc get pvc "$pvc" -n "$SRC_NS" -o jsonpath='{.spec.accessModes[0]}')

        cat >> "$WORKDIR/cleaned-pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
  namespace: ${NEW_NS}
spec:
  storageClassName: ${sc}
  accessModes:
    - ${am}
  resources:
    requests:
      storage: ${size}
  dataSource:
    name: ${snap_name}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
---
EOF
      done
    fi
  else
    echo "   Stripping volumeName/status (empty volume - use -p to attempt data clone)"
    strip_pvc_binding "$WORKDIR/raw-pvc.yaml" "$WORKDIR/raw-pvc-stripped.yaml"
    clean_yaml "$WORKDIR/raw-pvc-stripped.yaml" "$WORKDIR/cleaned-pvc.yaml"
    filter_existing_pvcs "$WORKDIR/cleaned-pvc.yaml"
  fi
fi
fi
# ---------------------------------------------------------------------------
# 3.5 Rewrite PVC claimNames if -r is specified
# ---------------------------------------------------------------------------

if [[ -n "$PVC_RENAME_MAP" ]]; then
  echo ">> Renaming PVC claimName references in manifests (-r set)"
  OLD_IFS="$IFS"
  IFS=','
  for pair in $PVC_RENAME_MAP; do
    old_pvc="${pair%%:*}"
    new_pvc="${pair#*:}"
    echo "   Rewriting claimName: $old_pvc -> $new_pvc"
    for f in "$WORKDIR"/cleaned-*.yaml; do
      [[ -f "$f" ]] || continue
      sed -e "s/claimName: ${old_pvc}$/claimName: ${new_pvc}/g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
  done
  IFS="$OLD_IFS"
fi

# ---------------------------------------------------------------------------
# 4. Apply - PVCs first, then everything else
# ---------------------------------------------------------------------------

echo
echo ">> Applying to $NEW_NS"

if [[ -f "$WORKDIR/cleaned-pvc.yaml" ]]; then
  if has_objects "$WORKDIR/cleaned-pvc.yaml"; then
    echo ">> Applying PVCs"
    oc apply -f "$WORKDIR/cleaned-pvc.yaml" -n "$NEW_NS"
    echo "   Waiting a few seconds for PVC binding to settle..."
    sleep 5
  else
    echo ">> Skipping PVCs (no objects to apply)"
  fi
fi

for f in "$WORKDIR"/cleaned-*.yaml; do
  [[ "$f" == "$WORKDIR/cleaned-pvc.yaml" ]] && continue
  [[ -e "$f" ]] || continue
  if ! has_objects "$f"; then
    echo ">> Skipping $(basename "$f") (no objects to apply)"
    continue
  fi
  echo ">> Applying $(basename "$f")"
  oc apply -f "$f" -n "$NEW_NS"
done

echo
echo "Done. Manifests kept at: $WORKDIR"
echo
echo "Verify with:"
echo "  oc get all,pvc,route -n $NEW_NS"
echo "  oc get pods -n $NEW_NS"
echo "  oc get events -n $NEW_NS --sort-by='.lastTimestamp' | tail -20"
echo
echo "Things this script does NOT handle - check manually if relevant:"
echo "  - Operator-managed resources (Subscription/CSV/OperatorGroup)"
echo "  - ImageStream references still pointing at ${SRC_NS}"
echo "  - Ingress/DNS-level references outside the cluster"
