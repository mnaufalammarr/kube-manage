#!/usr/bin/env bash
#
# audit_servers.sh
# ------------------------------------------------------------------
# Loops over a list of servers, SSHes into each one, and runs a
# remote audit (users, services, web/db/docker/k8s, cron jobs,
# installed packages). Saves one report per host + a combined
# summary.
#
# USAGE:
#   ./audit_servers.sh -f servers.txt
#   ./audit_servers.sh -f servers.txt -u myuser -k ~/.ssh/id_rsa -p 22
#
# servers.txt format (one host per line, "#" for comments):
#   web01.example.com
#   10.0.0.15
#   db01.example.com:2222        <- custom port
#   deploy@app01.example.com     <- custom user for this host only
#
# Requires: ssh access (key-based recommended) already set up to
# each host. This script does NOT store or handle passwords.
# ------------------------------------------------------------------

set -uo pipefail

# ---------------------------- defaults -----------------------------
SERVER_LIST=""
DEFAULT_USER="${USER:-$(whoami 2>/dev/null || id -un)}"
DEFAULT_PORT=22
SSH_KEY=""
SSH_TIMEOUT=10
USE_PASSWORD=0
OUTPUT_DIR="./audit-reports-$(date +%Y%m%d_%H%M%S)"
PARALLEL=1          # set >1 to run hosts concurrently (uses xargs -P)
SSH_OPTS_EXTRA=""
# Default folders to inspect on every host. Override/extend with -d
EXTRA_FOLDERS=""
DEFAULT_FOLDERS="/opt,/var/www/html,/var/www,/mnt,/home,/etc,/srv,/data"

usage() {
    cat <<EOF
Usage: $0 -f <server_list_file> [options]

Options:
  -f FILE     File with list of servers (required)
  -u USER     Default SSH user (default: current user, \$USER)
  -k KEYFILE  Path to SSH private key
  -p PORT     Default SSH port (default: 22)
  -t SECONDS  SSH connect timeout (default: 10)
  -o DIR      Output directory for reports (default: ./audit-reports-<timestamp>)
  -P N        Run N hosts in parallel (default: 1 = sequential)
  -d "a,b,c"  Extra folders to inspect, comma-separated (added to defaults below)
  -A          Use password auth, typed once and applied automatically to
              every host (no sshpass/expect needed - uses ssh's built-in
              SSH_ASKPASS mechanism). Works with parallel mode (-P) too.
  -h          Show this help

NOTE: -A uses the SAME password for every host in the list. If hosts have
different passwords, run the script separately per group of hosts sharing
one password, or switch to key-based auth (recommended long-term: ssh-copy-id).

Server list file: one host per line. Supports:
  host
  host:port
  user@host
  user@host:port
  # comment lines and blank lines are ignored

Folders inspected by default (contents, size, ownership):
  ${DEFAULT_FOLDERS}
Use -d to add more, e.g. -d "/opt/apps,/data/backups"
EOF
    exit 1
}

while getopts "f:u:k:p:t:o:P:d:Ah" opt; do
    case "$opt" in
        f) SERVER_LIST="$OPTARG" ;;
        u) DEFAULT_USER="$OPTARG" ;;
        k) SSH_KEY="$OPTARG" ;;
        p) DEFAULT_PORT="$OPTARG" ;;
        t) SSH_TIMEOUT="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        P) PARALLEL="$OPTARG" ;;
        d) EXTRA_FOLDERS="$OPTARG" ;;
        A) USE_PASSWORD=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

AUDIT_FOLDERS="$DEFAULT_FOLDERS"
if [[ -n "$EXTRA_FOLDERS" ]]; then
    AUDIT_FOLDERS="${AUDIT_FOLDERS},${EXTRA_FOLDERS}"
fi

if [[ -z "$SERVER_LIST" || ! -f "$SERVER_LIST" ]]; then
    echo "ERROR: must supply a valid server list file with -f" >&2
    usage
fi

mkdir -p "$OUTPUT_DIR"

if [[ -n "$SSH_KEY" ]]; then
    SSH_OPTS_EXTRA="-i $SSH_KEY"
fi

SSH_RUNNER=""
ASKPASS_SCRIPT=""

cleanup_askpass() {
    [[ -n "$ASKPASS_SCRIPT" && -f "$ASKPASS_SCRIPT" ]] && rm -f "$ASKPASS_SCRIPT"
}
trap cleanup_askpass EXIT

