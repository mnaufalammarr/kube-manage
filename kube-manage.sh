#!/bin/bash
set -euo pipefail

# ─── Warna ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ─── Error Trap Handler ─────────────────────────────────────────
error_handler() {
  local exit_code=$?
  local line_no=$1
  local bash_cmd=$2
  echo -e "\n${RED}[ERROR] Executed command failed (exit code ${exit_code}) at line ${line_no}: ${bash_cmd}${NC}" >&2
}
trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR

# ─── Pre-flight Check Helper ────────────────────────────────────
get_kube_cli() {
  if command -v kubectl >/dev/null 2>&1; then
    echo "kubectl"
  elif command -v oc >/dev/null 2>&1; then
    echo "oc"
  else
    echo -e "${RED}Error: CLI 'kubectl' atau 'oc' tidak ditemukan di PATH.${NC}" >&2
    exit 1
  fi
}

check_cluster_conn() {
  local cli
  cli=$(get_kube_cli)
  if ! $cli get api-resources &>/dev/null && ! $cli version --client &>/dev/null; then
    echo -e "${RED}Error: Tidak dapat berkomunikasi dengan Kubernetes API server.${NC}" >&2
    echo -e "${YELLOW}Pastikan Anda telah login (oc login / kubectl) dan terhubung ke VPN cluster.${NC}" >&2
    exit 1
  fi
}

# ─── Direktori snapshot ─────────────────────────────────────────
SNAPSHOT_DIR="${HOME}/.kube-update-snapshots"
mkdir -p "$SNAPSHOT_DIR"

usage() {
  echo -e "${BOLD}Usage:${NC}"
  echo "  $0 update      -t NEW_TAG [-n NAMESPACE] [-f file.txt] [-d] [--auto-rollback] [--wait]"
  echo "  $0 rollback    [-n NAMESPACE] [-s SNAPSHOT_FILE]"
  echo "  $0 list"
  echo "  $0 pods        [-n NAMESPACE]"
  echo "  $0 restart     -p PATTERN [-n NAMESPACE]"
  echo "  $0 pull-policy -d DEPLOYMENT -p POLICY [-n NAMESPACE] [-c CONTAINER]"
  echo "  $0 scale       [-n NAMESPACE] [-d DEPLOYMENT | -f file.txt | --all] [-r REPLICAS]"
  echo "  $0 clone       -s SRC_NS -n NEW_NS [-r old:new,...] [-v pvc1,...] [-p] [-x]"
  echo "  $0 chpasswd    [-u USERNAME] [-s SECRET_NAME] [--secret-ns NAMESPACE] [--idp IDP_NAME]"
  echo "  $0 resources   [-n NAMESPACE] [-d DEPLOYMENT | -f file.txt | --all] [--cpu-req 100m] [--mem-req 256Mi] [--cpu-lim 500m] [--mem-lim 512Mi]"
  echo "  $0 hpa         [-n NAMESPACE] [-d DEPLOYMENT | -f file.txt | --all] [--min 1] [--max 5] [--cpu-percent 80] [--mem-percent 80] [--delete]"
  echo "  $0 ctx         [CONTEXT_NAME]"
  echo "  $0 token       [-u SA_NAME] [-n NAMESPACE] [--duration 8760h] [--permanent]"
  echo "  $0 config      [-n NAMESPACE] [-cm CM_NAME] [-k KEY] [-v VALUE] [--replace OLD:NEW] [-r]"
  echo ""
  echo -e "${BOLD}Mode:${NC}"
  echo "  update       Ganti tag image deployment (simpan snapshot otomatis)"
  echo "  rollback     Kembalikan image ke snapshot sebelumnya"
  echo "  list         Tampilkan daftar snapshot tersedia"
  echo "  pods         Tampilkan pod & image di namespace"
  echo "  restart      Restart pod yang namanya cocok dengan pola (regex)"
  echo "  pull-policy  Update imagePullPolicy pada deployment (Always/IfNotPresent/Never)"
  echo "  scale        Ubah jumlah replika deployment (interaktif dari daftar jika -d & -f kosong)"
  echo "  clone        Duplikasi (clone) namespace/project beserta seluruh resource-nya"
  echo "  chpasswd     Ganti password user OpenShift (HTPasswd identity provider)"
  echo "  resources    Set/update resource requests & limits CPU/Memory pada container deployment"
  echo "  hpa          Aktifkan/konfigurasi Horizontal Pod Autoscaler (HPA) pada deployment"
  echo "  ctx          Tampilkan & ganti cluster context aktif (pindah antar cluster)"
  echo "  token        Generate Bearer Token 1 tahun / permanen untuk login cluster tanpa expired"
  echo "  config       Update ConfigMap / Env Vars (contoh: ganti IP Logstash) & restart pods"
  echo ""
  echo -e "${BOLD}Opsi update:${NC}"
  echo "  -t  Tag baru (wajib)           contoh: v2.1.0"
  echo "  -n  Namespace (default: default)"
  echo "  -f  File daftar deployment"
  echo "  -d  Dry-run"
  echo "  -c, --check-registry   Cek keberadaan tag di Nexus/Registry via curl"
  echo "  --auth USER:PASS       Basic auth credential untuk Nexus/Registry"
  echo "  --auto-rollback        Otomatis rollback jika ada deployment gagal rollout"
  echo "  --wait                 Tunggu rollout selesai setelah update"
  echo ""
  echo -e "${BOLD}Opsi rollback:${NC}"
  echo "  -n  Namespace"
  echo "  -s  Path file snapshot (opsional, default: snapshot terbaru)"
  echo ""
  echo -e "${BOLD}Opsi pods:${NC}"
  echo "  -n  Namespace (default: default)"
  echo ""
  echo -e "${BOLD}Opsi restart:${NC}"
  echo "  -p  Pola nama pod (regex, wajib)   contoh: '^jaguars-api-'"
  echo "  -n  Namespace (default: default)"
  echo ""
  echo -e "${BOLD}Opsi pull-policy:${NC}"
  echo "  -d  Nama deployment (wajib)"
  echo "  -p  Policy baru (wajib)        Always | IfNotPresent | Never"
  echo "  -n  Namespace (default: default)"
  echo "  -c  Nama container (opsional, default: container pertama)"
  echo ""
  echo -e "${BOLD}Opsi scale:${NC}"
  echo "  -n  Namespace (default: default)"
  echo "  -d  Nama deployment (opsional)"
  echo "  -f  File daftar deployment untuk batch scale"
  echo "  -a, --all  Scale SEMUA deployment di namespace"
  echo "  -r  Jumlah replika baru (opsional)"
  echo ""
  echo -e "${BOLD}Opsi clone:${NC}"
  echo "  -s  Source namespace / project (wajib)"
  echo "  -n  Namespace / project baru (wajib)"
  echo "  -r  Rename reference claimName PVC (contoh: -r 'old-pvc:new-pvc')"
  echo "  -v  Filter nama PVC tertentu (contoh: -v 'pvc1,pvc2')"
  echo "  -p  Coba duplikasi data PVC via CSI VolumeSnapshot"
  echo "  -x  Skip pembuatan PVC (jika PVC dibuat manual)"
  echo "  --only, --type  Clone HANYA resource tertentu (contoh: service, deployment, configmap)"
  echo ""
  echo -e "${BOLD}Opsi chpasswd:${NC}"
  echo "  -u  Username yang akan diganti password-nya (opsional, bisa pilih interaktif)"
  echo "  -s  Nama Secret htpasswd (default: htpass-secret)"
  echo "  --secret-ns  Namespace Secret (default: openshift-config)"
  echo "  --idp        Nama Identity Provider (default: htpasswd_provider)"
  echo ""
  echo -e "${BOLD}Opsi resources:${NC}"
  echo "  -n  Namespace (default: default)"
  echo "  -d  Nama deployment (opsional)"
  echo "  -f  File daftar deployment"
  echo "  -a, --all  Set resource untuk SEMUA deployment"
  echo "  --cpu-req  CPU request (default: 100m)"
  echo "  --mem-req  Memory request (default: 256Mi)"
  echo "  --cpu-lim  CPU limit (opsional, contoh: 500m)"
  echo "  --mem-lim  Memory limit (opsional, contoh: 512Mi)"
  echo "  -c  Nama container (opsional)"
  echo ""
  echo -e "${BOLD}Opsi hpa:${NC}"
  echo "  -n  Namespace (default: default)"
  echo "  -d  Nama deployment (opsional)"
  echo "  -f  File daftar deployment"
  echo "  -a, --all  Aktifkan HPA untuk SEMUA deployment"
  echo "  --min          Jumlah replika minimal (default: 1)"
  echo "  --max          Jumlah replika maksimal (default: 5)"
  echo "  --cpu-percent  Target pemakaian CPU % (opsional, contoh: 80)"
  echo "  --mem-percent  Target pemakaian Memory % (opsional, contoh: 80)"
  echo "  --delete       Hapus HPA dari deployment"
  echo ""
  echo -e "${BOLD}Opsi ctx:${NC}"
  echo "  [CONTEXT_NAME]                Nama context cluster (opsional, jika kosong tampil menu interaktif)"
  echo "  --add-file <path> [ALIAS]     Import & merge file kubeconfig baru ke ~/.kube/config"
  echo "  --login <SERVER_URL> [-u USR] Login ke cluster baru dan simpan context"
  echo "  --delete <CONTEXT_NAME>       Hapus context tertentu dari ~/.kube/config"
  echo "  --clear-all                   Hapus SEMUA context (reset ~/.kube/config)"
  echo ""
  echo -e "${BOLD}Opsi token:${NC}"
  echo "  -u, --user <SA_NAME>          Nama ServiceAccount (default: admin-user)"
  echo "  -n, --namespace <NAMESPACE>   Namespace ServiceAccount (default: default)"
  echo "  --duration <HOURS>            Masa aktif token (default: 8760h / 1 tahun)"
  echo "  --permanent                   Buat token permanen tanpa masa expired"
  echo ""
  echo -e "${BOLD}Opsi config:${NC}"
  echo "  -n NAMESPACE                  Namespace Kubernetes (default: default)"
  echo "  -cm CM_NAME                   Nama ConfigMap"
  echo "  -k KEY                        Nama key di ConfigMap (contoh: LOGSTASH_HOST)"
  echo "  -v VALUE                      Nilai baru (contoh: 10.2.2.10:5044)"
  echo "  --replace OLD:NEW             Ganti teks string di SEMUA ConfigMap (contoh: 10.1.1.5:10.2.2.10)"
  echo "  -r, --restart                 Otomatis restart semua deployment di namespace setelah update"
  echo ""
  echo -e "${BOLD}Contoh Penggunaan (Examples):${NC}"
  echo "  $0 update -t 3.0.0 -n jaguars -f service-300.txt -c --auth 'admin:pass'"
  echo "  $0 rollback -n jaguars"
  echo "  $0 pods -n jaguars"
  echo "  $0 restart -p '^app-' -n jaguars"
  echo "  $0 pull-policy -d app-penjaminan -p Always -n jaguars"
  echo "  $0 scale -n jaguars --all -r 0"
  echo "  $0 clone -s jaguars -n jaguars-dev --only service"
  echo "  $0 resources -n jaguars --all --cpu-req 100m --mem-req 1Gi --cpu-lim 1 --mem-lim 3Gi"
  echo "  $0 hpa -n jaguars --all --min 1 --max 5 --cpu-percent 80 --mem-percent 80"
  echo "  $0 ctx"
  echo "  $0 ctx --login https://api.cluster.com:6443 -p 'sha256~TOKEN' prod-cluster"
  echo "  $0 ctx --add-file ~/cluster.yaml dev-cluster"
  echo "  $0 ctx --delete staging-cluster"
  echo "  $0 token --duration 8760h"
  echo "  $0 token --permanent"
  echo "  $0 chpasswd -u admin"
  exit 1
}

# ════════════════════════════════════════════════════════════════
# MODE-SPECIFIC HELP FUNCTIONS
# ════════════════════════════════════════════════════════════════

update_help() {
  echo -e "${BOLD}Usage:${NC} $0 update -t NEW_TAG [-n NAMESPACE] [-f file.txt] [-d] [-c] [--auth USER:PASS] [--auto-rollback] [--wait]"
  echo -e "${BOLD}Deskripsi:${NC} Ganti tag image deployment dan simpan snapshot otomatis."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -t  NEW_TAG            Tag image baru (wajib, contoh: v3.0.0)"
  echo "  -n  NAMESPACE          Namespace Kubernetes (default: default)"
  echo "  -f  file.txt           File daftar nama deployment"
  echo "  -d                     Dry-run (simulasi tanpa mengubah cluster)"
  echo "  -c, --check-registry   Cek keberadaan tag di Nexus/Registry via curl"
  echo "  --auth USER:PASS       Basic auth credential untuk Nexus/Registry"
  echo "  --auto-rollback        Otomatis rollback jika ada deployment gagal rollout"
  echo "  --wait                 Tunggu rollout selesai setelah update"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 update -t 3.0.0 -n jaguars -f service-300.txt -c --auth 'admin:pass'"
  echo "  $0 update -t 3.0.0 -n jaguars --wait --auto-rollback"
  exit 0
}

rollback_help() {
  echo -e "${BOLD}Usage:${NC} $0 rollback [-n NAMESPACE] [-s SNAPSHOT_FILE]"
  echo -e "${BOLD}Deskripsi:${NC} Kembalikan image deployment ke snapshot sebelumnya."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -n  NAMESPACE          Namespace Kubernetes (default: default)"
  echo "  -s  SNAPSHOT_FILE      Path file snapshot (opsional, default: snapshot terbaru)"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 rollback -n jaguars"
  echo "  $0 rollback -n jaguars -s ~/.kube-update-snapshots/snapshot_jaguars_20260730.env"
  exit 0
}

list_help() {
  echo -e "${BOLD}Usage:${NC} $0 list"
  echo -e "${BOLD}Deskripsi:${NC} Tampilkan daftar file snapshot yang tersimpan."
  exit 0
}

pods_help() {
  echo -e "${BOLD}Usage:${NC} $0 pods [-n NAMESPACE]"
  echo -e "${BOLD}Deskripsi:${NC} Tampilkan daftar pod dan image di namespace."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -n  NAMESPACE          Namespace Kubernetes (default: default)"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 pods -n jaguars"
  exit 0
}

restart_help() {
  echo -e "${BOLD}Usage:${NC} $0 restart -p PATTERN [-n NAMESPACE]"
  echo -e "${BOLD}Deskripsi:${NC} Restart pod yang namanya cocok dengan pola regex."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -p  PATTERN            Pola nama pod (regex, wajib, contoh: '^app-')"
  echo "  -n  NAMESPACE          Namespace Kubernetes (default: default)"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 restart -p '^app-penjaminan-' -n jaguars"
  exit 0
}

pull_policy_help() {
  echo -e "${BOLD}Usage:${NC} $0 pull-policy -d DEPLOYMENT -p POLICY [-n NAMESPACE] [-c CONTAINER]"
  echo -e "${BOLD}Deskripsi:${NC} Update imagePullPolicy pada deployment (Always | IfNotPresent | Never)."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -d  DEPLOYMENT         Nama deployment (wajib)"
  echo "  -p  POLICY             Policy baru: Always | IfNotPresent | Never (wajib)"
  echo "  -n  NAMESPACE          Namespace Kubernetes (default: default)"
  echo "  -c  CONTAINER          Nama container (opsional, default: container pertama)"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 pull-policy -d app-penjaminan -p Always -n jaguars"
  exit 0
}

scale_help() {
  echo -e "${BOLD}Usage:${NC} $0 scale [-n NAMESPACE] [-d DEPLOYMENT | -f file.txt | --all] [-r REPLICAS]"
  echo -e "${BOLD}Deskripsi:${NC} Ubah jumlah replika deployment."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -n  NAMESPACE          Namespace Kubernetes (default: default)"
  echo "  -d  DEPLOYMENT         Nama deployment (opsional, jika kosong tampil menu interaktif)"
  echo "  -f  file.txt           File daftar deployment untuk batch scale"
  echo "  -a, --all              Scale SEMUA deployment di namespace"
  echo "  -r  REPLICAS           Jumlah replika baru (opsional)"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 scale -n jaguars -d app-penjaminan -r 3"
  echo "  $0 scale -n jaguars --all -r 0"
  exit 0
}

clone_help() {
  echo -e "${BOLD}Usage:${NC} $0 clone -s SRC_NS -n NEW_NS [-r old:new,...] [-v pvc1,...] [-p] [-x] [--only TYPE]"
  echo -e "${BOLD}Deskripsi:${NC} Duplikasi (clone) namespace/project beserta seluruh resourcenya."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -s  SRC_NS             Source namespace / project (wajib)"
  echo "  -n  NEW_NS             Namespace / project baru (wajib)"
  echo "  -r  OLD:NEW            Rename reference claimName PVC (contoh: -r 'old-pvc:new-pvc')"
  echo "  -v  PVC1,PVC2          Filter nama PVC tertentu"
  echo "  -p                     Coba duplikasi data PVC via CSI VolumeSnapshot"
  echo "  -x                     Skip pembuatan PVC (jika PVC dibuat manual)"
  echo "  --only, --type TYPE    Clone HANYA resource tertentu (contoh: service, deployment, configmap)"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 clone -s jaguars -n jaguars-dev"
  echo "  $0 clone -s jaguars -n jaguars-dev --only service"
  exit 0
}