if [[ "$USE_PASSWORD" -eq 1 ]]; then
    # Automated password auth using OpenSSH's built-in SSH_ASKPASS mechanism.
    # No sshpass/expect needed. The password is typed once, held only in
    # memory for this process, and handed to ssh via a tiny helper script
    # instead of a CLI argument (so it never shows up in `ps aux`).
    read -r -s -p "SSH password (used for ALL hosts in the list): " AUDIT_SSH_PASSWORD
    echo
    if [[ -z "$AUDIT_SSH_PASSWORD" ]]; then
        echo "ERROR: empty password entered." >&2
        exit 1
    fi
    export AUDIT_SSH_PASSWORD

    ASKPASS_SCRIPT="$(mktemp)"
    cat > "$ASKPASS_SCRIPT" <<'ASKPASS_EOF'
#!/usr/bin/env bash
printf '%s\n' "$AUDIT_SSH_PASSWORD"
ASKPASS_EOF
    chmod 700 "$ASKPASS_SCRIPT"

    export SSH_ASKPASS="$ASKPASS_SCRIPT"
    export SSH_ASKPASS_REQUIRE=force   # OpenSSH >= 8.4: force askpass even with a tty present
    export DISPLAY="${DISPLAY:-:0}"    # older OpenSSH only tries askpass if DISPLAY is set

    # Older OpenSSH (<8.4) only invokes SSH_ASKPASS when there's no controlling
    # terminal to prompt on directly - `setsid` detaches one, so this path
    # works whether the machine has a modern or older ssh client.
    SSH_RUNNER="setsid"

    SSH_BASE_OPTS="-o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new -o ConnectTimeout=${SSH_TIMEOUT} ${SSH_OPTS_EXTRA}"
else
    SSH_BASE_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=${SSH_TIMEOUT} ${SSH_OPTS_EXTRA}"
fi

# ------------------- the remote audit script ------------------------
# This whole block is sent to and executed on the REMOTE host.
# It only reads system state; it makes no changes.
read -r -d '' REMOTE_SCRIPT <<'REMOTE_EOF'
set -u
BOLD=$'\033[1m'; RESET=$'\033[0m'
line() { printf '%s\n' "----------------------------------------------------------------------"; }
section() { echo; line; echo "## $1"; line; }

echo "HOSTNAME: $(hostname -f 2>/dev/null || hostname)"
echo "DATE:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "UPTIME:   $(uptime -p 2>/dev/null || uptime)"

section "OPERATING SYSTEM"
if [ -f /etc/os-release ]; then
    ( . /etc/os-release
      echo "  Distro:       ${PRETTY_NAME:-unknown}"
      echo "  Name:         ${NAME:-unknown}"
      echo "  Version:      ${VERSION:-unknown}"
      echo "  ID:           ${ID:-unknown}"
    )
else
    echo "  Distro:       $(uname -sr) (no /etc/os-release found)"
fi
echo "  Kernel:       $(uname -r)"
echo "  Architecture: $(uname -m)"
echo "  Hostname:     $(hostname -f 2>/dev/null || hostname)"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    echo "  Virtualization: $(systemd-detect-virt 2>/dev/null)"
fi
echo "  CPU cores:    $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null)"
echo "  Memory total: $(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
echo "  Disk usage (/):"
df -h / 2>/dev/null | sed 's/^/    /'
echo "  All mounted filesystems:"
df -hT 2>/dev/null | grep -Ev 'tmpfs|udev|overlay' | sed 's/^/    /'

# ---------------- Users ----------------
section "USERS (logins allowed, uid >= 1000, plus root)"
awk -F: '($3>=1000 && $1!="nobody") || $1=="root" {printf "  %-15s uid=%-6s shell=%s\n",$1,$3,$7}' /etc/passwd

section "CURRENTLY LOGGED IN USERS"
who 2>/dev/null || w 2>/dev/null || echo "  (who/w not available)"

section "USERS WITH SUDO / ADMIN RIGHTS"
if [ -f /etc/sudoers ]; then
    grep -Ev '^\s*#|^\s*$' /etc/sudoers 2>/dev/null | sed 's/^/  /'