chpasswd_help() {
  echo -e "${BOLD}Usage:${NC} $0 chpasswd [-u USERNAME] [-s SECRET_NAME] [--secret-ns NAMESPACE] [--idp IDP_NAME]"
  echo -e "${BOLD}Deskripsi:${NC} Ganti password user OpenShift HTPasswd."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -u  USERNAME           Username yang akan diganti passwordnya (opsional)"
  echo "  -s  SECRET_NAME        Nama Secret htpasswd (default: htpass-secret)"
  echo "  --secret-ns NAMESPACE  Namespace Secret (default: openshift-config)"
  echo "  --idp IDP_NAME         Nama Identity Provider (default: htpasswd_provider)"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 chpasswd -u admin"
  exit 0
}

resources_help() {
  echo -e "${BOLD}Usage:${NC} $0 resources [-n NAMESPACE] [-d DEPLOYMENT | -f file.txt | --all] [--cpu-req 100m] [--mem-req 256Mi] [--cpu-lim 500m] [--mem-lim 512Mi]"
  echo -e "${BOLD}Deskripsi:${NC} Set/update resource requests & limits CPU/Memory pada container deployment."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -n  NAMESPACE          Namespace Kubernetes (default: default)"
  echo "  -d  DEPLOYMENT         Nama deployment (opsional)"
  echo "  -f  file.txt           File daftar deployment"
  echo "  -a, --all              Set resource untuk SEMUA deployment"
  echo "  --cpu-req CPU          CPU request (contoh: 100m / 0.1)"
  echo "  --mem-req MEM          Memory request (contoh: 256Mi / 1Gi)"
  echo "  --cpu-lim CPU          CPU limit (contoh: 500m / 1)"
  echo "  --mem-lim MEM          Memory limit (contoh: 512Mi / 3Gi)"
  echo "  -c  CONTAINER          Nama container (opsional)"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 resources -n jaguars --all --cpu-req 100m --mem-req 1Gi --cpu-lim 1 --mem-lim 3Gi"
  exit 0
}

hpa_help() {
  echo -e "${BOLD}Usage:${NC} $0 hpa [-n NAMESPACE] [-d DEPLOYMENT | -f file.txt | --all] [--min 1] [--max 5] [--cpu-percent 80] [--mem-percent 80] [--delete]"
  echo -e "${BOLD}Deskripsi:${NC} Aktifkan/konfigurasi Horizontal Pod Autoscaler (HPA) CPU & Memory."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -n  NAMESPACE          Namespace Kubernetes (default: default)"
  echo "  -d  DEPLOYMENT         Nama deployment (opsional)"
  echo "  -f  file.txt           File daftar deployment"
  echo "  -a, --all              Aktifkan HPA untuk SEMUA deployment"
  echo "  --min MIN              Jumlah replika minimal (default: 1)"
  echo "  --max MAX              Jumlah replika maksimal (default: 5)"
  echo "  --cpu-percent PERCENT  Target pemakaian CPU % (opsional, contoh: 80)"
  echo "  --mem-percent PERCENT  Target pemakaian Memory % (opsional, contoh: 80)"
  echo "  --delete               Hapus HPA dari deployment"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 hpa -n jaguars --all --min 1 --max 5 --cpu-percent 80 --mem-percent 80"
  echo "  $0 hpa -n jaguars --all --delete"
  exit 0
}

ctx_help() {
  echo -e "${BOLD}Usage:${NC} $0 ctx [CONTEXT_NAME | --add-file PATH | --login URL | --delete NAME | --clear-all]"
  echo -e "${BOLD}Deskripsi:${NC} Lihat, pindah, tambah, atau hapus cluster context."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  CONTEXT_NAME                Nama context cluster untuk dipilih"
  echo "  --add-file PATH [ALIAS]     Import & merge file kubeconfig baru ke ~/.kube/config"
  echo "  --login URL [-u USR] [-p]   Login ke cluster baru dan simpan context"
  echo "  --delete CONTEXT_NAME       Hapus context tertentu"
  echo "  --clear-all                 Hapus SEMUA context (reset ~/.kube/config)"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 ctx"
  echo "  $0 ctx prod-cluster"
  echo "  $0 ctx --add-file ~/cluster.yaml dev-cluster"
  echo "  $0 ctx --login https://api.cluster.com:6443 -p 'sha256~TOKEN' prod-cluster"
  echo "  $0 ctx --delete staging-cluster"
  echo "  $0 ctx --clear-all"
  exit 0
}

token_help() {
  echo -e "${BOLD}Usage:${NC} $0 token [-u SA_NAME] [-n NAMESPACE] [--duration 8760h] [--permanent]"
  echo -e "${BOLD}Deskripsi:${NC} Generate Bearer Token 1 tahun / permanen untuk login cluster tanpa expired."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -u, --user SA_NAME          Nama ServiceAccount (default: admin-user)"
  echo "  -n, --namespace NAMESPACE   Namespace ServiceAccount (default: default)"
  echo "  --duration DURATION         Masa aktif token (default: 8760h / 1 tahun)"
  echo "  --permanent                 Buat token permanen tanpa masa expired"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 token --duration 8760h"
  echo "  $0 token --permanent"
  exit 0
}

config_help() {
  echo -e "${BOLD}Usage:${NC} $0 config -n NAMESPACE [-e KEY=VALUE] [-d DEPLOY | -a/--all] [--old OLD --new NEW] [-r]"
  echo -e "${BOLD}Deskripsi:${NC} Update ConfigMap / Secret / Deployment environment variables dan restart pod otomatis."
  echo -e "${BOLD}Opsi:${NC}"
  echo "  -n NAMESPACE          Namespace Kubernetes (default: default)"
  echo "  -e, --env KEY=VALUE   Set environment variable langsung pada deployment (contoh: JAVA_TOOL_OPTIONS=...)"
  echo "  -d DEPLOYMENT         Nama deployment target (opsional, default: --all)"
  echo "  -a, --all             Terapkan ke SEMUA deployment di namespace"
  echo "  --old OLD_STR         Teks string lama yang akan diganti"
  echo "  --new NEW_STR         Teks string baru pengganti"
  echo "  -cm CM_NAME           Nama ConfigMap"
  echo "  -k KEY                Nama key di ConfigMap"
  echo "  -v VALUE              Nilai baru"
  echo "  -r, --restart         Otomatis restart semua deployment di namespace setelah update"
  echo -e "${BOLD}Contoh:${NC}"
  echo "  $0 config -n jaguars -e 'JAVA_TOOL_OPTIONS=-Duser.timezone=\"Asia/Jakarta\" -XX:MaxMetaspaceSize=512m -XX:MaxDirectMemorySize=256m -Xmx1024M' --all"
  echo "  $0 config -n jaguars --old '-XX:MaxMetaspaceSize=2048m' --new '-XX:MaxMetaspaceSize=512m' -r"
  exit 0
}

# ════════════════════════════════════════════════════════════════
# HELPER
# ════════════════════════════════════════════════════════════════

get_current_image() {
  kubectl get deployment "$1" -n "$2" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
}

get_container_name() {
  kubectl get deployment "$1" -n "$2" \
    -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null || true
}

strip_tag() {
  echo "$1" | sed 's/:[^:]*$//' || true
}

latest_snapshot() {
  ls -t "$SNAPSHOT_DIR"/snapshot_*.env 2>/dev/null | head -1 || true
}

check_registry_tag() {
  local FULL_IMAGE="$1"
  local TAG="$2"
  local AUTH_USER="${3:-${REGISTRY_USER:-}}"
  local AUTH_PASS="${4:-${REGISTRY_PASS:-}}"

  local BASE_IMAGE
  BASE_IMAGE=$(strip_tag "$FULL_IMAGE")

  local HOST
  HOST=$(echo "$BASE_IMAGE" | cut -d'/' -f1)
  local REPO
  REPO=$(echo "$BASE_IMAGE" | cut -d'/' -f2-)

  if [[ -z "$HOST" || -z "$REPO" || "$HOST" == "$REPO" ]]; then
    return 1
  fi

  local CURL_OPTS=(-s -k -L --connect-timeout 4)
  if [[ -n "$AUTH_USER" && -n "$AUTH_PASS" ]]; then
    CURL_OPTS+=(-u "${AUTH_USER}:${AUTH_PASS}")
  fi

  # Method 1: Cek JSON daftar tag (/v2/<repo>/tags/list)
  local TAGS_JSON
  TAGS_JSON=$(curl "${CURL_OPTS[@]}" "https://${HOST}/v2/${REPO}/tags/list" 2>/dev/null || echo "")
  if [[ -z "$TAGS_JSON" || "$TAGS_JSON" =~ ^40 || "$TAGS_JSON" =~ ^50 ]]; then
    TAGS_JSON=$(curl "${CURL_OPTS[@]}" "http://${HOST}/v2/${REPO}/tags/list" 2>/dev/null || echo "")
  fi

  if [[ -n "$TAGS_JSON" ]] && echo "$TAGS_JSON" | grep -q '"tags"'; then
    if echo "$TAGS_JSON" | grep -q "\"${TAG}\""; then
      return 0
    else
      return 1
    fi
  fi

  # Method 2: Fallback ke manifest check (HANYA HTTP 200)
  local MANIFEST_OPTS=(-s -k -L -o /dev/null -w "%{http_code}" --connect-timeout 4)
  MANIFEST_OPTS+=(-H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json")
  if [[ -n "$AUTH_USER" && -n "$AUTH_PASS" ]]; then
    MANIFEST_OPTS+=(-u "${AUTH_USER}:${AUTH_PASS}")
  fi

  local HTTP_CODE
  HTTP_CODE=$(curl "${MANIFEST_OPTS[@]}" "https://${HOST}/v2/${REPO}/manifests/${TAG}" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    return 0
  fi

  HTTP_CODE=$(curl "${MANIFEST_OPTS[@]}" "http://${HOST}/v2/${REPO}/manifests/${TAG}" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    return 0
  fi

  return 1
}

# ════════════════════════════════════════════════════════════════
# MODE: LIST
# ════════════════════════════════════════════════════════════════

cmd_list() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    list_help
  fi
  echo -e "${BOLD}Daftar snapshot tersimpan:${NC}"
  echo ""
  local files
  mapfile -t files < <(ls -t "$SNAPSHOT_DIR"/snapshot_*.env 2>/dev/null)

  if [[ ${#files[@]} -eq 0 ]]; then
    echo -e "  ${YELLOW}Belum ada snapshot.${NC}"
    return
  fi

  printf "  %-3s %-35s %-12s %s\n" "NO" "FILE" "NAMESPACE" "DIBUAT"
  printf "  %-3s %-35s %-12s %s\n" "---" "-----------------------------------" "----------" "-------"

  local i=1
  for f in "${files[@]}"; do
    local fname; fname=$(basename "$f")
    local ns; ns=$(grep '^NAMESPACE=' "$f" | cut -d= -f2 || true)
    local ts; ts=$(grep '^TIMESTAMP=' "$f" | cut -d= -f2 || true)
    printf "  %-3s %-35s %-12s %s\n" "$i" "$fname" "$ns" "$ts"
    ((i++))
  done
  echo ""
  echo -e "  Lokasi: ${CYAN}${SNAPSHOT_DIR}${NC}"
}

# ════════════════════════════════════════════════════════════════
# MODE: PODS  (list pods & image di namespace)
# ════════════════════════════════════════════════════════════════

cmd_pods() {
  local NAMESPACE="default"

  while [[ $# -gt 0 ]]; do
    case $1 in
      -n) NAMESPACE="$2"; shift 2 ;;
      -h|--help) pods_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; pods_help ;;
    esac
  done

  echo -e "${BOLD}Pod & image di namespace '${CYAN}${NAMESPACE}${NC}${BOLD}':${NC}"
  echo ""
  kubectl get pods -n "$NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CONTAINER:.spec.containers[*].name,IMAGE:.spec.containers[*].image'
}

# ════════════════════════════════════════════════════════════════
# MODE: RESTART  (restart pod berdasarkan pola nama)
# ════════════════════════════════════════════════════════════════

cmd_restart() {
  local NAMESPACE="default" PATTERN=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      -n) NAMESPACE="$2"; shift 2 ;;
      -p) PATTERN="$2"; shift 2 ;;
      -h|--help) restart_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; restart_help ;;
    esac
  done

  if [[ -z "$PATTERN" ]]; then
    echo -e "${RED}Error: -p PATTERN wajib diisi.${NC}"
    usage
  fi

  echo -e "${CYAN}Mencari pod dengan pola '${PATTERN}' di namespace '${NAMESPACE}'...${NC}"
  local MATCHED=()
  mapfile -t MATCHED < <(kubectl get pods -n "$NAMESPACE" -o name | sed 's|pod/||' | grep -E "$PATTERN" || true)

  if [[ ${#MATCHED[@]} -eq 0 ]]; then
    echo -e "${YELLOW}Tidak ada pod yang cocok dengan pola tersebut.${NC}"
    return 0
  fi

  echo ""
  echo -e "${BOLD}Pod berikut akan di-restart (dihapus, lalu dibuat ulang oleh controller):${NC}"
  for p in "${MATCHED[@]}"; do
    echo -e "  ${YELLOW}${p}${NC}"
  done
  echo ""
  echo -ne "Lanjutkan? (y/N): "
  read -r CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Dibatalkan."
    exit 0
  fi

  echo ""
  local SUCCESS=() FAILED=()
  for p in "${MATCHED[@]}"; do
    echo -ne "  Menghapus pod ${BOLD}${p}${NC} ... "
    if kubectl delete pod "$p" -n "$NAMESPACE" &>/dev/null; then
      echo -e "${GREEN}✓${NC}"
      SUCCESS+=("$p")
    else
      echo -e "${RED}✗ gagal${NC}"
      FAILED+=("$p")
    fi
  done

  echo ""
  echo -e "${BOLD}Ringkasan restart:${NC}"
  echo -e "  ${GREEN}Berhasil : ${#SUCCESS[@]}${NC}"
  echo -e "  ${RED}Gagal    : ${#FAILED[@]}${NC}"
}

# ════════════════════════════════════════════════════════════════
# MODE: PULL-POLICY  (update imagePullPolicy pada deployment)
# ════════════════════════════════════════════════════════════════

cmd_pull_policy() {
  local NAMESPACE="default" DEPLOY="" CONTAINER="" POLICY=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      -n) NAMESPACE="$2"; shift 2 ;;
      -d) DEPLOY="$2"; shift 2 ;;
      -c) CONTAINER="$2"; shift 2 ;;
      -p) POLICY="$2"; shift 2 ;;
      -h|--help) pull_policy_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; pull_policy_help ;;
    esac
  done

  if [[ -z "$DEPLOY" || -z "$POLICY" ]]; then
    echo -e "${RED}Error: -d DEPLOYMENT dan -p POLICY wajib diisi.${NC}"
    usage
  fi

  case "$POLICY" in
    Always|IfNotPresent|Never) ;;
    *)
      echo -e "${RED}Error: POLICY harus salah satu dari Always | IfNotPresent | Never.${NC}"
      exit 1
      ;;
  esac

  if [[ -z "$CONTAINER" ]]; then
    CONTAINER=$(get_container_name "$DEPLOY" "$NAMESPACE")
    if [[ -z "$CONTAINER" ]]; then
      echo -e "${RED}Error: tidak bisa menemukan deployment '$DEPLOY' di namespace '$NAMESPACE'.${NC}"
      exit 1
    fi
    echo -e "${CYAN}Container tidak disebut, memakai container pertama: ${CONTAINER}${NC}"
  fi

  echo ""
  echo -e "${BOLD}Update imagePullPolicy${NC}"
  echo -e "  Namespace  : ${CYAN}${NAMESPACE}${NC}"
  echo -e "  Deployment : ${CYAN}${DEPLOY}${NC}"
  echo -e "  Container  : ${CYAN}${CONTAINER}${NC}"
  echo -e "  Policy baru: ${GREEN}${POLICY}${NC}"
  echo ""
  read -rp "Lanjutkan? (y/N): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Dibatalkan."
    exit 0
  fi

  echo ""
  echo -ne "  Menerapkan patch ... "
  if kubectl patch deployment "$DEPLOY" -n "$NAMESPACE" --type=strategic -p \
      "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${CONTAINER}\",\"imagePullPolicy\":\"${POLICY}\"}]}}}}" &>/dev/null; then
    echo -e "${GREEN}✓ berhasil${NC}"
  else
    echo -e "${RED}✗ gagal${NC}"
    exit 1
  fi
}

# ════════════════════════════════════════════════════════════════
# MODE: UPDATE
# ════════════════════════════════════════════════════════════════

cmd_update() {
  local NEW_TAG="" NAMESPACE="default" DEPLOY_FILE=""
  local DRY_RUN="false" AUTO_ROLLBACK="false" DO_WAIT="false"
  local CHECK_REGISTRY="false" AUTH_USER="" AUTH_PASS=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      -t) NEW_TAG="$2"; shift 2 ;;
      -n) NAMESPACE="$2"; shift 2 ;;
      -f) DEPLOY_FILE="$2"; shift 2 ;;
      -d) DRY_RUN="true"; shift ;;
      -c|--check-registry) CHECK_REGISTRY="true"; shift ;;
      --auth)
        AUTH_USER=$(echo "$2" | cut -d: -f1 || true)
        AUTH_PASS=$(echo "$2" | cut -d: -f2 || true)
        shift 2
        ;;
      --auto-rollback) AUTO_ROLLBACK="true"; shift ;;
      --wait) DO_WAIT="true"; shift ;;
      -h|--help) update_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; update_help ;;
    esac
  done

  if [[ -z "$NEW_TAG" ]]; then
    echo -e "${RED}Error: -t NEW_TAG wajib diisi.${NC}"
    usage
  fi

  if [[ "$CHECK_REGISTRY" == "true" ]] && ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}Error: 'curl' tidak ditemukan di system. Diperlukan untuk opsi -c / --check-registry.${NC}"
    exit 1
  fi

  # ── Ambil daftar deployment ──────────────────────────────────
  local DEPLOYMENTS=()
  if [[ -n "$DEPLOY_FILE" ]]; then
    if [[ ! -f "$DEPLOY_FILE" ]]; then
      echo -e "${RED}Error: file '$DEPLOY_FILE' tidak ditemukan.${NC}"
      exit 1
    fi
    mapfile -t DEPLOYMENTS < <(grep -v '^\s*#' "$DEPLOY_FILE" | grep -v '^\s*$' | tr -d '\r' || true)
  else
    echo -e "${CYAN}Mengambil semua deployment di namespace '${NAMESPACE}'...${NC}"
    mapfile -t DEPLOYMENTS < <(kubectl get deployments -n "$NAMESPACE" \
      -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' || true)
  fi

  if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}Tidak ada deployment ditemukan.${NC}"
    exit 0
  fi

  # ── Pratinjau & susun plan ───────────────────────────────────
  echo ""
  echo -e "${BOLD}Pratinjau update tag → ${CYAN}${NEW_TAG}${NC}"
  echo -e "Namespace : ${CYAN}${NAMESPACE}${NC}"
  [[ "$CHECK_REGISTRY" == "true" ]] && echo -e "Mode      : ${CYAN}Auto-Check Nexus/Registry API${NC}"
  echo ""
  printf "  %-28s %-38s %s\n" "DEPLOYMENT" "IMAGE SEKARANG" "IMAGE BARU"
  printf "  %-28s %-38s %s\n" "----------" "--------------" "----------"

  declare -A PLAN_IMAGE PLAN_CONTAINER PLAN_OLD_IMAGE
  local SKIP=()

  for DEPLOY in "${DEPLOYMENTS[@]}"; do
    local CUR; CUR=$(get_current_image "$DEPLOY" "$NAMESPACE")
    if [[ -z "$CUR" ]]; then
      printf "  ${RED}%-28s tidak ditemukan${NC}\n" "$DEPLOY"
      SKIP+=("$DEPLOY")
      continue
    fi
    local BASE; BASE=$(strip_tag "$CUR")
    local NEW_IMG="${BASE}:${NEW_TAG}"

    if [[ "$CUR" == "$NEW_IMG" ]]; then
      printf "  %-28s ${CYAN}%-38s (sudah tag ${NEW_TAG}, di-skip)${NC}\n" "$DEPLOY" "$CUR"
      SKIP+=("$DEPLOY")
      continue
    fi

    if [[ "$CHECK_REGISTRY" == "true" ]]; then
      if ! check_registry_tag "$CUR" "$NEW_TAG" "$AUTH_USER" "$AUTH_PASS"; then
        printf "  %-28s ${YELLOW}%-38s (tag ${NEW_TAG} tidak ada di Nexus, di-skip)${NC}\n" "$DEPLOY" "$CUR"
        SKIP+=("$DEPLOY")
        continue
      fi
    fi

    local CTR; CTR=$(get_container_name "$DEPLOY" "$NAMESPACE")
    PLAN_IMAGE["$DEPLOY"]="$NEW_IMG"
    PLAN_CONTAINER["$DEPLOY"]="$CTR"
    PLAN_OLD_IMAGE["$DEPLOY"]="$CUR"
    printf "  %-28s ${YELLOW}%-38s${NC} ${GREEN}%s${NC}\n" "$DEPLOY" "$CUR" "$NEW_IMG"
  done

  echo ""

  if [[ ${#PLAN_IMAGE[@]} -eq 0 ]]; then
    echo -e "${YELLOW}Tidak ada deployment yang perlu / siap di-update ke tag ${NEW_TAG}.${NC}"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN] Tidak ada yang diubah.${NC}"
    return
  fi

  echo -ne "Lanjutkan? (y/N): "
  read -r CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Dibatalkan."
    exit 0
  fi

  # ── Simpan snapshot sebelum update ──────────────────────────
  local TS; TS=$(date +%Y%m%d_%H%M%S)
  local SNAP_FILE="${SNAPSHOT_DIR}/snapshot_${NAMESPACE}_${TS}.env"

  {
    echo "TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "NAMESPACE=${NAMESPACE}"
    echo "NEW_TAG=${NEW_TAG}"
    for DEPLOY in "${!PLAN_OLD_IMAGE[@]}"; do
      echo "DEPLOY_${DEPLOY}__container=${PLAN_CONTAINER[$DEPLOY]}"
      echo "DEPLOY_${DEPLOY}__old_image=${PLAN_OLD_IMAGE[$DEPLOY]}"
      echo "DEPLOY_${DEPLOY}__new_image=${PLAN_IMAGE[$DEPLOY]}"
    done
  } > "$SNAP_FILE"

  echo -e "${GREEN}✓ Snapshot disimpan:${NC} $SNAP_FILE"
  echo ""

  # ── Eksekusi update ─────────────────────────────────────────
  local SUCCESS=() FAILED=()

  for DEPLOY in "${DEPLOYMENTS[@]}"; do
    if [[ -z "${PLAN_IMAGE[$DEPLOY]+x}" ]]; then
      FAILED+=("$DEPLOY")
      continue
    fi

    echo -ne "  Updating ${BOLD}${DEPLOY}${NC} ... "
    if kubectl set image deployment/"$DEPLOY" \
         "${PLAN_CONTAINER[$DEPLOY]}"="${PLAN_IMAGE[$DEPLOY]}" \
         -n "$NAMESPACE" &>/dev/null; then
      echo -e "${GREEN}✓${NC} ${PLAN_IMAGE[$DEPLOY]}"
      SUCCESS+=("$DEPLOY")
    else
      echo -e "${RED}✗ gagal${NC}"
      FAILED+=("$DEPLOY")
    fi
  done

  # ── Tunggu rollout & deteksi gagal ──────────────────────────
  local ROLLOUT_FAILED=()

  if [[ "$DO_WAIT" == "true" || "$AUTO_ROLLBACK" == "true" ]]; then
    echo ""
    echo -e "${BOLD}Menunggu rollout...${NC}"
    for DEPLOY in "${SUCCESS[@]}"; do
      echo -ne "  ${DEPLOY} ... "
      if kubectl rollout status deployment/"$DEPLOY" \
           -n "$NAMESPACE" --timeout=120s &>/dev/null; then
        echo -e "${GREEN}ready${NC}"
      else
        echo -e "${RED}timeout / gagal${NC}"
        ROLLOUT_FAILED+=("$DEPLOY")
      fi
    done
  fi

  # ── Auto-rollback jika ada yang gagal ───────────────────────
  if [[ "$AUTO_ROLLBACK" == "true" && ${#ROLLOUT_FAILED[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}${BOLD}⚠ Auto-rollback dipicu untuk: ${ROLLOUT_FAILED[*]}${NC}"
    for DEPLOY in "${ROLLOUT_FAILED[@]}"; do
      echo -ne "  Rolling back ${BOLD}${DEPLOY}${NC} ... "
      local OLD_IMG="${PLAN_OLD_IMAGE[$DEPLOY]}"
      local CTR="${PLAN_CONTAINER[$DEPLOY]}"
      if kubectl set image deployment/"$DEPLOY" \
           "$CTR"="$OLD_IMG" -n "$NAMESPACE" &>/dev/null; then
        echo -e "${GREEN}✓ kembali ke ${OLD_IMG}${NC}"
      else
        echo -e "${RED}✗ auto-rollback gagal! cek manual.${NC}"
      fi
    done
  fi

  # ── Ringkasan ────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}Ringkasan:${NC}"
  echo -e "  ${GREEN}Update berhasil  : ${#SUCCESS[@]}${NC}"
  echo -e "  ${RED}Update gagal     : ${#FAILED[@]}${NC}"
  if [[ ${#ROLLOUT_FAILED[@]} -gt 0 ]]; then
    echo -e "  ${RED}Rollout gagal    : ${#ROLLOUT_FAILED[@]} (auto-rollback: $AUTO_ROLLBACK)${NC}"
  fi
  echo ""
  echo -e "  Untuk rollback manual: ${CYAN}$0 rollback -n $NAMESPACE -s $SNAP_FILE${NC}"
}

# ════════════════════════════════════════════════════════════════
# MODE: ROLLBACK
# ════════════════════════════════════════════════════════════════

cmd_rollback() {
  local NAMESPACE="default" SNAP_FILE=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      -n) NAMESPACE="$2"; shift 2 ;;
      -s) SNAP_FILE="$2"; shift 2 ;;
      -h|--help) rollback_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; rollback_help ;;
    esac
  done

  # Pakai snapshot terbaru kalau tidak ditentukan
  if [[ -z "$SNAP_FILE" ]]; then
    SNAP_FILE=$(latest_snapshot)
    if [[ -z "$SNAP_FILE" ]]; then
      echo -e "${RED}Tidak ada snapshot ditemukan di ${SNAPSHOT_DIR}.${NC}"
      exit 1
    fi
    echo -e "${CYAN}Menggunakan snapshot terbaru: $(basename "$SNAP_FILE")${NC}"
  fi

  if [[ ! -f "$SNAP_FILE" ]]; then
    echo -e "${RED}Snapshot tidak ditemukan: $SNAP_FILE${NC}"
    exit 1
  fi

  # ── Baca snapshot ────────────────────────────────────────────
  local SNAP_NS; SNAP_NS=$(grep '^NAMESPACE=' "$SNAP_FILE" | cut -d= -f2 || true)
  local SNAP_TS; SNAP_TS=$(grep '^TIMESTAMP=' "$SNAP_FILE" | cut -d= -f2 || true)
  local SNAP_TAG; SNAP_TAG=$(grep '^NEW_TAG=' "$SNAP_FILE" | cut -d= -f2 || true)

  # Ambil semua deployment dari snapshot
  mapfile -t DEPLOYS < <(grep '^DEPLOY_' "$SNAP_FILE" | grep '__old_image=' \
    | sed 's/^DEPLOY_//;s/__old_image=.*//' | sort -u || true)

  echo ""
  echo -e "${BOLD}Rollback dari snapshot:${NC}"
  echo -e "  Dibuat    : ${CYAN}${SNAP_TS}${NC}"
  echo -e "  Namespace : ${CYAN}${SNAP_NS}${NC}"
  echo -e "  Tag saat update : ${CYAN}${SNAP_TAG}${NC}"
  echo ""
  printf "  %-28s %-38s %s\n" "DEPLOYMENT" "IMAGE SEKARANG" "ROLLBACK KE"
  printf "  %-28s %-38s %s\n" "----------" "--------------" "-----------"

  declare -A RB_CTR RB_OLD

  for DEPLOY in "${DEPLOYS[@]}"; do
    local OLD_IMG; OLD_IMG=$(grep "^DEPLOY_${DEPLOY}__old_image=" "$SNAP_FILE" | cut -d= -f2)
    local CTR; CTR=$(grep "^DEPLOY_${DEPLOY}__container=" "$SNAP_FILE" | cut -d= -f2)
    local CUR; CUR=$(get_current_image "$DEPLOY" "$SNAP_NS")
    RB_CTR["$DEPLOY"]="$CTR"
    RB_OLD["$DEPLOY"]="$OLD_IMG"
    printf "  %-28s ${YELLOW}%-38s${NC} ${GREEN}%s${NC}\n" "$DEPLOY" "${CUR:-tidak ditemukan}" "$OLD_IMG"
  done

  echo ""
  read -rp "Jalankan rollback? (y/N): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Dibatalkan."
    exit 0
  fi

  echo ""
  local RB_SUCCESS=() RB_FAILED=()

  for DEPLOY in "${DEPLOYS[@]}"; do
    echo -ne "  Rolling back ${BOLD}${DEPLOY}${NC} ... "
    if kubectl set image deployment/"$DEPLOY" \
         "${RB_CTR[$DEPLOY]}"="${RB_OLD[$DEPLOY]}" \
         -n "$SNAP_NS" &>/dev/null; then
      echo -e "${GREEN}✓ ${RB_OLD[$DEPLOY]}${NC}"
      RB_SUCCESS+=("$DEPLOY")
    else
      echo -e "${RED}✗ gagal${NC}"
      RB_FAILED+=("$DEPLOY")
    fi
  done

  echo ""
  echo -e "${BOLD}Ringkasan rollback:${NC}"
  echo -e "  ${GREEN}Berhasil : ${#RB_SUCCESS[@]}${NC}"
  echo -e "  ${RED}Gagal    : ${#RB_FAILED[@]}${NC}"
  if [[ ${#RB_FAILED[@]} -gt 0 ]]; then
    printf "    ${RED}- %s${NC}\n" "${RB_FAILED[@]}"
  fi

  if [[ ${#RB_SUCCESS[@]} -gt 0 ]]; then
    echo ""
    read -rp "Tunggu rollout rollback selesai? (y/N): " WAIT
    if [[ "$WAIT" == "y" || "$WAIT" == "Y" ]]; then
      for DEPLOY in "${RB_SUCCESS[@]}"; do
        echo -ne "  Menunggu ${BOLD}$DEPLOY${NC} ... "
        kubectl rollout status deployment/"$DEPLOY" \
          -n "$SNAP_NS" --timeout=120s &>/dev/null \
          && echo -e "${GREEN}ready${NC}" \
          || echo -e "${YELLOW}timeout${NC}"
      done
    fi
  fi
}

# ════════════════════════════════════════════════════════════════
# MODE: SCALE  (scale deployment dari daftar atau nama)
# ════════════════════════════════════════════════════════════════

cmd_scale() {
  local NAMESPACE="default" DEPLOY="" REPLICAS="" DEPLOY_FILE="" SCALE_ALL="false"

  while [[ $# -gt 0 ]]; do
    case $1 in
      -n) NAMESPACE="$2"; shift 2 ;;
      -d) DEPLOY="$2"; shift 2 ;;
      -r) REPLICAS="$2"; shift 2 ;;
      -f) DEPLOY_FILE="$2"; shift 2 ;;
      -a|--all) SCALE_ALL="true"; shift ;;
      -h|--help) scale_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; scale_help ;;
    esac
  done

  # Case 1: Batch scale dari --all (-a)
  if [[ "$SCALE_ALL" == "true" ]]; then
    echo -e "${CYAN}Mengambil semua deployment di namespace '${NAMESPACE}'...${NC}"
    local DEPLOYMENTS=()
    mapfile -t DEPLOYMENTS < <(kubectl get deployments -n "$NAMESPACE" \
      -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' | grep -v '^\s*$' || true)

    if [[ ${#DEPLOYMENTS[@]} -eq 0 || -z "${DEPLOYMENTS[0]:-}" ]]; then
      echo -e "${YELLOW}Tidak ada deployment ditemukan di namespace '${NAMESPACE}'.${NC}"
      return 0
    fi

    if [[ -z "$REPLICAS" ]]; then
      echo -ne "Masukkan jumlah replika baru untuk SEMUA (${#DEPLOYMENTS[@]}) deployment: "
      read -r REPLICAS
    fi

    if ! [[ "$REPLICAS" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}Error: jumlah replika harus berupa angka non-negatif.${NC}"
      exit 1
    fi

    echo ""
    echo -e "${BOLD}Pratinjau batch scale (SEMUA DEPLOYMENT)${NC}"
    echo -e "  Namespace      : ${CYAN}${NAMESPACE}${NC}"
    echo -e "  Jumlah replika : ${GREEN}${REPLICAS}${NC}"
    echo -e "  Daftar deployment (${#DEPLOYMENTS[@]}):"
    for d in "${DEPLOYMENTS[@]}"; do
      local cur_rep; cur_rep=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      echo -e "    - ${CYAN}${d}${NC} (replika saat ini: ${YELLOW}${cur_rep}${NC} → ${GREEN}${REPLICAS}${NC})"
    done
    echo ""
    echo -ne "Lanjutkan? (y/N): "
    read -r CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      echo "Dibatalkan."
      exit 0
    fi

    echo ""
    local SUCCESS=() FAILED=()

    for d in "${DEPLOYMENTS[@]}"; do
      echo -ne "  Scaling ${BOLD}${d}${NC} ... "
      if kubectl scale deployment "$d" -n "$NAMESPACE" --replicas="$REPLICAS" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
        SUCCESS+=("$d")
      else
        echo -e "${RED}✗ gagal${NC}"
        FAILED+=("$d")
      fi
    done

    echo ""
    echo -e "${BOLD}Ringkasan batch scale:${NC}"
    echo -e "  ${GREEN}Berhasil : ${#SUCCESS[@]}${NC}"
    echo -e "  ${RED}Gagal    : ${#FAILED[@]}${NC}"
    return 0
  fi

  # Case 2: Batch scale dari file (-f)
  if [[ -n "$DEPLOY_FILE" ]]; then
    if [[ ! -f "$DEPLOY_FILE" ]]; then
      echo -e "${RED}Error: file '$DEPLOY_FILE' tidak ditemukan.${NC}"
      exit 1
    fi
    local DEPLOYMENTS=()
    mapfile -t DEPLOYMENTS < <(grep -v '^\s*#' "$DEPLOY_FILE" | grep -v '^\s*$' | tr -d '\r' || true)

    if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
      echo -e "${YELLOW}Tidak ada deployment ditemukan di file '$DEPLOY_FILE'.${NC}"
      return 0
    fi

    if [[ -z "$REPLICAS" ]]; then
      echo -ne "Masukkan jumlah replika baru untuk ${#DEPLOYMENTS[@]} deployment di file: "
      read -r REPLICAS
    fi

    if ! [[ "$REPLICAS" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}Error: jumlah replika harus berupa angka non-negatif.${NC}"
      exit 1
    fi

    echo ""
    echo -e "${BOLD}Pratinjau batch scale${NC}"
    echo -e "  Namespace      : ${CYAN}${NAMESPACE}${NC}"
    echo -e "  File           : ${CYAN}${DEPLOY_FILE}${NC}"
    echo -e "  Jumlah replika : ${GREEN}${REPLICAS}${NC}"
    echo -e "  Daftar deployment:"
    for d in "${DEPLOYMENTS[@]}"; do
      local cur_rep; cur_rep=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      echo -e "    - ${CYAN}${d}${NC} (replika saat ini: ${YELLOW}${cur_rep}${NC} → ${GREEN}${REPLICAS}${NC})"
    done
    echo ""
    echo -ne "Lanjutkan? (y/N): "
    read -r CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      echo "Dibatalkan."
      exit 0
    fi

    echo ""
    local SUCCESS=() FAILED=()

    for d in "${DEPLOYMENTS[@]}"; do
      echo -ne "  Scaling ${BOLD}${d}${NC} ... "
      if kubectl scale deployment "$d" -n "$NAMESPACE" --replicas="$REPLICAS" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
        SUCCESS+=("$d")
      else
        echo -e "${RED}✗ gagal${NC}"
        FAILED+=("$d")
      fi
    done

    echo ""
    echo -e "${BOLD}Ringkasan batch scale:${NC}"
    echo -e "  ${GREEN}Berhasil : ${#SUCCESS[@]}${NC}"
    echo -e "  ${RED}Gagal    : ${#FAILED[@]}${NC}"
    return 0
  fi

  # Case 3: Jika deployment (-d) tidak ditentukan, tampilkan daftar deployment di namespace
  if [[ -z "$DEPLOY" ]]; then
    echo -e "${CYAN}Mengambil daftar deployment di namespace '${NAMESPACE}'...${NC}"
    local DEPLOYMENTS=()
    mapfile -t DEPLOYMENTS < <(kubectl get deployments -n "$NAMESPACE" \
      -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' | grep -v '^\s*$' || true)

    if [[ ${#DEPLOYMENTS[@]} -eq 0 || -z "${DEPLOYMENTS[0]:-}" ]]; then
      echo -e "${YELLOW}Tidak ada deployment ditemukan di namespace '${NAMESPACE}'.${NC}"
      return 0
    fi

    echo ""
    echo -e "${BOLD}Daftar Deployment di namespace '${CYAN}${NAMESPACE}${NC}${BOLD}':${NC}"
    echo ""
    printf "  %-3s %-35s %s\n" "NO" "DEPLOYMENT" "REPLIKA SAAT INI"
    printf "  %-3s %-35s %s\n" "---" "-----------------------------------" "----------------"
    printf "  %-3s ${CYAN}%-35s${NC}\n" "0" "-- SEMUA DEPLOYMENT (ALL) --"

    local i=1
    for d in "${DEPLOYMENTS[@]}"; do
      local cur_rep; cur_rep=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      printf "  %-3s %-35s %s\n" "$i" "$d" "$cur_rep"
      ((i++))
    done

    echo ""
    echo -ne "Pilih nomor deployment yang ingin di-scale (0 untuk SEMUA, 1-${#DEPLOYMENTS[@]}): "
    read -r CHOICE

    if [[ "$CHOICE" == "0" || "$CHOICE" == "all" || "$CHOICE" == "ALL" ]]; then
      SCALE_ALL="true"
    else
      if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#DEPLOYMENTS[@]}" ]; then
        echo -e "${RED}Pilihan tidak valid.${NC}"
        exit 1
      fi
      DEPLOY="${DEPLOYMENTS[$((CHOICE-1))]}"
    fi
  fi

  # Case 4: Scaling single deployment
  local current_rep; current_rep=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ -z "$REPLICAS" ]]; then
    echo ""
    echo -e "Deployment: ${CYAN}${DEPLOY}${NC} (Replika saat ini: ${YELLOW}${current_rep}${NC})"
    echo -ne "Masukkan jumlah replika baru: "
    read -r REPLICAS
  fi

  if ! [[ "$REPLICAS" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: jumlah replika harus berupa angka non-negatif.${NC}"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}Scale deployment${NC}"
  echo -e "  Namespace        : ${CYAN}${NAMESPACE}${NC}"
  echo -e "  Deployment       : ${CYAN}${DEPLOY}${NC}"
  echo -e "  Replika saat ini : ${YELLOW}${current_rep}${NC}"
  echo -e "  Replika baru     : ${GREEN}${REPLICAS}${NC}"
  echo ""
  echo -ne "Lanjutkan? (y/N): "
  read -r CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Dibatalkan."
    exit 0
  fi

  echo ""
  echo -ne "  Scaling deployment ${BOLD}${DEPLOY}${NC} ke ${GREEN}${REPLICAS}${NC} replika ... "
  if kubectl scale deployment "$DEPLOY" -n "$NAMESPACE" --replicas="$REPLICAS" &>/dev/null; then
    echo -e "${GREEN}✓ berhasil${NC}"
  else
    echo -e "${RED}✗ gagal${NC}"
    exit 1
  fi
}

# ════════════════════════════════════════════════════════════════
# MODE: CLONE  (clone namespace / project beserta seluruh resource)
# ════════════════════════════════════════════════════════════════

cmd_clone() {
  local SRC_NS="" NEW_NS="" WITH_PVC_DATA=false SKIP_PVC=false PVC_FILTER="" PVC_RENAME_MAP="" ONLY_RESOURCE=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      -s) SRC_NS="$2"; shift 2 ;;
      -n) NEW_NS="$2"; shift 2 ;;
      -v) PVC_FILTER="$2"; shift 2 ;;
      -r) PVC_RENAME_MAP="$2"; shift 2 ;;
      -p) WITH_PVC_DATA=true; shift ;;
      -x) SKIP_PVC=true; shift ;;
      --only|--type) ONLY_RESOURCE="$2"; shift 2 ;;
      -h|--help) clone_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; clone_help ;;
    esac
  done

  if [[ -z "$SRC_NS" || -z "$NEW_NS" ]]; then
    echo -e "${RED}Error: -s <source-namespace> dan -n <new-namespace> wajib diisi.${NC}"
    usage
  fi

  if [[ "$SRC_NS" == "$NEW_NS" ]]; then
    echo -e "${RED}Error: Source dan new namespace tidak boleh sama.${NC}"
    exit 1
  fi

  local KUBE_CMD="kubectl"
  if command -v oc >/dev/null 2>&1; then
    KUBE_CMD="oc"
  fi
  echo -e "${CYAN}Menggunakan CLI: ${KUBE_CMD}${NC}"

  # ── Validasi Keberadaan Source Namespace ────────────────────
  if ! $KUBE_CMD get namespace "$SRC_NS" &>/dev/null && ! $KUBE_CMD get project "$SRC_NS" &>/dev/null; then
    echo -e "${RED}Error: Source namespace/project '${SRC_NS}' tidak ditemukan atau tidak dapat diakses di cluster.${NC}"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}Konfirmasi Clone Namespace / Resource:${NC}"
  echo -e "  Source Namespace : ${CYAN}${SRC_NS}${NC}"
  echo -e "  Target Namespace : ${CYAN}${NEW_NS}${NC}"
  [[ -n "$ONLY_RESOURCE" ]] && echo -e "  Filter Resource  : ${CYAN}${ONLY_RESOURCE}${NC}"
  echo ""
  read -rp "Lanjutkan duplikasi (clone) resource ke namespace '${NEW_NS}'? (y/N): " CONFIRM
  CONFIRM=$(echo "$CONFIRM" | tr -d '\r')

  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Dibatalkan."
    exit 0
  fi

  local WORKDIR
  WORKDIR="$(mktemp -d "clone-${SRC_NS}-to-${NEW_NS}.XXXXXX")"
  echo -e "${CYAN}Working directory: ${WORKDIR}${NC}"

  local HAS_YQ=false HAS_PY=false
  if command -v yq >/dev/null 2>&1; then
    HAS_YQ=true
    echo "yq ditemukan - menggunakan yq untuk pembersihan YAML."
  elif command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    HAS_PY=true
    echo "python3+PyYAML ditemukan - menggunakan Python untuk pembersihan YAML."
  else
    echo "yq atau python3+PyYAML tidak ditemukan - menggunakan fallback awk/sed."
  fi

  local EXCLUDED_NAMES="kube-root-ca.crt openshift-service-ca.crt"

  _clone_has_objects() {
    local file="$1"
    [[ ! -s "$file" ]] && return 1
    if $HAS_YQ; then
      local count
      count=$(yq eval 'if .kind == "List" then (.items // []) | length elif .items then (.items // []) | length else 1 end' "$file" 2>/dev/null || echo 0)
      [[ "$count" -gt 0 ]] && return 0 || return 1
    elif $HAS_PY; then
      python3 - "$file" <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        docs = list(yaml.safe_load_all(f))
    total = 0
    for doc in docs:
        if not doc: continue
        if isinstance(doc, dict):
            if doc.get("kind") == "List" or "items" in doc:
                total += len(doc.get("items") or [])
            else: total += 1
        elif isinstance(doc, list): total += len(doc)
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

  _clone_clean_yaml() {
    local inp="$1" outp="$2"
    if $HAS_YQ; then
      local excl_jq_array; excl_jq_array=$(printf '"%s",' $EXCLUDED_NAMES); excl_jq_array="[${excl_jq_array%,}]"
      yq eval "
        (${excl_jq_array}) as \$excluded |
        del(.items[] | select((.metadata.ownerReferences // []) | length > 0)) |
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
      " "$inp" > "$outp.tmp"
    elif $HAS_PY; then
      SRC_NS="$SRC_NS" NEW_NS="$NEW_NS" EXCLUDED_NAMES="$EXCLUDED_NAMES" python3 - "$inp" "$outp.tmp" <<'PYEOF'
import os, sys, yaml
inp, outp = sys.argv[1], sys.argv[2]
src_ns = os.environ["SRC_NS"]
excluded = set(os.environ["EXCLUDED_NAMES"].split())
with open(inp) as f: doc = yaml.safe_load(f) or {}
items = doc.get("items", []) or []
kept = []
for item in items:
    meta = item.get("metadata", {}) or {}
    name = meta.get("name", "")
    kind = item.get("kind", "?")
    if meta.get("ownerReferences") or name in excluded: continue
    for field in ("uid", "resourceVersion", "creationTimestamp", "generation", "selfLink", "managedFields"):
        meta.pop(field, None)
    item["metadata"] = meta
    item.pop("status", None)
    if kind == "Service":
        spec = item.get("spec", {}) or {}
        if spec.get("clusterIP") != "None":
            spec.pop("clusterIP", None); spec.pop("clusterIPs", None)
        spec.pop("healthCheckNodePort", None)
        item["spec"] = spec
    if kind == "ServiceAccount":
        item["secrets"] = [s for s in (item.get("secrets", []) or []) if not ("-token-" in s.get("name", "") or "-dockercfg-" in s.get("name", ""))]
        if not item["secrets"]: item.pop("secrets", None)
        item["imagePullSecrets"] = [s for s in (item.get("imagePullSecrets", []) or []) if not ("-dockercfg-" in s.get("name", ""))]
        if not item["imagePullSecrets"]: item.pop("imagePullSecrets", None)
    kept.append(item)
doc["items"] = kept
with open(outp, "w") as f: yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
    else
      local excl_pattern; excl_pattern=$(echo "$EXCLUDED_NAMES" | sed 's/\./\\./g' | sed 's/ /|/g')
      awk -v excl="$excl_pattern" '
        function flush() { if (buf != "" && !skip) printf "%s", buf; buf=""; skip=0 }
        /^items:/ { print; in_items=1; next }
        in_items && /^[a-zA-Z]/ { flush(); in_items=0; print; next }
        in_items && /^- / { flush(); buf = $0 "\n"; next }
        in_items {
          buf = buf $0 "\n"
          if ($0 ~ /ownerReferences:/) skip=1
          if (excl != "" && $0 ~ ("name: (" excl ")$")) skip=1
          next
        }
        { print }
        END { if (in_items) flush() }
      ' "$inp" | sed -e '/resourceVersion:/d' -e '/[[:space:]]uid:/d' -e '/selfLink:/d' \
                    -e '/creationTimestamp:/d' -e '/generation:/d' -e '/[[:space:]]*clusterIPs:/d' \
                    -e '/[[:space:]]*clusterIP:[[:space:]]*[0-9]/d' -e '/[[:space:]]*- [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/d' \
                    -e '/[[:space:]]*healthCheckNodePort:/d' -e '/[[:space:]]*- name:.*-token-/d' \
                    -e '/[[:space:]]*- name:.*-dockercfg-/d' > "$outp.tmp"
    fi
    sed -e "s/namespace: ${SRC_NS}$/namespace: ${NEW_NS}/" \
        -e "s#${SRC_NS}\.apps#${NEW_NS}.apps#g" \
        "$outp.tmp" > "$outp"
    rm -f "$outp.tmp"
  }

  _clone_strip_pvc_binding() {
    local inp="$1" outp="$2"
    if $HAS_YQ; then
      yq eval 'del(.items[].spec.volumeName) | del(.items[].status) | del(.items[].metadata.annotations."pv.kubernetes.io/bind-completed") | del(.items[].metadata.annotations."pv.kubernetes.io/bound-by-controller")' "$inp" > "$outp"
    elif $HAS_PY; then
      python3 - "$inp" "$outp" <<'PYEOF'
import sys, yaml
inp, outp = sys.argv[1], sys.argv[2]
with open(inp) as f: doc = yaml.safe_load(f) or {}
for item in doc.get("items", []) or []:
    item.get("spec", {}).pop("volumeName", None)
    item.pop("status", None)
    ann = item.get("metadata", {}).get("annotations", {}) or {}
    ann.pop("pv.kubernetes.io/bind-completed", None)
    ann.pop("pv.kubernetes.io/bound-by-controller", None)
    if "metadata" in item: item["metadata"]["annotations"] = ann
with open(outp, "w") as f: yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
    else
      sed -e '/volumeName:/d' -e '/pv.kubernetes.io\/bind-completed/d' -e '/pv.kubernetes.io\/bound-by-controller/d' "$inp" > "$outp"
    fi
  }

  _clone_filter_existing_pvcs() {
    local target_file="$1"
    local existing
    existing=$($KUBE_CMD get pvc -n "$NEW_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    [[ -z "$existing" ]] && return 0
    echo "   Memeriksa PVC yang sudah ada di $NEW_NS..."
    local tmp="${target_file}.filtered"
    if $HAS_YQ; then
      local arr; arr=$(printf '"%s",' $existing); arr="[${arr%,}]"
      yq eval "del(.items[] | select(.metadata.name as \$n | (${arr}) | contains([\$n])))" "$target_file" > "$tmp"
    elif $HAS_PY; then
      EXISTING_PVCS="$existing" python3 - "$target_file" "$tmp" <<'PYEOF'
import os, sys, yaml
existing = set(os.environ["EXISTING_PVCS"].split())
inp, outp = sys.argv[1], sys.argv[2]
with open(inp) as f: doc = yaml.safe_load(f) or {}
doc["items"] = [i for i in (doc.get("items", []) or []) if i.get("metadata", {}).get("name", "") not in existing]
with open(outp, "w") as f: yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
    else
      local excl_pattern; excl_pattern=$(echo "$existing" | sed 's/\./\\./g' | sed 's/ /|/g')
      awk -v excl="$excl_pattern" '
        function flush() { if (buf != "" && !skip) printf "%s", buf; buf=""; skip=0 }
        /^items:/ { print; in_items=1; next }
        in_items && /^[a-zA-Z]/ { flush(); in_items=0; print; next }
        in_items && /^- / { flush(); buf = $0 "\n"; next }
        in_items { buf = buf $0 "\n"; if (excl != "" && $0 ~ ("name: (" excl ")$")) skip=1; next }
        { print }
        END { if (in_items) flush() }
      ' "$target_file" > "$tmp"
    fi
    mv "$tmp" "$target_file"
  }

  # ── 0. Pastikan target namespace / project ada ─────────────
  if ! $KUBE_CMD get namespace "$NEW_NS" >/dev/null 2>&1 && ! $KUBE_CMD get project "$NEW_NS" >/dev/null 2>&1; then
    echo -e ">> Membuat namespace/project ${CYAN}${NEW_NS}${NC}"
    if [[ "$KUBE_CMD" == "oc" ]]; then
      oc new-project "$NEW_NS" >/dev/null || oc create namespace "$NEW_NS" >/dev/null
    else
      kubectl create namespace "$NEW_NS" >/dev/null
    fi
  else
    echo -e ">> Namespace/Project ${CYAN}${NEW_NS}${NC} sudah ada, menggunakan namespace tersebut."
  fi

  # ── 1. Export + bersihkan resource umum ─────────────────────
  local ALL_RESOURCES="deployment service configmap rolebinding role serviceaccount route networkpolicy resourcequota limitrange horizontalpodautoscaler"
  local RESOURCES="$ALL_RESOURCES"
  if [[ -n "$ONLY_RESOURCE" ]]; then
    RESOURCES=$(echo "$ONLY_RESOURCE" | tr ',' ' ')
  fi

  for res in $RESOURCES; do
    [[ "$res" == "secret" || "$res" == "pvc" ]] && continue
    local count; count=$($KUBE_CMD get "$res" -n "$SRC_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    [[ "$count" == "0" ]] && continue
    echo -e ">> Exporting $res ($count ditemukan)"
    $KUBE_CMD get "$res" -n "$SRC_NS" -o yaml > "$WORKDIR/raw-$res.yaml" 2>/dev/null || true
    _clone_clean_yaml "$WORKDIR/raw-$res.yaml" "$WORKDIR/cleaned-$res.yaml"
  done

  # ── 2. Secrets (skip auto-generated service-account-token) ──
  local sec_count; sec_count=$($KUBE_CMD get secret -n "$SRC_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  if [[ "$sec_count" != "0" ]]; then
    echo ">> Exporting secrets (excluding service-account-token type)"
    $KUBE_CMD get secret -n "$SRC_NS" -o yaml > "$WORKDIR/raw-secret.yaml" 2>/dev/null || true
    if $HAS_YQ; then
      yq eval 'del(.items[] | select(.type == "kubernetes.io/service-account-token"))' "$WORKDIR/raw-secret.yaml" > "$WORKDIR/raw-secret-filtered.yaml"
    elif $HAS_PY; then
      python3 - "$WORKDIR/raw-secret.yaml" "$WORKDIR/raw-secret-filtered.yaml" <<'PYEOF'
import sys, yaml
inp, outp = sys.argv[1], sys.argv[2]
with open(inp) as f: doc = yaml.safe_load(f) or {}
doc["items"] = [i for i in (doc.get("items", []) or []) if i.get("type") != "kubernetes.io/service-account-token"]
with open(outp, "w") as f: yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
    else
      awk '
        function flush() { if (buf != "" && !skip) printf "%s", buf; buf=""; skip=0 }
        /^items:/ { print; in_items=1; next }
        in_items && /^[a-zA-Z]/ { flush(); in_items=0; print; next }
        in_items && /^- / { flush(); buf = $0 "\n"; next }
        in_items { buf = buf $0 "\n"; if ($0 ~ /type: kubernetes\.io\/service-account-token/) skip=1; next }
        { print }
        END { if (in_items) flush() }
      ' "$WORKDIR/raw-secret.yaml" > "$WORKDIR/raw-secret-filtered.yaml"
    fi
    _clone_clean_yaml "$WORKDIR/raw-secret-filtered.yaml" "$WORKDIR/cleaned-secret.yaml"
  fi

  # ── 3. PVCs ──────────────────────────────────────────────────
  if $SKIP_PVC; then
    echo ">> -x diaktifkan: skip export dan pembuatan PVC."
  else
    local pvc_count; pvc_count=$($KUBE_CMD get pvc -n "$SRC_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$pvc_count" != "0" ]]; then
      echo ">> Exporting PVCs ($pvc_count ditemukan)"
      $KUBE_CMD get pvc -n "$SRC_NS" -o yaml > "$WORKDIR/raw-pvc.yaml" 2>/dev/null || true
      _clone_strip_pvc_binding "$WORKDIR/raw-pvc.yaml" "$WORKDIR/raw-pvc-stripped.yaml"
      _clone_clean_yaml "$WORKDIR/raw-pvc-stripped.yaml" "$WORKDIR/cleaned-pvc.yaml"
      _clone_filter_existing_pvcs "$WORKDIR/cleaned-pvc.yaml"
    fi
  fi

  # ── 3.5 Rewrite PVC claimNames jika -r ditentukan ───────────
  if [[ -n "$PVC_RENAME_MAP" ]]; then
    echo ">> Renaming PVC claimName references (-r set)"
    local OLD_IFS="$IFS"
    IFS=','
    for pair in $PVC_RENAME_MAP; do
      local old_pvc="${pair%%:*}"
      local new_pvc="${pair#*:}"
      echo "   Rewriting claimName: $old_pvc -> $new_pvc"
      for f in "$WORKDIR"/cleaned-*.yaml; do
        [[ -f "$f" ]] || continue
        sed -e "s/claimName: ${old_pvc}$/claimName: ${new_pvc}/g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      done
    done
    IFS="$OLD_IFS"
  fi

  # ── 4. Apply ────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}Menerapkan resource ke namespace '${CYAN}${NEW_NS}${NC}${BOLD}'...${NC}"

  if [[ -f "$WORKDIR/cleaned-pvc.yaml" ]]; then
    if _clone_has_objects "$WORKDIR/cleaned-pvc.yaml"; then
      echo ">> Applying PVCs"
      $KUBE_CMD apply -f "$WORKDIR/cleaned-pvc.yaml" -n "$NEW_NS"
      sleep 3
    fi
  fi

  for f in "$WORKDIR"/cleaned-*.yaml; do
    [[ "$f" == "$WORKDIR/cleaned-pvc.yaml" ]] && continue
    [[ -e "$f" ]] || continue
    if ! _clone_has_objects "$f"; then
      continue
    fi
    echo ">> Applying $(basename "$f")"
    $KUBE_CMD apply -f "$f" -n "$NEW_NS"
  done

  echo ""
  echo -e "${GREEN}✓ Clone selesai!${NC} File manifest tersimpan di: ${CYAN}${WORKDIR}${NC}"
  echo -e "Untuk memverifikasi hasil clone:"
  echo -e "  ${CYAN}${KUBE_CMD} get all,pvc -n ${NEW_NS}${NC}"
}

# ════════════════════════════════════════════════════════════════
# MODE: CHPASSWD  (ganti password user OpenShift HTPasswd)
# ════════════════════════════════════════════════════════════════

cmd_chpasswd() {
  local USERNAME="" SECRET_NAME="htpass-secret" SECRET_NS="openshift-config" IDP_NAME="htpasswd_provider"

  while [[ $# -gt 0 ]]; do
    case $1 in
      -u) USERNAME="$2"; shift 2 ;;
      -s) SECRET_NAME="$2"; shift 2 ;;
      --secret-ns) SECRET_NS="$2"; shift 2 ;;
      --idp) IDP_NAME="$2"; shift 2 ;;
      -h|--help) chpasswd_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; chpasswd_help ;;
    esac
  done

  # ── Pre-flight: hanya mendukung oc ──────────────────────────
  if ! command -v oc >/dev/null 2>&1; then
    echo -e "${RED}Error: Mode chpasswd memerlukan 'oc' CLI (OpenShift). 'oc' tidak ditemukan di PATH.${NC}"
    exit 1
  fi

  if ! command -v htpasswd >/dev/null 2>&1; then
    echo -e "${RED}Error: 'htpasswd' tidak ditemukan di PATH.${NC}"
    echo -e "${YELLOW}Install via: yum install httpd-tools  /  apt install apache2-utils${NC}"
    exit 1
  fi

  # ── Ambil Secret htpasswd dari cluster ──────────────────────
  echo -e "${CYAN}Mengambil Secret '${SECRET_NAME}' dari namespace '${SECRET_NS}'...${NC}"
  local HTPASSWD_DATA
  HTPASSWD_DATA=$(oc get secret "$SECRET_NAME" -n "$SECRET_NS" -o jsonpath='{.data.htpasswd}' 2>/dev/null || true)

  if [[ -z "$HTPASSWD_DATA" ]]; then
    echo -e "${RED}Error: Secret '${SECRET_NAME}' tidak ditemukan di namespace '${SECRET_NS}', atau field 'htpasswd' kosong.${NC}"
    echo -e "${YELLOW}Pastikan nama Secret dan namespace sudah benar. Cek dengan:${NC}"
    echo -e "  ${CYAN}oc get secret -n ${SECRET_NS}${NC}"
    exit 1
  fi

  local TMPFILE
  TMPFILE=$(mktemp /tmp/htpasswd.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$TMPFILE'" EXIT

  echo "$HTPASSWD_DATA" | base64 -d > "$TMPFILE"

  # ── Daftar user yang ada ────────────────────────────────────
  local USERS=()  
  mapfile -t USERS < <(awk -F: '{print $1}' "$TMPFILE" | sort | tr -d '\r')

  if [[ ${#USERS[@]} -eq 0 ]]; then
    echo -e "${RED}Error: Tidak ada user ditemukan dalam htpasswd Secret.${NC}"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}User yang terdaftar di HTPasswd (${#USERS[@]} user):${NC}"
  echo -e "${YELLOW}────────────────────────────────────────${NC}"
  local i=1
  for u in "${USERS[@]}"; do
    printf "  ${CYAN}%2d${NC}) %s\n" "$i" "$u"
    ((i++)) || true
  done
  echo -e "${YELLOW}────────────────────────────────────────${NC}"

  # ── Pilih user ──────────────────────────────────────────────
  if [[ -z "$USERNAME" ]]; then
    echo ""
    echo -ne "${BOLD}Pilih nomor user atau ketik username: ${NC}"
    read -r CHOICE
    CHOICE=$(echo "$CHOICE" | tr -d '\r')

    if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
      if [[ "$CHOICE" -ge 1 && "$CHOICE" -le ${#USERS[@]} ]]; then
        USERNAME="${USERS[$((CHOICE-1))]}"
      else
        echo -e "${RED}Error: Nomor tidak valid.${NC}"
        exit 1
      fi
    else
      USERNAME="$CHOICE"
    fi
  fi

  if [[ -z "$USERNAME" ]]; then
    echo -e "${RED}Error: Username tidak boleh kosong.${NC}"
    exit 1
  fi

  # Cek apakah user ada di htpasswd
  local USER_EXISTS=false
  if grep -q "^${USERNAME}:" "$TMPFILE"; then
    USER_EXISTS=true
  fi

  if [[ "$USER_EXISTS" == "false" ]]; then
    echo ""
    echo -e "${YELLOW}⚠ User '${USERNAME}' belum ada di htpasswd.${NC}"
    echo -ne "${BOLD}Apakah ingin membuat user baru? (y/N): ${NC}"
    read -r ADD_CONFIRM
    ADD_CONFIRM=$(echo "$ADD_CONFIRM" | tr -d '\r')
    if [[ "$ADD_CONFIRM" != "y" && "$ADD_CONFIRM" != "Y" ]]; then
      echo "Dibatalkan."
      exit 0
    fi
  fi

  # ── Prompt password ─────────────────────────────────────────
  echo ""
  echo -ne "${BOLD}Masukkan password baru untuk '${USERNAME}': ${NC}"
  read -rs NEW_PASS
  echo ""
  echo -ne "${BOLD}Konfirmasi password baru: ${NC}"
  read -rs CONFIRM_PASS
  echo ""

  if [[ -z "$NEW_PASS" ]]; then
    echo -e "${RED}Error: Password tidak boleh kosong.${NC}"
    exit 1
  fi

  if [[ "$NEW_PASS" != "$CONFIRM_PASS" ]]; then
    echo -e "${RED}Error: Password tidak cocok.${NC}"
    exit 1
  fi

  # ── Update htpasswd file ────────────────────────────────────
  if [[ "$USER_EXISTS" == "true" ]]; then
    htpasswd -bB "$TMPFILE" "$USERNAME" "$NEW_PASS"
    echo -e "${GREEN}✓ Password user '${USERNAME}' berhasil di-update di file lokal.${NC}"
  else
    htpasswd -bB "$TMPFILE" "$USERNAME" "$NEW_PASS"
    echo -e "${GREEN}✓ User '${USERNAME}' berhasil ditambahkan ke file lokal.${NC}"
  fi

  # ── Konfirmasi push ke cluster ──────────────────────────────
  echo ""
  echo -e "${BOLD}Pratinjau perubahan:${NC}"
  if [[ "$USER_EXISTS" == "true" ]]; then
    echo -e "  Action   : ${YELLOW}UPDATE password${NC}"
  else
    echo -e "  Action   : ${GREEN}CREATE user baru${NC}"
  fi
  echo -e "  Username : ${CYAN}${USERNAME}${NC}"
  echo -e "  Secret   : ${CYAN}${SECRET_NAME}${NC} (ns: ${CYAN}${SECRET_NS}${NC})"
  echo -e "  IDP      : ${CYAN}${IDP_NAME}${NC}"
  echo ""
  echo -ne "${BOLD}Terapkan perubahan ke cluster? (y/N): ${NC}"
  read -r APPLY_CONFIRM
  APPLY_CONFIRM=$(echo "$APPLY_CONFIRM" | tr -d '\r')

  if [[ "$APPLY_CONFIRM" != "y" && "$APPLY_CONFIRM" != "Y" ]]; then
    echo "Dibatalkan. Perubahan TIDAK diterapkan ke cluster."
    exit 0
  fi

  # ── Push Secret ke cluster ──────────────────────────────────
  echo ""
  echo -ne "  Meng-update Secret '${SECRET_NAME}' ... "
  if oc create secret generic "$SECRET_NAME" \
       --from-file=htpasswd="$TMPFILE" \
       -n "$SECRET_NS" \
       --dry-run=client -o yaml | oc replace -f - &>/dev/null; then
    echo -e "${GREEN}✓ berhasil${NC}"
  else
    echo -e "${RED}✗ gagal${NC}"
    echo -e "${YELLOW}Tip: Pastikan Anda memiliki akses cluster-admin.${NC}"
    exit 1
  fi

  # ── Restart OAuth pods agar perubahan aktif ─────────────────
  echo -ne "  Restart OAuth pods ... "
  if oc delete pods -l app=oauth-openshift -n openshift-authentication &>/dev/null; then
    echo -e "${GREEN}✓ berhasil${NC}"
  else
    echo -e "${YELLOW}⚠ Gagal restart OAuth pods (mungkin bukan label default). Restart manual mungkin diperlukan.${NC}"
  fi

  echo ""
  echo -e "${GREEN}✓ Selesai!${NC} Password user ${BOLD}${USERNAME}${NC} telah diubah."
  echo -e "${YELLOW}Catatan: Perubahan mungkin memerlukan waktu ~30 detik untuk aktif sepenuhnya.${NC}"
  echo -e "Untuk verifikasi, coba login:"
  echo -e "  ${CYAN}oc login -u ${USERNAME}${NC}"
}

# ════════════════════════════════════════════════════════════════
# MODE: RESOURCES  (set requests & limits CPU/Memory container)
# ════════════════════════════════════════════════════════════════

_set_deployment_resources() {
  local DEPLOY="$1" NAMESPACE="$2" CPU_REQ="$3" MEM_REQ="$4" CPU_LIM="$5" MEM_LIM="$6" CONTAINER_TARGET="$7"

  local CONTAINER="$CONTAINER_TARGET"
  if [[ -z "$CONTAINER" ]]; then
    CONTAINER=$(get_container_name "$DEPLOY" "$NAMESPACE")
  fi

  if [[ -z "$CONTAINER" ]]; then
    echo -e "  Deployment ${BOLD}${DEPLOY}${NC}: ${RED}container tidak ditemukan${NC}"
    return 1
  fi

  local PATCH_JSON=""
  if command -v python3 >/dev/null 2>&1; then
    PATCH_JSON=$(python3 -c "
import json, sys
c, cpu_r, mem_r, cpu_l, mem_l = sys.argv[1:6]
res = {}
req = {}
if cpu_r: req['cpu'] = cpu_r
if mem_r: req['memory'] = mem_r
if req: res['requests'] = req
lim = {}
if cpu_l: lim['cpu'] = cpu_l
if mem_l: lim['memory'] = mem_l
if lim: res['limits'] = lim
doc = {'spec': {'template': {'spec': {'containers': [{'name': c, 'resources': res}]}}}}
print(json.dumps(doc))
" "$CONTAINER" "$CPU_REQ" "$MEM_REQ" "$CPU_LIM" "$MEM_LIM" 2>/dev/null || echo "")
  elif command -v python >/dev/null 2>&1; then
    PATCH_JSON=$(python -c "
import json, sys
c, cpu_r, mem_r, cpu_l, mem_l = sys.argv[1:6]
res = {}
req = {}
if cpu_r: req['cpu'] = cpu_r
if mem_r: req['memory'] = mem_r
if req: res['requests'] = req
lim = {}
if cpu_l: lim['cpu'] = cpu_l
if mem_l: lim['memory'] = mem_l
if lim: res['limits'] = lim
doc = {'spec': {'template': {'spec': {'containers': [{'name': c, 'resources': res}]}}}}
print(json.dumps(doc))
" "$CONTAINER" "$CPU_REQ" "$MEM_REQ" "$CPU_LIM" "$MEM_LIM" 2>/dev/null || echo "")
  fi

  if [[ -z "$PATCH_JSON" ]]; then
    local REQ_PARTS=()
    [[ -n "$CPU_REQ" ]] && REQ_PARTS+=("\"cpu\":\"${CPU_REQ}\"")
    [[ -n "$MEM_REQ" ]] && REQ_PARTS+=("\"memory\":\"${MEM_REQ}\"")

    local LIM_PARTS=()
    [[ -n "$CPU_LIM" ]] && LIM_PARTS+=("\"cpu\":\"${CPU_LIM}\"")
    [[ -n "$MEM_LIM" ]] && LIM_PARTS+=("\"memory\":\"${MEM_LIM}\"")

    local RES_BODY=""
    if [[ ${#REQ_PARTS[@]} -gt 0 ]]; then
      local req_str; req_str=$(IFS=,; echo "${REQ_PARTS[*]}")
      RES_BODY="\"requests\":{${req_str}}"
    fi

    if [[ ${#LIM_PARTS[@]} -gt 0 ]]; then
      local lim_str; lim_str=$(IFS=,; echo "${LIM_PARTS[*]}")
      if [[ -n "$RES_BODY" ]]; then
        RES_BODY="${RES_BODY},\"limits\":{${lim_str}}"
      else
        RES_BODY="\"limits\":{${lim_str}}"
      fi
    fi

    PATCH_JSON="{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${CONTAINER}\",\"resources\":{${RES_BODY}}}}]}}}}"
  fi

  echo -ne "  Resource ${BOLD}${DEPLOY}${NC} (req: CPU ${CPU_REQ:-'same'}, Mem ${MEM_REQ:-'same'}) ... "
  local ERR_MSG
  if ERR_MSG=$(kubectl patch deployment "$DEPLOY" -n "$NAMESPACE" --type=strategic -p "$PATCH_JSON" 2>&1); then
    echo -e "${GREEN}✓ berhasil${NC}"
    return 0
  else
    echo -e "${RED}✗ gagal${NC}"
    local CLEAN_ERR
    CLEAN_ERR=$(echo "$ERR_MSG" | tr '\n' ' ' | sed 's/.*error/Error/' | cut -c1-120 || echo "$ERR_MSG")
    echo -e "    ${YELLOW}Detail error: ${CLEAN_ERR}${NC}"
    return 1
  fi
}

cmd_resources() {
  local NAMESPACE="default" DEPLOY="" DEPLOY_FILE="" ALL_MODE=false
  local CPU_REQ="100m" MEM_REQ="256Mi" CPU_LIM="" MEM_LIM="" CONTAINER=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      -n) NAMESPACE="$2"; shift 2 ;;
      -d) DEPLOY="$2"; shift 2 ;;
      -f) DEPLOY_FILE="$2"; shift 2 ;;
      -a|--all) ALL_MODE=true; shift ;;
      --cpu-req) CPU_REQ="$2"; shift 2 ;;
      --mem-req) MEM_REQ="$2"; shift 2 ;;
      --cpu-lim) CPU_LIM="$2"; shift 2 ;;
      --mem-lim) MEM_LIM="$2"; shift 2 ;;
      -c) CONTAINER="$2"; shift 2 ;;
      -h|--help) resources_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; resources_help ;;
    esac
  done

  local DEPLOYMENTS=()

  if [[ "$ALL_MODE" == "true" ]]; then
    echo -e "${CYAN}Mengambil semua deployment di namespace '${NAMESPACE}'...${NC}"
    mapfile -t DEPLOYMENTS < <(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' || true)
  elif [[ -n "$DEPLOY_FILE" ]]; then
    if [[ ! -f "$DEPLOY_FILE" ]]; then
      echo -e "${RED}Error: File '$DEPLOY_FILE' tidak ditemukan.${NC}"
      exit 1
    fi
    mapfile -t DEPLOYMENTS < <(grep -v '^\s*#' "$DEPLOY_FILE" | grep -v '^\s*$' | tr -d '\r' || true)
  elif [[ -n "$DEPLOY" ]]; then
    DEPLOYMENTS=("$DEPLOY")
  else
    echo -e "${CYAN}Mengambil daftar deployment di namespace '${NAMESPACE}'...${NC}"
    local ALL_DEPS=()
    mapfile -t ALL_DEPS < <(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' || true)

    if [[ ${#ALL_DEPS[@]} -eq 0 ]]; then
      echo -e "${RED}Tidak ada deployment ditemukan di namespace '${NAMESPACE}'.${NC}"
      exit 1
    fi

    echo ""
    echo -e "${BOLD}Daftar Deployment di namespace '${CYAN}${NAMESPACE}${NC}':${NC}"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────────────────${NC}"
    printf "  ${BOLD}%-3s  %-30s  %-20s  %-20s${NC}\n" "NO" "DEPLOYMENT" "CPU (REQ/LIM)" "MEM (REQ/LIM)"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────────────────${NC}"
    printf "  ${CYAN}%-3s${NC}  ${BOLD}%-30s${NC}\n" "0" "-- SEMUA DEPLOYMENT (ALL) --"

    local idx=1
    for d in "${ALL_DEPS[@]}"; do
      [[ -z "$d" ]] && continue
      local c_req; c_req=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "-")
      local c_lim; c_lim=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "-")
      local m_req; m_req=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "-")
      local m_lim; m_lim=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "-")
      
      [[ -z "$c_req" ]] && c_req="none"
      [[ -z "$c_lim" ]] && c_lim="none"
      [[ -z "$m_req" ]] && m_req="none"
      [[ -z "$m_lim" ]] && m_lim="none"

      printf "  ${CYAN}%-3d${NC}  %-30s  %-20s  %-20s\n" "$idx" "$d" "${c_req}/${c_lim}" "${m_req}/${m_lim}"
      ((idx++)) || true
    done
    echo -e "${YELLOW}────────────────────────────────────────────────────────────────────────${NC}"

    echo -ne "${BOLD}Pilih nomor deployment (atau 0 untuk semua): ${NC}"
    read -r CHOICE
    CHOICE=$(echo "$CHOICE" | tr -d '\r')

    if [[ "$CHOICE" == "0" ]]; then
      DEPLOYMENTS=("${ALL_DEPS[@]}")
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && [[ "$CHOICE" -ge 1 && "$CHOICE" -le ${#ALL_DEPS[@]} ]]; then
      DEPLOYMENTS=("${ALL_DEPS[$((CHOICE-1))]}")
    else
      echo -e "${RED}Pilihan tidak valid.${NC}"
      exit 1
    fi
  fi

  if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}Tidak ada deployment untuk di-update.${NC}"
    exit 0
  fi

  echo ""
  echo -e "${BOLD}Rencana update resources:${NC}"
  echo "  Namespace : $NAMESPACE"
  echo "  Total dep : ${#DEPLOYMENTS[@]}"
  echo "  CPU Req   : ${CPU_REQ:-'(tidak diubah)'}"
  echo "  Mem Req   : ${MEM_REQ:-'(tidak diubah)'}"
  echo "  CPU Limit : ${CPU_LIM:-'(tidak diubah)'}"
  echo "  Mem Limit : ${MEM_LIM:-'(tidak diubah)'}"
  echo ""
  echo -ne "${BOLD}Lanjutkan update resources? (y/N): ${NC}"
  read -r CONFIRM
  CONFIRM=$(echo "$CONFIRM" | tr -d '\r')

  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Dibatalkan."
    exit 0
  fi

  echo ""
  local SUCCESS=() FAILED=()
  for d in "${DEPLOYMENTS[@]}"; do
    [[ -z "$d" ]] && continue
    if _set_deployment_resources "$d" "$NAMESPACE" "$CPU_REQ" "$MEM_REQ" "$CPU_LIM" "$MEM_LIM" "$CONTAINER"; then
      SUCCESS+=("$d")
    else
      FAILED+=("$d")
    fi
  done

  echo ""
  echo -e "${BOLD}Ringkasan update resources:${NC}"
  echo -e "  ${GREEN}Berhasil : ${#SUCCESS[@]}${NC}"
  echo -e "  ${RED}Gagal    : ${#FAILED[@]}${NC}"
}

# ════════════════════════════════════════════════════════════════
# MODE: HPA  (aktifkan & atur Horizontal Pod Autoscaler)
# ════════════════════════════════════════════════════════════════

cmd_hpa() {
  local NAMESPACE="default" DEPLOY="" DEPLOY_FILE="" ALL_MODE=false
  local MIN_REPLICAS="1" MAX_REPLICAS="5" CPU_PERCENT="80" MEM_PERCENT="" DELETE_MODE=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      -n) NAMESPACE="$2"; shift 2 ;;
      -d) DEPLOY="$2"; shift 2 ;;
      -f) DEPLOY_FILE="$2"; shift 2 ;;
      -a|--all) ALL_MODE=true; shift ;;
      --min) MIN_REPLICAS="$2"; shift 2 ;;
      --max) MAX_REPLICAS="$2"; shift 2 ;;
      --cpu-percent) CPU_PERCENT="$2"; shift 2 ;;
      --mem-percent) MEM_PERCENT="$2"; shift 2 ;;
      --delete) DELETE_MODE=true; shift ;;
      -h|--help) hpa_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; hpa_help ;;
    esac
  done

  local DEPLOYMENTS=()

  if [[ "$ALL_MODE" == "true" ]]; then
    echo -e "${CYAN}Mengambil semua deployment di namespace '${NAMESPACE}'...${NC}"
    mapfile -t DEPLOYMENTS < <(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' || true)
  elif [[ -n "$DEPLOY_FILE" ]]; then
    if [[ ! -f "$DEPLOY_FILE" ]]; then
      echo -e "${RED}Error: File '$DEPLOY_FILE' tidak ditemukan.${NC}"
      exit 1
    fi
    mapfile -t DEPLOYMENTS < <(grep -v '^\s*#' "$DEPLOY_FILE" | grep -v '^\s*$' | tr -d '\r' || true)
  elif [[ -n "$DEPLOY" ]]; then
    DEPLOYMENTS=("$DEPLOY")
  else
    echo -e "${CYAN}Mengambil daftar deployment & status HPA di namespace '${NAMESPACE}'...${NC}"
    local ALL_DEPS=()
    mapfile -t ALL_DEPS < <(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' || true)

    if [[ ${#ALL_DEPS[@]} -eq 0 ]]; then
      echo -e "${RED}Tidak ada deployment ditemukan di namespace '${NAMESPACE}'.${NC}"
      exit 1
    fi

    echo ""
    echo -e "${BOLD}Daftar Deployment & HPA di namespace '${CYAN}${NAMESPACE}${NC}':${NC}"
    echo -e "${YELLOW}──────────────────────────────────────────────────────────────────────────────${NC}"
    printf "  ${BOLD}%-3s  %-30s  %-20s  %-20s${NC}\n" "NO" "DEPLOYMENT" "CPU/MEM REQ" "HPA STATUS"
    echo -e "${YELLOW}──────────────────────────────────────────────────────────────────────────────${NC}"
    printf "  ${CYAN}%-3s${NC}  ${BOLD}%-30s${NC}\n" "0" "-- SEMUA DEPLOYMENT (ALL) --"

    local idx=1
    for d in "${ALL_DEPS[@]}"; do
      [[ -z "$d" ]] && continue
      local c_req; c_req=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "")
      local m_req; m_req=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "")
      local hpa_info; hpa_info=$(kubectl get hpa "$d" -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $3"/"$4" (max "$5")"}' || echo "")

      local req_status="${c_req:-'none'}/${m_req:-'none'}"
      if [[ -z "$c_req" || -z "$m_req" ]]; then
        req_status="${RED}${req_status}${NC}"
      fi

      local hpa_status="${hpa_info}"
      [[ -z "$hpa_info" ]] && hpa_status="${YELLOW}Inactive${NC}"

      printf "  ${CYAN}%-3d${NC}  %-30s  %-20b  %-20b\n" "$idx" "$d" "$req_status" "$hpa_status"
      ((idx++)) || true
    done
    echo -e "${YELLOW}──────────────────────────────────────────────────────────────────────────────${NC}"

    echo -ne "${BOLD}Pilih nomor deployment (atau 0 untuk semua): ${NC}"
    read -r CHOICE
    CHOICE=$(echo "$CHOICE" | tr -d '\r')

    if [[ "$CHOICE" == "0" ]]; then
      DEPLOYMENTS=("${ALL_DEPS[@]}")
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && [[ "$CHOICE" -ge 1 && "$CHOICE" -le ${#ALL_DEPS[@]} ]]; then
      DEPLOYMENTS=("${ALL_DEPS[$((CHOICE-1))]}")
    else
      echo -e "${RED}Pilihan tidak valid.${NC}"
      exit 1
    fi
  fi

  if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}Tidak ada deployment diproses.${NC}"
    exit 0
  fi

  if [[ "$DELETE_MODE" == "false" ]]; then
    local NEED_RESOURCE_FIX=()
    for d in "${DEPLOYMENTS[@]}"; do
      [[ -z "$d" ]] && continue
      local c_req; c_req=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "")
      local m_req; m_req=$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "")
      
      if [[ -n "$CPU_PERCENT" && -z "$c_req" ]] || [[ -n "$MEM_PERCENT" && -z "$m_req" ]]; then
        NEED_RESOURCE_FIX+=("$d")
      fi
    done

    if [[ ${#NEED_RESOURCE_FIX[@]} -gt 0 ]]; then
      echo ""
      echo -e "${YELLOW}⚠ Peringatan: ${#NEED_RESOURCE_FIX[@]} deployment belum memiliki Resource Requests (CPU/Memory).${NC}"
      echo -e "${YELLOW}HPA membutuhkan CPU/Memory request agar dapat mengkalkulasi persentase utilization.${NC}"
      echo ""
      echo -ne "${BOLD}Apakah Anda ingin mengeset default CPU Request (100m) & Memory Request (256Mi) otomatis? (Y/n): ${NC}"
      read -r FIX_CONFIRM
      FIX_CONFIRM=$(echo "$FIX_CONFIRM" | tr -d '\r')

      if [[ "$FIX_CONFIRM" != "n" && "$FIX_CONFIRM" != "N" ]]; then
        echo -e "${CYAN}Meng-apply default resources pada deployment yang belum memiliki resource requests...${NC}"
        for d in "${NEED_RESOURCE_FIX[@]}"; do
          _set_deployment_resources "$d" "$NAMESPACE" "100m" "256Mi" "" "" ""
        done
      fi
    fi
  fi

  echo ""
  if [[ "$DELETE_MODE" == "true" ]]; then
    echo -e "${BOLD}Konfirmasi HAPUS HPA:${NC}"
    echo "  Namespace : $NAMESPACE"
    echo "  Total dep : ${#DEPLOYMENTS[@]}"
    echo ""
    echo -ne "${BOLD}Hapus HPA dari deployment tersebut? (y/N): ${NC}"
    read -r CONFIRM
    CONFIRM=$(echo "$CONFIRM" | tr -d '\r')
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      echo "Dibatalkan."
      exit 0
    fi

    for d in "${DEPLOYMENTS[@]}"; do
      [[ -z "$d" ]] && continue
      echo -ne "  Menghapus HPA ${BOLD}${d}${NC} ... "
      if kubectl delete hpa "$d" -n "$NAMESPACE" &>/dev/null; then
        echo -e "${GREEN}✓ berhasil${NC}"
      else
        echo -e "${YELLOW}⚠ tidak ditemukan / gagal${NC}"
      fi
    done
  else
    echo -e "${BOLD}Rencana konfigurasi HPA:${NC}"
    echo "  Namespace   : $NAMESPACE"
    echo "  Total dep   : ${#DEPLOYMENTS[@]}"
    echo "  Min Replika : $MIN_REPLICAS"
    echo "  Max Replika : $MAX_REPLICAS"
    [[ -n "$CPU_PERCENT" ]] && echo "  CPU Target  : ${CPU_PERCENT}%"
    [[ -n "$MEM_PERCENT" ]] && echo "  Mem Target  : ${MEM_PERCENT}%"
    echo ""
    echo -ne "${BOLD}Aktifkan/Update HPA? (y/N): ${NC}"
    read -r CONFIRM
    CONFIRM=$(echo "$CONFIRM" | tr -d '\r')
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      echo "Dibatalkan."
      exit 0
    fi

    echo ""
    for d in "${DEPLOYMENTS[@]}"; do
      [[ -z "$d" ]] && continue
      
      local METRICS_BLOCK=""
      if [[ -n "$CPU_PERCENT" ]]; then
        METRICS_BLOCK="${METRICS_BLOCK}
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: ${CPU_PERCENT}"
      fi

      if [[ -n "$MEM_PERCENT" ]]; then
        METRICS_BLOCK="${METRICS_BLOCK}
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: ${MEM_PERCENT}"
      fi

      if [[ -z "$METRICS_BLOCK" ]]; then
        echo -e "${RED}Error: Minimal salah satu dari --cpu-percent atau --mem-percent harus ditentukan.${NC}"
        exit 1
      fi

      local TARGET_STR=""
      [[ -n "$CPU_PERCENT" ]] && TARGET_STR="CPU: ${CPU_PERCENT}%"
      if [[ -n "$MEM_PERCENT" ]]; then
        [[ -n "$TARGET_STR" ]] && TARGET_STR="${TARGET_STR}, "
        TARGET_STR="${TARGET_STR}Mem: ${MEM_PERCENT}%"
      fi

      echo -ne "  Mengaktifkan HPA ${BOLD}${d}${NC} (min: ${MIN_REPLICAS}, max: ${MAX_REPLICAS}, ${TARGET_STR}) ... "

      if kubectl apply -f - &>/dev/null <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${d}
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${d}
  minReplicas: ${MIN_REPLICAS}
  maxReplicas: ${MAX_REPLICAS}
  metrics: ${METRICS_BLOCK}
EOF
      then
        echo -e "${GREEN}✓ berhasil${NC}"
      else
        echo -e "${RED}✗ gagal${NC}"
      fi
    done
  fi

  echo ""
  echo -e "${GREEN}✓ Proses HPA selesai!${NC}"
}

# ════════════════════════════════════════════════════════════════
# MODE: CTX / CONTEXT  (pindah / lihat / tambah cluster context)
# ════════════════════════════════════════════════════════════════

_add_kubeconfig_file() {
  local file_path="$1" alias_name="${2:-}"
  if [[ ! -f "$file_path" ]]; then
    echo -e "${RED}Error: File '$file_path' tidak ditemukan.${NC}"
    exit 1
  fi

  local KUBECONFIG_MAIN="${HOME}/.kube/config"
  mkdir -p "${HOME}/.kube"
  touch "$KUBECONFIG_MAIN"

  local TMP_CONF
  TMP_CONF=$(mktemp)

  echo -ne "  Meng-merge file '${file_path}' ke ${KUBECONFIG_MAIN} ... "
  if KUBECONFIG="${KUBECONFIG_MAIN}:${file_path}" kubectl config view --flatten > "$TMP_CONF" 2>/dev/null; then
    mv "$TMP_CONF" "$KUBECONFIG_MAIN"
    chmod 600 "$KUBECONFIG_MAIN" 2>/dev/null || true
    echo -e "${GREEN}✓ berhasil${NC}"

    if [[ -n "$alias_name" ]]; then
      local NEW_CTX
      NEW_CTX=$(kubectl config current-context 2>/dev/null || echo "")
      if [[ -n "$NEW_CTX" ]]; then
        kubectl config rename-context "$NEW_CTX" "$alias_name" &>/dev/null || true
        echo -e "${GREEN}✓ Context di-rename menjadi: ${CYAN}${alias_name}${NC}"
      fi
    fi
  else
    rm -f "$TMP_CONF"
    echo -e "${RED}✗ gagal meng-merge file kubeconfig.${NC}"
    exit 1
  fi
}

_login_cluster() {
  local server_url="$1" user_name="$2" pass_token="$3" alias_name="$4"

  if command -v oc >/dev/null 2>&1; then
    echo -e "${CYAN}Melakukan OpenShift login (oc login)...${NC}"
    local LOGIN_ARGS=()
    [[ -n "$server_url" ]] && LOGIN_ARGS+=("$server_url")
    LOGIN_ARGS+=("--insecure-skip-tls-verify=true")

    if [[ "$pass_token" == sha256~* || "$pass_token" == eyJ* || ( -z "$user_name" && -n "$pass_token" ) ]]; then
      LOGIN_ARGS+=("--token=${pass_token}")
    else
      [[ -n "$user_name" ]] && LOGIN_ARGS+=("-u" "$user_name")
      [[ -n "$pass_token" ]] && LOGIN_ARGS+=("-p" "$pass_token")
    fi

    if oc login "${LOGIN_ARGS[@]}"; then
      echo -e "${GREEN}✓ Login berhasil.${NC}"
      if [[ -n "$alias_name" ]]; then
        local CUR
        CUR=$(oc config current-context 2>/dev/null || echo "")
        if [[ -n "$CUR" ]]; then
          oc config rename-context "$CUR" "$alias_name" &>/dev/null || true
          echo -e "${GREEN}✓ Context di-rename menjadi: ${CYAN}${alias_name}${NC}"
        fi
      fi
    else
      echo -e "${RED}✗ Login gagal.${NC}"
      echo -e "${YELLOW}Tip untuk OpenShift 4:${NC}"
      echo -e "  1. Buka URL: ${CYAN}https://oauth-openshift.apps.test-jaguars.jamkrindo.co.id/oauth/token/request${NC}"
      echo -e "  2. Login & klik 'Display Token'"
      echo -e "  3. Copy token (sha256~...), lalu jalankan:"
      echo -e "     ${CYAN}./kube-manage.sh ctx --login https://api.test-jaguars.jamkrindo.co.id:6443 -p \"sha256~YOUR_TOKEN\" [ALIAS]${NC}"
      exit 1
    fi
  else
    echo -e "${CYAN}Meng-konfigurasi cluster context via kubectl config...${NC}"
    local CTX_NAME="${alias_name:-k8s-cluster}"
    local CLUSTER_NAME="cluster-${CTX_NAME}"
    local USER_NAME_KEY="user-${CTX_NAME}"

    kubectl config set-cluster "$CLUSTER_NAME" --server="$server_url" --insecure-skip-tls-verify=true >/dev/null
    
    if [[ -n "$pass_token" ]]; then
      kubectl config set-credentials "$USER_NAME_KEY" --token="$pass_token" >/dev/null
    elif [[ -n "$user_name" ]]; then
      kubectl config set-credentials "$USER_NAME_KEY" --username="$user_name" >/dev/null
    fi

    kubectl config set-context "$CTX_NAME" --cluster="$CLUSTER_NAME" --user="$USER_NAME_KEY" --namespace=default >/dev/null
    kubectl config use-context "$CTX_NAME" >/dev/null

    echo -e "${GREEN}✓ Context '${CYAN}${CTX_NAME}${GREEN}' berhasil dibuat & diaktifkan.${NC}"
  fi
}

cmd_ctx() {
  local CLI
  CLI=$(get_kube_cli)

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    ctx_help
  fi

  if [[ "${1:-}" == "--add-file" ]]; then
    shift
    local FILE_PATH="${1:-}"
    local ALIAS_NAME="${2:-}"
    if [[ -z "$FILE_PATH" ]]; then
      echo -e "${RED}Error: Path file kubeconfig wajib ditentukan.${NC}"
      exit 1
    fi
    _add_kubeconfig_file "$FILE_PATH" "$ALIAS_NAME"
    return 0
  fi

  if [[ "${1:-}" == "--login" ]]; then
    shift
    local SERVER_URL="${1:-}"
    local USER_VAL="" PASS_VAL="" ALIAS_NAME=""
    shift || true

    while [[ $# -gt 0 ]]; do
      case $1 in
        -u) USER_VAL="$2"; shift 2 ;;
        -p) PASS_VAL="$2"; shift 2 ;;
        *) ALIAS_NAME="$1"; shift ;;
      esac
    done

    if [[ -z "$SERVER_URL" ]]; then
      echo -e "${RED}Error: Server URL wajib ditentukan.${NC}"
      exit 1
    fi

    _login_cluster "$SERVER_URL" "$USER_VAL" "$PASS_VAL" "$ALIAS_NAME"
    return 0
  fi

  if [[ "${1:-}" == "--delete" || "${1:-}" == "-del" ]]; then
    shift
    local DEL_CTX="${1:-}"
    if [[ -z "$DEL_CTX" ]]; then
      echo -e "${RED}Error: Nama context yang akan dihapus wajib ditentukan.${NC}"
      exit 1
    fi

    echo -ne "  Menghapus cluster context ${BOLD}${DEL_CTX}${NC} ... "
    if $CLI config delete-context "$DEL_CTX" &>/dev/null; then
      echo -e "${GREEN}✓ berhasil dihapus${NC}"
    else
      echo -e "${RED}✗ gagal (context '$DEL_CTX' tidak ditemukan)${NC}"
      exit 1
    fi
    return 0
  fi

  if [[ "${1:-}" == "--clear-all" || "${1:-}" == "--reset" ]]; then
    local CONF_FILE="${HOME}/.kube/config"
    echo -e "${RED}⚠ PERINGATAN: Semua daftar cluster context di ${CONF_FILE} akan dihapus.${NC}"
    echo -ne "${BOLD}Apakah Anda yakin ingin mereset SEMUA context? (y/N): ${NC}"
    read -r CONFIRM_RESET
    CONFIRM_RESET=$(echo "$CONFIRM_RESET" | tr -d '\r')

    if [[ "$CONFIRM_RESET" == "y" || "$CONFIRM_RESET" == "Y" ]]; then
      if [[ -f "$CONF_FILE" ]]; then
        cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        rm -f "$CONF_FILE"
        echo -e "${GREEN}✓ Semua context berhasil dihapus (backup disimpan di ${CONF_FILE}.bak.*).${NC}"
      else
        echo -e "${YELLOW}Kubeconfig sudah kosong.${NC}"
      fi
    else
      echo "Dibatalkan."
    fi
    return 0
  fi

  local TARGET_CTX="${1:-}"
  local CUR_CTX
  CUR_CTX=$($CLI config current-context 2>/dev/null || echo "none")

  if [[ -n "$TARGET_CTX" ]]; then
    echo -ne "  Pindah ke cluster context ${BOLD}${TARGET_CTX}${NC} ... "
    if $CLI config use-context "$TARGET_CTX" &>/dev/null; then
      echo -e "${GREEN}✓ berhasil${NC}"
      echo -e "Cluster aktif sekarang: ${CYAN}${TARGET_CTX}${NC}"
    else
      echo -e "${RED}✗ gagal (context '$TARGET_CTX' tidak ditemukan)${NC}"
      exit 1
    fi
    return 0
  fi

  local CONTEXTS=()
  mapfile -t CONTEXTS < <($CLI config get-contexts -o name 2>/dev/null | tr -d '\r' || true)

  echo ""
  echo -e "${BOLD}Daftar Cluster Context (${#CONTEXTS[@]} cluster terdaftar):${NC}"
  echo -e "${YELLOW}────────────────────────────────────────────────────────────────────────${NC}"
  local idx=1
  for ctx in "${CONTEXTS[@]}"; do
    [[ -z "$ctx" ]] && continue
    if [[ "$ctx" == "$CUR_CTX" ]]; then
      printf "  ${GREEN}* %2d) %-50s (active)${NC}\n" "$idx" "$ctx"
    else
      printf "    %2d) %-50s\n" "$idx" "$ctx"
    fi
    ((idx++)) || true
  done
  echo -e "${CYAN}   +) -- Tambah / Import Cluster Baru --${NC}"
  echo -e "${RED}   -) -- Hapus / Delete Context Cluster --${NC}"
  echo -e "${YELLOW}────────────────────────────────────────────────────────────────────────${NC}"

  echo ""
  echo -ne "${BOLD}Pilih nomor cluster, '+' (tambah), '-' (hapus), atau ketik nama context: ${NC}"
  read -r CHOICE
  CHOICE=$(echo "$CHOICE" | tr -d '\r')

  if [[ -z "$CHOICE" ]]; then
    echo "Dibatalkan."
    exit 0
  fi

  if [[ "$CHOICE" == "+" ]]; then
    echo ""
    echo -e "${BOLD}Metode Penambahan Cluster:${NC}"
    echo "  1) Import dari File Kubeconfig (.yaml)"
    echo "  2) Login / Tambah Cluster via Server URL"
    echo -ne "${BOLD}Pilih metode (1/2): ${NC}"
    read -r METHOD
    METHOD=$(echo "$METHOD" | tr -d '\r')

    if [[ "$METHOD" == "1" ]]; then
      echo -ne "${BOLD}Masukkan path file kubeconfig: ${NC}"
      read -r FILE_INPUT
      FILE_INPUT=$(echo "$FILE_INPUT" | tr -d '\r')

      echo -ne "${BOLD}Masukkan nama alias context (opsional): ${NC}"
      read -r ALIAS_INPUT
      ALIAS_INPUT=$(echo "$ALIAS_INPUT" | tr -d '\r')

      _add_kubeconfig_file "$FILE_INPUT" "$ALIAS_INPUT"
      return 0
    elif [[ "$METHOD" == "2" ]]; then
      echo -ne "${BOLD}Masukkan URL Server API (contoh: https://api.cluster.com:6443): ${NC}"
      read -r SERVER_INPUT
      SERVER_INPUT=$(echo "$SERVER_INPUT" | tr -d '\r')

      echo -ne "${BOLD}Username / Token: ${NC}"
      read -r USER_INPUT
      USER_INPUT=$(echo "$USER_INPUT" | tr -d '\r')

      echo -ne "${BOLD}Password (kosongkan jika mengisi Token di atas): ${NC}"
      read -rs PASS_INPUT
      echo ""

      echo -ne "${BOLD}Masukkan nama alias context (opsional): ${NC}"
      read -r ALIAS_INPUT
      ALIAS_INPUT=$(echo "$ALIAS_INPUT" | tr -d '\r')

      _login_cluster "$SERVER_INPUT" "$USER_INPUT" "$PASS_INPUT" "$ALIAS_INPUT"
      return 0
    else
      echo -e "${RED}Metode tidak valid.${NC}"
      exit 1
    fi
  fi

  if [[ "$CHOICE" == "-" ]]; then
    echo ""
    echo -e "${BOLD}Pilih nomor context yang ingin DIHAPUS:${NC}"
    printf "  ${RED}%2s) %s${NC}\n" "0" "-- HAPUS SEMUA CONTEXT (RESET) --"
    local idx=1
    for ctx in "${CONTEXTS[@]}"; do
      [[ -z "$ctx" ]] && continue
      printf "  %2d) %s\n" "$idx" "$ctx"
      ((idx++)) || true
    done
    echo -ne "${BOLD}Nomor context (atau 0 untuk hapus semua): ${NC}"
    read -r DEL_CHOICE
    DEL_CHOICE=$(echo "$DEL_CHOICE" | tr -d '\r')

    if [[ "$DEL_CHOICE" == "0" ]]; then
      cmd_ctx --clear-all
      return 0
    elif [[ "$DEL_CHOICE" =~ ^[0-9]+$ ]] && [[ "$DEL_CHOICE" -ge 1 && "$DEL_CHOICE" -le ${#CONTEXTS[@]} ]]; then
      local TARGET_DEL="${CONTEXTS[$((DEL_CHOICE-1))]}"
      echo -ne "${RED}Apakah Anda yakin ingin menghapus context '${TARGET_DEL}'? (y/N): ${NC}"
      read -r CONFIRM_DEL
      CONFIRM_DEL=$(echo "$CONFIRM_DEL" | tr -d '\r')
      if [[ "$CONFIRM_DEL" == "y" || "$CONFIRM_DEL" == "Y" ]]; then
        echo -ne "  Menghapus context ${BOLD}${TARGET_DEL}${NC} ... "
        if $CLI config delete-context "$TARGET_DEL" &>/dev/null; then
          echo -e "${GREEN}✓ berhasil dihapus${NC}"
        else
          echo -e "${RED}✗ gagal${NC}"
        fi
      else
        echo "Dibatalkan."
      fi
    else
      echo -e "${RED}Pilihan tidak valid.${NC}"
    fi
    return 0
  fi

  local SELECTED_CTX=""
  if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [[ "$CHOICE" -ge 1 && "$CHOICE" -le ${#CONTEXTS[@]} ]]; then
    SELECTED_CTX="${CONTEXTS[$((CHOICE-1))]}"
  else
    SELECTED_CTX="$CHOICE"
  fi

  echo -ne "  Pindah ke cluster context ${BOLD}${SELECTED_CTX}${NC} ... "
  if $CLI config use-context "$SELECTED_CTX" &>/dev/null; then
    echo -e "${GREEN}✓ berhasil${NC}"
    echo -e "Cluster aktif sekarang: ${CYAN}${SELECTED_CTX}${NC}"
  else
    echo -e "${RED}✗ gagal (context '$SELECTED_CTX' tidak valid)${NC}"
    exit 1
  fi
}

# ════════════════════════════════════════════════════════════════
# MODE: TOKEN  (buat Bearer Token 1 tahun / permanen)
# ════════════════════════════════════════════════════════════════

cmd_token() {
  local SA_NAME="admin-user" NAMESPACE="default" DURATION="8760h" PERMANENT=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      -u|--user) SA_NAME="$2"; shift 2 ;;
      -n|--namespace) NAMESPACE="$2"; shift 2 ;;
      --duration) DURATION="$2"; shift 2 ;;
      --permanent) PERMANENT=true; shift ;;
      -h|--help) token_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; token_help ;;
    esac
  done

  local CLI
  CLI=$(get_kube_cli)

  echo -e "${CYAN}Menyiapkan ServiceAccount '${SA_NAME}' di namespace '${NAMESPACE}'...${NC}"
  
  if ! $CLI get serviceaccount "$SA_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo -ne "  Membuat ServiceAccount ${BOLD}${SA_NAME}${NC} ... "
    if $CLI create serviceaccount "$SA_NAME" -n "$NAMESPACE" &>/dev/null; then
      echo -e "${GREEN}✓ berhasil${NC}"
    else
      echo -e "${RED}✗ gagal${NC}"
      exit 1
    fi
  fi

  local CRB_NAME="${SA_NAME}-${NAMESPACE}-binding"
  if ! $CLI get clusterrolebinding "$CRB_NAME" &>/dev/null; then
    echo -ne "  Membuat ClusterRoleBinding ${BOLD}${CRB_NAME}${NC} (cluster-admin) ... "
    if $CLI create clusterrolebinding "$CRB_NAME" --clusterrole=cluster-admin --serviceaccount="${NAMESPACE}:${SA_NAME}" &>/dev/null; then
      echo -e "${GREEN}✓ berhasil${NC}"
    else
      echo -e "${YELLOW}⚠ Gagal membuat ClusterRoleBinding (mungkin butuh akses cluster-admin). Melanjutkan...${NC}"
    fi
  fi

  echo ""
  local TOKEN=""

  if [[ "$PERMANENT" == "true" ]]; then
    echo -e "${CYAN}Membuat Secret Token Permanen (Tanpa Expired)...${NC}"
    local SECRET_NAME="${SA_NAME}-permanent-token"
    
    $CLI apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

    sleep 2
    TOKEN=$($CLI get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")
  else
    echo -e "${CYAN}Meng-generate Bearer Token dengan durasi ${DURATION} (1 tahun)...${NC}"
    TOKEN=$($CLI create token "$SA_NAME" -n "$NAMESPACE" --duration="$DURATION" 2>/dev/null || echo "")
  fi

  if [[ -z "$TOKEN" ]]; then
    echo -e "${RED}Error: Gagal meng-generate token.${NC}"
    exit 1
  fi

  local SERVER_URL
  SERVER_URL=$($CLI config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "https://API-CLUSTER-URL:6443")

  echo ""
  echo -e "${GREEN}✓ Bearer Token Berhasil Dibuat!${NC}"
  echo -e "${YELLOW}────────────────────────────────────────────────────────────────────────${NC}"
  echo -e "${BOLD}Token String:${NC}"
  echo -e "${CYAN}${TOKEN}${NC}"
  echo -e "${YELLOW}────────────────────────────────────────────────────────────────────────${NC}"
  echo ""
  echo -e "${BOLD}Untuk menyimpan context cluster ini di laptop Anda agar aktif 1 tahun:${NC}"
  echo -e "  ${CYAN}./kube-manage.sh ctx --login ${SERVER_URL} -p \"${TOKEN}\" rke-cluster${NC}"
}

# ════════════════════════════════════════════════════════════════
# MODE: CONFIG  (update ConfigMap / Env vars & restart pods)
# ════════════════════════════════════════════════════════════════

cmd_config() {
  local NAMESPACE="default" CM_NAME="" KEY_NAME="" VALUE_VAL="" OLD_STR="" NEW_STR="" ENV_PAIR="" DEPLOY="" ALL_MODE=false RESTART_DEPS=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      -n) NAMESPACE="$2"; shift 2 ;;
      -d) DEPLOY="$2"; shift 2 ;;
      -a|--all) ALL_MODE=true; shift ;;
      -e|--env|--set-env) ENV_PAIR="$2"; shift 2 ;;
      -cm|--configmap) CM_NAME="$2"; shift 2 ;;
      -k|--key) KEY_NAME="$2"; shift 2 ;;
      -v|--value) VALUE_VAL="$2"; shift 2 ;;
      --old) OLD_STR="$2"; shift 2 ;;
      --new) NEW_STR="$2"; shift 2 ;;
      --replace)
        if [[ $# -ge 3 && "$2" != -* && "$3" != -* ]]; then
          OLD_STR="$2"
          NEW_STR="$3"
          shift 3
        elif [[ "$2" == *":::"* ]]; then
          OLD_STR="${2%%:::*}"
          NEW_STR="${2#*:::}"
          shift 2
        else
          OLD_STR=$(echo "$2" | cut -d: -f1)
          NEW_STR=$(echo "$2" | cut -d: -f2-)
          shift 2
        fi
        ;;
      -r|--restart) RESTART_DEPS=true; shift ;;
      -h|--help) config_help ;;
      *) echo -e "${RED}Opsi tidak dikenal: $1${NC}"; config_help ;;
    esac
  done

  local CLI
  CLI=$(get_kube_cli)

  if [[ -n "$OLD_STR" && -n "$NEW_STR" ]]; then
    echo -e "${CYAN}Memindai ConfigMap, Secret, & Deployment di namespace '${NAMESPACE}' untuk string '${OLD_STR}'...${NC}"
    
    local OLD_B64
    OLD_B64=$(echo -n "$OLD_STR" | base64 | tr -d '\r\n')
    local NEW_B64
    NEW_B64=$(echo -n "$NEW_STR" | base64 | tr -d '\r\n')

    local MATCHED_CMS=()
    local CMS=()
    mapfile -t CMS < <($CLI get configmap -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' || true)
    
    for cm in "${CMS[@]}"; do
      [[ -z "$cm" ]] && continue
      local RAW_YAML
      RAW_YAML=$($CLI get configmap "$cm" -n "$NAMESPACE" -o yaml 2>/dev/null || echo "")
      if echo "$RAW_YAML" | grep -F -q -- "$OLD_STR" 2>/dev/null || echo "$RAW_YAML" | grep -F -q -- "$OLD_B64" 2>/dev/null; then
        MATCHED_CMS+=("$cm")
      fi
    done

    local MATCHED_SECS=()
    local SECS=()
    mapfile -t SECS < <($CLI get secret -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' || true)

    for sec in "${SECS[@]}"; do
      [[ -z "$sec" ]] && continue
      local sec_type; sec_type=$($CLI get secret "$sec" -n "$NAMESPACE" -o jsonpath='{.type}' 2>/dev/null || echo "")
      [[ "$sec_type" == "kubernetes.io/service-account-token" ]] && continue
      local RAW_YAML
      RAW_YAML=$($CLI get secret "$sec" -n "$NAMESPACE" -o yaml 2>/dev/null || echo "")
      if echo "$RAW_YAML" | grep -F -q -- "$OLD_STR" 2>/dev/null || echo "$RAW_YAML" | grep -F -q -- "$OLD_B64" 2>/dev/null; then
        MATCHED_SECS+=("$sec")
      fi
    done

    local MATCHED_DEPS=()
    local DEPS=()
    mapfile -t DEPS < <($CLI get deployment -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' || true)

    for d in "${DEPS[@]}"; do
      [[ -z "$d" ]] && continue
      local RAW_YAML
      RAW_YAML=$($CLI get deployment "$d" -n "$NAMESPACE" -o yaml 2>/dev/null || echo "")
      if echo "$RAW_YAML" | grep -F -q -- "$OLD_STR" 2>/dev/null; then
        MATCHED_DEPS+=("$d")
      fi
    done

    if [[ ${#MATCHED_CMS[@]} -eq 0 && ${#MATCHED_SECS[@]} -eq 0 && ${#MATCHED_DEPS[@]} -eq 0 ]]; then
      echo -e "${YELLOW}Tidak ditemukan string '${OLD_STR}' pada ConfigMap, Secret, maupun Deployment di namespace '${NAMESPACE}'.${NC}"
      exit 0
    fi

    echo ""
    echo -e "${BOLD}Pratinjau Perubahan (Preview):${NC}"
    echo -e "  Namespace  : ${CYAN}${NAMESPACE}${NC}"
    echo -e "  Teks Lama  : ${YELLOW}${OLD_STR}${NC}"
    echo -e "  Teks Baru  : ${GREEN}${NEW_STR}${NC}"
    echo ""

    if [[ ${#MATCHED_CMS[@]} -gt 0 ]]; then
      echo -e "  ${BOLD}ConfigMap yang akan di-update (${#MATCHED_CMS[@]}):${NC}"
      for cm in "${MATCHED_CMS[@]}"; do
        echo -e "    - ${CYAN}${cm}${NC}"
      done
    else
      echo -e "  ${YELLOW}ConfigMap  : (tidak ada yang cocok)${NC}"
    fi

    echo ""
    if [[ ${#MATCHED_SECS[@]} -gt 0 ]]; then
      echo -e "  ${BOLD}Secret yang akan di-update (${#MATCHED_SECS[@]}):${NC}"
      for sec in "${MATCHED_SECS[@]}"; do
        echo -e "    - ${CYAN}${sec}${NC}"
      done
    else
      echo -e "  ${YELLOW}Secret     : (tidak ada yang cocok)${NC}"
    fi

    echo ""
    if [[ ${#MATCHED_DEPS[@]} -gt 0 ]]; then
      echo -e "  ${BOLD}Deployment yang akan di-update (${#MATCHED_DEPS[@]}):${NC}"
      for d in "${MATCHED_DEPS[@]}"; do
        echo -e "    - ${CYAN}${d}${NC} (env/spec)"
      done
    else
      echo -e "  ${YELLOW}Deployment : (tidak ada yang cocok)${NC}"
    fi

    echo ""
    read -rp "Lanjutkan update ${#MATCHED_CMS[@]} ConfigMap, ${#MATCHED_SECS[@]} Secret, dan ${#MATCHED_DEPS[@]} Deployment? (y/N): " CONFIRM
    CONFIRM=$(echo "$CONFIRM" | tr -d '\r')

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      echo "Dibatalkan."
      exit 0
    fi

    echo ""
    local UPDATED_COUNT=0
    for cm in "${MATCHED_CMS[@]}"; do
      echo -ne "  Updating ConfigMap ${BOLD}${cm}${NC} ... "
      local RAW_YAML
      RAW_YAML=$($CLI get configmap "$cm" -n "$NAMESPACE" -o yaml 2>/dev/null || echo "")
      local NEW_YAML
      NEW_YAML=$(echo "$RAW_YAML" | sed -e "s/${OLD_STR}/${NEW_STR}/g" -e "s/${OLD_B64}/${NEW_B64}/g")
      if echo "$NEW_YAML" | $CLI apply -f - &>/dev/null; then
        echo -e "${GREEN}✓ berhasil${NC}"
        ((UPDATED_COUNT++)) || true
      else
        echo -e "${RED}✗ gagal${NC}"
      fi
    done

    local SEC_UPDATED_COUNT=0
    for sec in "${MATCHED_SECS[@]}"; do
      echo -ne "  Updating Secret ${BOLD}${sec}${NC} ... "
      local RAW_YAML
      RAW_YAML=$($CLI get secret "$sec" -n "$NAMESPACE" -o yaml 2>/dev/null || echo "")
      local NEW_YAML
      NEW_YAML=$(echo "$RAW_YAML" | sed -e "s/${OLD_STR}/${NEW_STR}/g" -e "s/${OLD_B64}/${NEW_B64}/g")
      if echo "$NEW_YAML" | $CLI apply -f - &>/dev/null; then
        echo -e "${GREEN}✓ berhasil${NC}"
        ((SEC_UPDATED_COUNT++)) || true
      else
        echo -e "${RED}✗ gagal${NC}"
      fi
    done

    local DEP_UPDATED_COUNT=0
    for d in "${MATCHED_DEPS[@]}"; do
      echo -ne "  Updating Deployment ${BOLD}${d}${NC} (env/spec) ... "
      local RAW_YAML
      RAW_YAML=$($CLI get deployment "$d" -n "$NAMESPACE" -o yaml 2>/dev/null || echo "")
      local NEW_YAML
      NEW_YAML=$(echo "$RAW_YAML" | sed -e "s/${OLD_STR}/${NEW_STR}/g" -e "s/${OLD_B64}/${NEW_B64}/g")
      if echo "$NEW_YAML" | $CLI apply -f - &>/dev/null; then
        echo -e "${GREEN}✓ berhasil (rollout otomatis ter-trigger)${NC}"
        ((DEP_UPDATED_COUNT++)) || true
      else
        echo -e "${RED}✗ gagal${NC}"
      fi
    done

    echo ""
    echo -e "${BOLD}Ringkasan update config:${NC}"
    echo -e "  ConfigMap di-update  : ${GREEN}${UPDATED_COUNT}${NC}"
    echo -e "  Secret di-update     : ${GREEN}${SEC_UPDATED_COUNT}${NC}"
    echo -e "  Deployment di-update : ${GREEN}${DEP_UPDATED_COUNT}${NC}"

  elif [[ -n "$CM_NAME" && -n "$KEY_NAME" && -n "$VALUE_VAL" ]]; then
    echo ""
    echo -e "${BOLD}Konfirmasi Update ConfigMap Key:${NC}"
    echo -e "  Namespace : ${CYAN}${NAMESPACE}${NC}"
    echo -e "  ConfigMap : ${CYAN}${CM_NAME}${NC}"
    echo -e "  Key       : ${CYAN}${KEY_NAME}${NC}"
    echo -e "  Value Baru: ${GREEN}${VALUE_VAL}${NC}"
    echo "  Restart   : ${RESTART_DEPS}"
    echo ""
    read -rp "Lanjutkan update ConfigMap? (y/N): " CONFIRM
    CONFIRM=$(echo "$CONFIRM" | tr -d '\r')
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      echo "Dibatalkan."
      exit 0
    fi

    echo ""
    echo -ne "  Updating ${BOLD}${CM_NAME}${NC} (key: ${KEY_NAME}) ... "
    if $CLI create configmap "$CM_NAME" -n "$NAMESPACE" --from-literal="${KEY_NAME}=${VALUE_VAL}" --dry-run=client -o yaml | $CLI apply -f - &>/dev/null; then
      echo -e "${GREEN}✓ berhasil${NC}"
    else
      echo -e "${RED}✗ gagal${NC}"
      exit 1
    fi

  elif [[ -n "$ENV_PAIR" ]]; then
    local K_NAME="${ENV_PAIR%%=*}"
    local V_NAME="${ENV_PAIR#*=}"

    if [[ -z "$K_NAME" || -z "$V_NAME" ]]; then
      echo -e "${RED}Error: Format --env harus 'KEY=VALUE'.${NC}"
      exit 1
    fi

    local DEPLOYMENTS=()
    if [[ -n "$DEPLOY" ]]; then
      DEPLOYMENTS=("$DEPLOY")
    else
      mapfile -t DEPLOYMENTS < <($CLI get deployment -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tr -d '\r' || true)
    fi

    if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
      echo -e "${YELLOW}Tidak ada deployment ditemukan di namespace '${NAMESPACE}'.${NC}"
      exit 0
    fi

    echo ""
    echo -e "${BOLD}Konfirmasi Set Environment Variable Deployment:${NC}"
    echo -e "  Namespace  : ${CYAN}${NAMESPACE}${NC}"
    echo -e "  Total Dep  : ${CYAN}${#DEPLOYMENTS[@]} deployment${NC}"
    echo -e "  Env Key    : ${CYAN}${K_NAME}${NC}"
    echo -e "  Env Value  : ${GREEN}${V_NAME}${NC}"
    echo ""
    read -rp "Lanjutkan set environment variable pada ${#DEPLOYMENTS[@]} deployment? (y/N): " CONFIRM
    CONFIRM=$(echo "$CONFIRM" | tr -d '\r')
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      echo "Dibatalkan."
      exit 0
    fi

    echo ""
    local SUCCESS=() FAILED=()
    for d in "${DEPLOYMENTS[@]}"; do
      [[ -z "$d" ]] && continue
      echo -ne "  Setting env ${BOLD}${K_NAME}${NC} pada deployment/${d} ... "
      if $CLI set env deployment/"$d" -n "$NAMESPACE" "${K_NAME}=${V_NAME}" &>/dev/null; then
        echo -e "${GREEN}✓ berhasil (rollout otomatis ter-trigger)${NC}"
        SUCCESS+=("$d")
      else
        echo -e "${RED}✗ gagal${NC}"
        FAILED+=("$d")
      fi
    done

    echo ""
    echo -e "${BOLD}Ringkasan set env deployment:${NC}"
    echo -e "  ${GREEN}Berhasil : ${#SUCCESS[@]}${NC}"
    echo -e "  ${RED}Gagal    : ${#FAILED[@]}${NC}"
  else
    echo -e "${RED}Error: Gunakan '-e KEY=VALUE', '-cm CM_NAME -k KEY -v VALUE', atau '--old STR --new STR'.${NC}"
    config_help
  fi

  if [[ "$RESTART_DEPS" == "true" ]]; then
    echo ""
    echo -e "${CYAN}Melakukan restart rollout pada semua deployment agar pod memuat konfigurasi baru...${NC}"
    $CLI rollout restart deployment -n "$NAMESPACE" &>/dev/null || true
    echo -e "${GREEN}✓ Rollout restart dipicu untuk semua deployment di namespace '${NAMESPACE}'.${NC}"
  fi
}

# ════════════════════════════════════════════════════════════════
# ENTRY POINT
# ════════════════════════════════════════════════════════════════

MODE="${1:-}"
if [[ -z "$MODE" || "$MODE" == "-h" || "$MODE" == "--help" || "$MODE" == "help" ]]; then
  usage
fi
shift

# Memastikan CLI (kubectl/oc) tersedia sebelum menjalankan mode yang membutuhkan cluster
if [[ "$MODE" != "list" ]]; then
  get_kube_cli >/dev/null
fi

case "$MODE" in
  update)       cmd_update "$@" ;;
  rollback)     cmd_rollback "$@" ;;
  list)         cmd_list ;;
  pods)         cmd_pods "$@" ;;
  restart)      cmd_restart "$@" ;;
  pull-policy)  cmd_pull_policy "$@" ;;
  scale)        cmd_scale "$@" ;;
  clone)        cmd_clone "$@" ;;
  chpasswd)     cmd_chpasswd "$@" ;;
  resources)    cmd_resources "$@" ;;
  hpa)          cmd_hpa "$@" ;;
  ctx|context)  cmd_ctx "$@" ;;
  token)        cmd_token "$@" ;;
  config|env)   cmd_config "$@" ;;
  *)            echo -e "${RED}Mode tidak dikenal: $MODE${NC}"; usage ;;
esac