fi
if [ -d /etc/sudoers.d ]; then
    for f in /etc/sudoers.d/*; do
        [ -f "$f" ] && grep -Ev '^\s*#|^\s*$' "$f" 2>/dev/null | sed 's/^/  /'
    done
fi
getent group sudo 2>/dev/null | sed 's/^/  group sudo: /'
getent group wheel 2>/dev/null | sed 's/^/  group wheel: /'

# ---------------- Running services ----------------
section "RUNNING SERVICES (systemd, active)"
if command -v systemctl >/dev/null 2>&1; then
    systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
        | awk '{printf "  %-40s %s\n",$1,$0}' | cut -c1-120
else
    echo "  systemctl not found, listing processes instead:"
    ps -eo comm --no-headers | sort -u | sed 's/^/  /'
fi

# ---------------- Listening ports / what's serving them ----------------
section "LISTENING PORTS (what's exposed on this server)"
if command -v ss >/dev/null 2>&1; then
    ss -tulnp 2>/dev/null | sed 's/^/  /'
elif command -v netstat >/dev/null 2>&1; then
    netstat -tulnp 2>/dev/null | sed 's/^/  /'
else
    echo "  ss/netstat not available"
fi

# ---------------- Web server check ----------------
section "WEB SERVER CHECK"
WEB_FOUND=0
for svc in nginx apache2 httpd caddy lighttpd traefik; do
    if command -v "$svc" >/dev/null 2>&1 || systemctl is-active --quiet "$svc" 2>/dev/null; then
        STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "installed (status unknown)")
        echo "  FOUND: $svc -> $STATUS"
        WEB_FOUND=1
    fi
done
if ss -tuln 2>/dev/null | grep -Eq ':(80|443|8080|8443)\s'; then
    echo "  Ports 80/443/8080/8443 are LISTENING"
    WEB_FOUND=1
fi
[ "$WEB_FOUND" -eq 0 ] && echo "  No web server detected"

# ---------------- Database check ----------------
section "DATABASE CHECK"
DB_FOUND=0
for db in mysqld mariadbd postgres mongod redis-server redis-sentinel memcached cassandra; do
    if pgrep -x "$db" >/dev/null 2>&1; then
        echo "  RUNNING: $db"
        DB_FOUND=1
    fi
done
for svc in mysql mariadb postgresql mongod redis redis-server memcached; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "  ACTIVE SERVICE: $svc"
        DB_FOUND=1
    fi
done
if ss -tuln 2>/dev/null | grep -Eq ':(3306|5432|27017|6379|11211|9042)\s'; then
    echo "  Common DB ports are LISTENING (3306/5432/27017/6379/11211/9042)"
    DB_FOUND=1
fi
[ "$DB_FOUND" -eq 0 ] && echo "  No database engine detected"

# ---------------- Docker check ----------------
section "DOCKER CHECK"
if command -v docker >/dev/null 2>&1; then
    echo "  Docker CLI installed: $(docker --version 2>/dev/null)"
    if systemctl is-active --quiet docker 2>/dev/null; then
        echo "  Docker daemon: ACTIVE"
        echo "  Running containers:"
        docker ps --format '    - {{.Names}} ({{.Image}}) status={{.Status}}' 2>/dev/null || echo "    (need permission - try sudo/adding user to docker group)"
    else
        echo "  Docker daemon: NOT ACTIVE / no permission to check"
    fi
else
    echo "  Docker not installed"
fi

# ---------------- Kubernetes (kubectl / kubelet) check ----------------
section "KUBERNETES CHECK"
if command -v kubectl >/dev/null 2>&1; then
    echo "  kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null)"
    echo "  Cluster context (if configured):"
    kubectl config current-context 2>/dev/null | sed 's/^/    /' || echo "    (no kubeconfig / not connected)"
else
    echo "  kubectl not installed"
fi
if command -v kubelet >/dev/null 2>&1 || systemctl is-active --quiet kubelet 2>/dev/null; then
    echo "  kubelet present: $(systemctl is-active kubelet 2>/dev/null || echo installed)"
fi
if command -v k3s >/dev/null 2>&1; then
    echo "  k3s installed: $(systemctl is-active k3s 2>/dev/null || echo installed)"
fi

# ---------------- Cron jobs ----------------
section "CRON JOBS"
echo "  System-wide crontab (/etc/crontab):"
[ -f /etc/crontab ] && grep -Ev '^\s*#|^\s*$' /etc/crontab 2>/dev/null | sed 's/^/    /' || echo "    (none)"

echo "  /etc/cron.d/*:"
if [ -d /etc/cron.d ]; then
    for f in /etc/cron.d/*; do
        [ -f "$f" ] && { echo "    -- $f --"; grep -Ev '^\s*#|^\s*$' "$f" | sed 's/^/    /'; }
    done
fi

echo "  Per-user crontabs:"
for u in $(awk -F: '($3>=1000 || $1=="root"){print $1}' /etc/passwd); do
    CRONTAB=$(crontab -l -u "$u" 2>/dev/null)
    if [ -n "$CRONTAB" ]; then
        echo "    -- user: $u --"
        echo "$CRONTAB" | grep -Ev '^\s*#|^\s*$' | sed 's/^/      /'
    fi
done

echo "  Systemd timers (active):"
if command -v systemctl >/dev/null 2>&1; then
    systemctl list-timers --all --no-pager 2>/dev/null | sed 's/^/    /'
fi

# ---------------- Installed applications / packages ----------------
section "INSTALLED PACKAGES (top-level, count + notable apps)"
if command -v dpkg >/dev/null 2>&1; then
    echo "  Package manager: dpkg/apt"
    echo "  Total packages installed: $(dpkg -l 2>/dev/null | grep -c '^ii')"
elif command -v rpm >/dev/null 2>&1; then
    echo "  Package manager: rpm/yum/dnf"
    echo "  Total packages installed: $(rpm -qa 2>/dev/null | wc -l)"
fi

echo "  Notable / commonly-relevant software detected:"
for app in nginx apache2 httpd mysql mariadb postgresql mongodb redis docker docker-ce containerd kubectl kubelet k3s git python3 python2 java openjdk node npm ruby php php-fpm golang jenkins ansible terraform prometheus grafana elasticsearch logstash kibana rabbitmq haproxy varnish certbot fail2ban ufw firewalld; do
    if command -v "$app" >/dev/null 2>&1; then
        VER=$("$app" --version 2>/dev/null | head -n1)
        echo "    - $app ${VER:+($VER)}"
    fi
done

# ---------------- Folder contents check ----------------
section "FOLDER CONTENTS CHECK"
IFS=',' read -ra FOLDERS_ARR <<< "${AUDIT_FOLDERS:-/opt,/var/www/html,/mnt,/home,/etc}"
for dir in "${FOLDERS_ARR[@]}"; do
    dir="$(echo "$dir" | xargs)"   # trim whitespace
    [ -z "$dir" ] && continue
    echo
    echo "  ==> $dir"
    if [ ! -e "$dir" ]; then
        echo "      (does not exist on this host)"
        continue
    fi
    if [ ! -d "$dir" ]; then
        echo "      (exists but is not a directory)"
        continue
    fi
    echo "      Size (du -sh):  $(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    echo "      Owner/perms:    $(stat -c '%U:%G %A' "$dir" 2>/dev/null)"
    echo "      Top-level contents:"
    ls -lAh "$dir" 2>/dev/null | tail -n +2 | awk '{printf "        %s\n",$0}' | head -50
    ITEMCOUNT=$(ls -A "$dir" 2>/dev/null | wc -l)
    if [ "$ITEMCOUNT" -gt 50 ]; then
        echo "        ... ($ITEMCOUNT items total, truncated to first 50)"
    fi

    case "$dir" in
        */home|/home)
            echo "      Per-user home directory sizes:"
            for uhome in "$dir"/*; do
                [ -d "$uhome" ] && printf "        %-10s %s\n" "$(du -sh "$uhome" 2>/dev/null | awk '{print $1}')" "$uhome"
            done
            ;;
        */var/www/html|/var/www/html|*/var/www|/var/www)
            echo "      Detected web content - looking for app/framework markers:"
            for marker in wp-config.php index.php index.html composer.json package.json artisan .env docker-compose.yml; do
                found=$(find "$dir" -maxdepth 3 -iname "$marker" 2>/dev/null | head -5)
                [ -n "$found" ] && echo "$found" | sed "s/^/        [$marker] /"
            done
            ;;
        */etc|/etc)
            echo "      Recently modified config files (last 20, top-level /etc):"
            find "$dir" -maxdepth 2 -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -20 | awk '{$1="";print "       "$0}'
            ;;
        */opt|/opt)
            echo "      (each subfolder under /opt is typically a separately-installed app)"
            ;;
        */mnt|/mnt)
            echo "      Mount points under here:"
            mount 2>/dev/null | grep "on $dir" | sed 's/^/        /'
            ;;
    esac
done

section "END OF REPORT"
REMOTE_EOF
# ---------------------------------------------------------------------

audit_one_host() {
    local raw_line="$1"
    local user="$DEFAULT_USER"
    local port="$DEFAULT_PORT"
    local host="$raw_line"

    # Parse "user@host:port" style entries
    if [[ "$host" == *"@"* ]]; then
        user="${host%%@*}"
        host="${host#*@}"
    fi
    if [[ "$host" == *":"* ]]; then
        port="${host##*:}"
        host="${host%%:*}"
    fi

    local safe_name
    safe_name=$(echo "${user}_${host}_${port}" | tr -c 'A-Za-z0-9_.-' '_')
    local out_file="${OUTPUT_DIR}/${safe_name}.txt"

    echo ">>> Auditing ${user}@${host}:${port} ..."

    {
        echo "======================================================================"
        echo " SERVER AUDIT: ${user}@${host}:${port}"
        echo " Run at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "======================================================================"
    } > "$out_file"

    local payload="export AUDIT_FOLDERS='${AUDIT_FOLDERS}'"$'\n'"${REMOTE_SCRIPT}"
    if $SSH_RUNNER ssh $SSH_BASE_OPTS -p "$port" "${user}@${host}" "bash -s" <<< "$payload" >> "$out_file" 2>>"$out_file"; then
        echo "    OK  -> $out_file"
        echo "STATUS: SUCCESS" >> "$out_file"
    else
        echo "    FAILED (see $out_file for details)"
        echo "STATUS: FAILED - could not connect or command errored" >> "$out_file"
    fi
}
export -f audit_one_host
export SSH_BASE_OPTS OUTPUT_DIR REMOTE_SCRIPT DEFAULT_USER DEFAULT_PORT AUDIT_FOLDERS SSH_RUNNER
export SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY AUDIT_SSH_PASSWORD

# ----------------------- build clean host list ------------------------
mapfile -t HOSTS < <(grep -Ev '^\s*#|^\s*$' "$SERVER_LIST")

echo "Loaded ${#HOSTS[@]} server(s) from $SERVER_LIST"
echo "Reports will be saved to: $OUTPUT_DIR"
echo

if [[ "$PARALLEL" -gt 1 ]]; then
    printf '%s\n' "${HOSTS[@]}" | xargs -I{} -P "$PARALLEL" bash -c 'audit_one_host "$@"' _ {}
else
    for h in "${HOSTS[@]}"; do
        audit_one_host "$h"
    done
fi

# ----------------------------- summary ---------------------------------
SUMMARY_FILE="${OUTPUT_DIR}/_SUMMARY.txt"
{
    echo "AUDIT SUMMARY - $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "======================================================================"
    for f in "${OUTPUT_DIR}"/*.txt; do
        [[ "$f" == "$SUMMARY_FILE" ]] && continue
        host_line=$(grep "SERVER AUDIT:" "$f" | head -1)
        status_line=$(grep "^STATUS:" "$f" | tail -1)
        web=$(awk '/## WEB SERVER CHECK/{flag=1;next}/^----/{if(flag){exit}}flag' "$f" | grep -c FOUND)
        db=$(awk '/## DATABASE CHECK/{flag=1;next}/^----/{if(flag){exit}}flag' "$f" | grep -Ec 'RUNNING|ACTIVE')
        docker=$(grep -q "Docker daemon: ACTIVE" "$f" && echo yes || echo no)
        k8s=$(grep -q "kubectl installed" "$f" && echo yes || echo no)
        printf "%-45s %-20s web:%-3s db:%-3s docker:%-3s kubectl:%-3s\n" \
            "$host_line" "$status_line" "$([[ $web -gt 0 ]] && echo yes || echo no)" \
            "$([[ $db -gt 0 ]] && echo yes || echo no)" "$docker" "$k8s"
    done
} > "$SUMMARY_FILE"

echo
echo "======================================================================"
echo "All done. Per-host reports + summary saved in: $OUTPUT_DIR"
echo "Summary file: $SUMMARY_FILE"
echo "======================================================================"
cat "$SUMMARY_FILE"