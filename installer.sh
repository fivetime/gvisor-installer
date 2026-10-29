#!/bin/sh
# gvisor-installer: install gVisor on the host it runs on and register it as a
# runtime handler with the host's CRI runtime (containerd or CRI-O).
#
#   gvisor-installer install          install or update, restart the CRI runtime
#                                     only when its configuration changed
#   gvisor-installer uninstall        remove what install wrote
#   gvisor-installer uninstall-nodes  Kubernetes only: run "uninstall" on every
#                                     node carrying the node label (helm
#                                     pre-delete hook)
#
# install and uninstall need the host's root at $HOST_ROOT and the host's PID
# namespace (to restart the CRI runtime through systemd): in Kubernetes a
# privileged pod with hostPID and a hostPath of /, under Podman
# --privileged --pid=host -v /:/host.
#
# Everything is configured through the environment; see README.md.
set -eu

HOST_ROOT=${HOST_ROOT:-/host}
PREFIX=${GVISOR_PREFIX:-/opt/gvisor}
BIN_DIR=${GVISOR_BIN_DIR:-/usr/local/bin}
HANDLER=${GVISOR_HANDLER:-gvisor}
PLATFORM=${GVISOR_PLATFORM:-systrap}
# Extra runsc flags, "name=value" separated by spaces (e.g. "net-raw=true").
RUNSC_FLAGS=${GVISOR_RUNSC_FLAGS:-}
# auto, or one or more of "containerd crio".
CRI=${GVISOR_CRI:-auto}
RESTART_CRI=${GVISOR_RESTART_CRI:-true}
CONTAINERD_CONFIG=${GVISOR_CONTAINERD_CONFIG:-/etc/containerd/config.toml}
CONTAINERD_DROPIN_DIR=${GVISOR_CONTAINERD_DROPIN_DIR:-/etc/containerd/conf.d}
CRIO_DROPIN_DIR=${GVISOR_CRIO_DROPIN_DIR:-/etc/crio/crio.conf.d}
# Seconds the CRI runtime has to come back after a restart.
RESTART_TIMEOUT=${GVISOR_RESTART_TIMEOUT:-60}
# Uninstall refuses while gVisor sandboxes run on the host, unless this is set:
# their runsc would be gone, so the CRI runtime could no longer stop them.
FORCE=${GVISOR_FORCE:-false}
# Kubernetes: the node label set to "true" once the node can run gVisor pods.
NODE_LABEL=${GVISOR_NODE_LABEL:-}
NODE_NAME=${NODE_NAME:-}

SRC=/gvisor
RELEASE_DIR=$PREFIX/release
HANDLER_DIR=$PREFIX/handlers/$HANDLER
DROPIN_NAME=90-gvisor-$HANDLER
SA=/var/run/secrets/kubernetes.io/serviceaccount

log() { echo "gvisor-installer: $*"; }
die() { echo "gvisor-installer: error: $*" >&2; exit 1; }

# Runs a command on the host, in its namespaces, with the host's binaries.
host() { nsenter -t 1 -m -u -i -n -p -- "$@"; }

# Writes $2 to $1 unless it already holds exactly that. Returns 0 when the file
# changed, 1 when it did not.
write_if_changed() {
    if [ -f "$1" ] && printf '%s' "$2" | cmp -s - "$1"; then
        return 1
    fi
    mkdir -p "$(dirname "$1")"
    printf '%s' "$2" > "$1.tmp"
    mv "$1.tmp" "$1"
    return 0
}

detect_cri() {
    if [ "$CRI" != auto ]; then
        echo "$CRI" | tr ',' ' '
        return
    fi
    # kubelet talks to one CRI runtime. When both run (containerd under
    # dockerd, CRI-O for kubelet), CRI-O is the one kubelet uses: name both in
    # GVISOR_CRI to register the handler with each.
    if host systemctl is-active --quiet crio; then
        echo crio
    elif host systemctl is-active --quiet containerd; then
        echo containerd
    else
        die "neither crio nor containerd is active on this host; set GVISOR_CRI"
    fi
}

# Waits for unit $1 to be active. Fails as soon as systemd gives up on it or
# schedules a restart after a failure.
cri_up() {
    end=$(( $(date +%s) + RESTART_TIMEOUT ))
    while [ "$(date +%s)" -lt "$end" ]; do
        case $(host systemctl show "$1" -p ActiveState -p SubState --value | tr '\n' ' ') in
            'active '*) return 0 ;;
            *auto-restart*|'failed '*|'inactive '*) return 1 ;;
        esac
        sleep 1
    done
    return 1
}

# Restarts CRI runtime $1 after install or uninstall changed its drop-in $2.
# The previous drop-in is at $3 (absent if there was none). If $1 does not come
# back up, the previous drop-in is put back and $1 restarted on it: a node must
# never be left without its CRI runtime because of a configuration this script
# wrote. The rejected drop-in is kept at $2.rejected under $HANDLER_DIR so that
# a retry (a DaemonSet's init container) does not take the runtime down again.
restart_cri() {
    cri=$1 dropin=$2 prev=$3
    if [ "$RESTART_CRI" != true ]; then
        log "$cri configuration changed; restart $cri yourself (GVISOR_RESTART_CRI=$RESTART_CRI)"
        rm -f "$prev"
        return
    fi
    # Neither runtime reloads runtime handlers: a reload, or a SIGHUP to
    # CRI-O, leaves the new handler unknown. Running containers survive a
    # restart of either.
    log "restarting $cri"
    if host systemctl restart "$cri" && cri_up "$cri"; then
        rm -f "$prev"
        return
    fi
    why=$(host journalctl -u "$cri" -n 20 --no-pager -o cat 2>&1 | grep -iE 'fatal|error' | tail -3 || true)
    mkdir -p "$HOST_ROOT$HANDLER_DIR"
    rejected=$HOST_ROOT$HANDLER_DIR/$(basename "$dropin").rejected
    if [ -f "$dropin" ]; then cp "$dropin" "$rejected"; else : > "$rejected"; fi
    if [ -f "$prev" ]; then mv "$prev" "$dropin"; else rm -f "$dropin"; fi
    log "$cri did not come back up; restored its previous configuration"
    host systemctl reset-failed "$cri" 2>/dev/null || true
    if host systemctl restart "$cri" && cri_up "$cri"; then
        die "$cri failed to start with the new configuration and runs on the previous one again.
$cri said:
$why"
    fi
    die "$cri does not start even on its previous configuration; the host needs a person now.
$cri said:
$why"
}

# Writes drop-in $2 (content $3) for CRI runtime $1 and restarts $1 if it
# changed. Refuses a drop-in that $1 already failed to start with.
apply_dropin() {
    cri=$1 dropin=$2 content=$3
    rejected=$HOST_ROOT$HANDLER_DIR/$(basename "$dropin").rejected
    if [ -f "$rejected" ] && printf '%s' "$content" | cmp -s - "$rejected"; then
        die "$cri failed to start with this configuration before ($rejected); not trying again. Fix the configuration, or delete that file to retry"
    fi
    prev=$HOST_ROOT$HANDLER_DIR/$(basename "$dropin").prev
    rm -f "$prev"
    if [ -f "$dropin" ]; then mkdir -p "$(dirname "$prev")"; cp "$dropin" "$prev"; fi
    if ! write_if_changed "$dropin" "$content"; then
        rm -f "$prev"
        return 1
    fi
    "check_$cri" || { if [ -f "$prev" ]; then mv "$prev" "$dropin"; else rm -f "$dropin"; fi; exit 1; }
    restart_cri "$cri" "$dropin" "$prev"
    rm -f "$rejected"
}

# runsc flags as TOML key = "value" lines, for the containerd shim.
runsc_flags_toml() {
    printf '  platform = "%s"\n' "$PLATFORM"
    for f in $RUNSC_FLAGS; do
        printf '  %s = "%s"\n' "${f%%=*}" "${f#*=}"
    done
}

install_release() {
    [ -x "$SRC/runsc" ] || die "this image carries no gVisor at $SRC"
    want=$(cat "$SRC/RELEASE")
    have=$(cat "$HOST_ROOT$RELEASE_DIR/RELEASE" 2>/dev/null || true)
    if [ "$want" = "$have" ] &&
       cmp -s "$SRC/runsc" "$HOST_ROOT$RELEASE_DIR/runsc"; then
        log "gVisor $want already installed at $RELEASE_DIR"
    else
        # Copied beside the old tree and swapped in with renames, so runsc is
        # never missing or half written for a sandbox starting meanwhile.
        rm -rf "$HOST_ROOT$RELEASE_DIR.new" "$HOST_ROOT$RELEASE_DIR.old"
        mkdir -p "$HOST_ROOT$PREFIX"
        cp -a "$SRC" "$HOST_ROOT$RELEASE_DIR.new"
        if [ -e "$HOST_ROOT$RELEASE_DIR" ]; then
            mv "$HOST_ROOT$RELEASE_DIR" "$HOST_ROOT$RELEASE_DIR.old"
        fi
        mv "$HOST_ROOT$RELEASE_DIR.new" "$HOST_ROOT$RELEASE_DIR"
        rm -rf "$HOST_ROOT$RELEASE_DIR.old"
        log "installed gVisor $want at $RELEASE_DIR (was: ${have:-none})"
    fi
    # Links for people and for containerd, which finds the shim in PATH. runsc
    # finds gvisor-bin/ beside its real path, so a link still works.
    mkdir -p "$HOST_ROOT$BIN_DIR"
    for b in runsc containerd-shim-runsc-v1; do
        ln -sfn "$RELEASE_DIR/$b" "$HOST_ROOT$BIN_DIR/$b"
    done
}

install_containerd() {
    conf=$HOST_ROOT$CONTAINERD_CONFIG
    [ -f "$conf" ] || die "$CONTAINERD_CONFIG does not exist; containerd's built-in defaults import no drop-ins"
    # A drop-in is only read when the main configuration imports it.
    grep -Eq "^[[:space:]]*imports[[:space:]]*=.*${CONTAINERD_DROPIN_DIR}/" "$conf" ||
        die "$CONTAINERD_CONFIG does not import $CONTAINERD_DROPIN_DIR; add: imports = [\"$CONTAINERD_DROPIN_DIR/*.toml\"]"
    version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$conf" | head -1)
    # A drop-in must use its importer's schema: a version 3 section in a
    # version 2 document names a plugin that does not exist there and is
    # ignored without a word.
    case "${version:-1}" in
        2) plugin='"io.containerd.grpc.v1.cri".containerd' ;;
        3|4) plugin="'io.containerd.cri.v1.runtime'.containerd" ;;
        *) die "$CONTAINERD_CONFIG is version ${version:-1}; only versions 2 to 4 are supported" ;;
    esac

    write_if_changed "$HOST_ROOT$HANDLER_DIR/runsc.toml" "# Written by gvisor-installer.
binary_name = \"$RELEASE_DIR/runsc\"

[runsc_config]
$(runsc_flags_toml)
" || true

    if ! apply_dropin containerd "$HOST_ROOT$CONTAINERD_DROPIN_DIR/$DROPIN_NAME.toml" "# Written by gvisor-installer.
version = $version

[plugins.$plugin.runtimes.$HANDLER]
  runtime_type = \"io.containerd.runsc.v1\"

[plugins.$plugin.runtimes.$HANDLER.options]
  TypeUrl = \"io.containerd.runsc.v1.options\"
  ConfigPath = \"$HANDLER_DIR/runsc.toml\"
"; then
        log "containerd already has the $HANDLER handler"
    fi
}

# Checks, before the restart, that containerd reads the new drop-in: it would
# otherwise find out at its restart, with every pod on the node waiting for it.
check_containerd() {
    host containerd --config "$CONTAINERD_CONFIG" config dump 2>&1 | grep -q "containerd.runtimes.$HANDLER\]" && return
    echo "gvisor-installer: error: containerd does not see the $HANDLER handler in its configuration; drop-in reverted" >&2
    return 1
}

install_crio() {
    # CRI-O runs gVisor through containerd-shim-runsc-v1, as a "vm" runtime
    # like Kata: as a plain OCI runtime under conmon, runsc cannot start a
    # pod's app containers. See gVisor's g3doc/user_guide/containerd/crio.md.
    version=$(host crio --version 2>/dev/null | sed -n 's/^crio version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
    # shellcheck disable=SC2086 # two words on purpose
    set -- $version
    [ "${1:-0}" -gt 1 ] || [ "${2:-0}" -ge 37 ] ||
        die "CRI-O ${1:-?}.${2:-?} cannot run gVisor's shim; CRI-O 1.37 or later is needed"
    host crio config 2>/dev/null | grep -Eq '^[[:space:]]*selinux[[:space:]]*=[[:space:]]*true' &&
        die "CRI-O runs with selinux = true, which gVisor does not support"

    # With the systemd cgroup manager (CRI-O's default) the cgroup paths are
    # systemd's slice:prefix:name, which runsc only parses with
    # --systemd-cgroup.
    cgroup_manager=$(host crio config 2>/dev/null |
        sed -n 's/^[[:space:]]*cgroup_manager[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' | head -1)
    systemd_cgroup=
    case " $RUNSC_FLAGS " in
        *" systemd-cgroup="*) ;;
        *) [ "${cgroup_manager:-systemd}" != systemd ] || systemd_cgroup='  systemd-cgroup = "true"
' ;;
    esac
    # grouping: a pod's app containers join the shim of its sandbox, which
    # CRI-O starts for the pause container, instead of starting their own.
    write_if_changed "$HOST_ROOT$HANDLER_DIR/crio-runsc.toml" "# Written by gvisor-installer.
binary_name = \"$RELEASE_DIR/runsc\"
grouping = true

[runsc_config]
$(runsc_flags_toml)
$systemd_cgroup" || true

    if ! apply_dropin crio "$HOST_ROOT$CRIO_DROPIN_DIR/$DROPIN_NAME.conf" "# Written by gvisor-installer.
[crio.runtime.runtimes.$HANDLER]
runtime_path = \"$RELEASE_DIR/containerd-shim-runsc-v1\"
runtime_config_path = \"$HANDLER_DIR/crio-runsc.toml\"
runtime_type = \"vm\"
runtime_root = \"/run/runsc-$HANDLER\"
"; then
        log "CRI-O already has the $HANDLER handler"
    fi
}

# crio config parses the drop-ins but does not validate the runtimes;
# restart_cri's rollback covers the rest.
check_crio() {
    host crio config 2>/dev/null | grep -q "crio.runtime.runtimes.$HANDLER\]" && return
    echo "gvisor-installer: error: CRI-O does not see the $HANDLER handler in its configuration; drop-in reverted" >&2
    return 1
}

# Kubernetes API, with the pod's service account.
api() {
    method=$1 path=$2; shift 2
    h=$KUBERNETES_SERVICE_HOST
    case $h in *:*) h="[$h]" ;; esac
    curl -sS --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" \
        -X "$method" "https://$h:$KUBERNETES_SERVICE_PORT$path" "$@"
}

# Sets the node label to $1 ("true", or null to remove it). Outside Kubernetes,
# or with no label configured, does nothing.
label_node() {
    [ -n "$NODE_LABEL" ] && [ -n "$NODE_NAME" ] && [ -f "$SA/token" ] || return 0
    code=$(api PATCH "/api/v1/nodes/$NODE_NAME" -o /tmp/label.out -w '%{http_code}' \
        -H 'Content-Type: application/merge-patch+json' \
        -d "{\"metadata\":{\"labels\":{\"$NODE_LABEL\":$1}}}")
    [ "$code" = 200 ] || die "labeling node $NODE_NAME failed (HTTP $code): $(cat /tmp/label.out)"
    log "node $NODE_NAME: $NODE_LABEL=$1"
}

do_install() {
    case $HANDLER in
        *[!a-z0-9-]*|'') die "handler \"$HANDLER\" must be lowercase letters, digits and dashes" ;;
    esac
    install_release
    for c in $(detect_cri); do
        case $c in
            containerd) install_containerd ;;
            crio) install_crio ;;
            *) die "unknown CRI runtime \"$c\"; use containerd or crio" ;;
        esac
    done
    label_node '"true"'
    log "done: runtime handler $HANDLER, gVisor $(cat "$SRC/RELEASE"), platform $PLATFORM"
}

# Removes drop-in $2 of CRI runtime $1, if there is one, and restarts $1 if it
# runs.
remove_dropin() {
    [ -f "$2" ] || return 0
    prev=$HOST_ROOT$HANDLER_DIR/$(basename "$2").prev
    mkdir -p "$(dirname "$prev")"
    mv "$2" "$prev"
    log "removed ${2#"$HOST_ROOT"}"
    if host systemctl is-active --quiet "$1"; then
        restart_cri "$1" "$2" "$prev"
    else
        rm -f "$prev"
    fi
}

do_uninstall() {
    if [ "$FORCE" != true ] && pgrep -f '^runsc-sandbox' >/dev/null 2>&1; then
        die "gVisor sandboxes are running on this host; delete their pods first (or set GVISOR_FORCE=true)"
    fi
    # The node stops attracting gVisor pods before the handler goes away.
    label_node null
    # Removed from every runtime that has it, whatever detect_cri says now.
    remove_dropin crio "$HOST_ROOT$CRIO_DROPIN_DIR/$DROPIN_NAME.conf"
    remove_dropin containerd "$HOST_ROOT$CONTAINERD_DROPIN_DIR/$DROPIN_NAME.toml"
    rm -rf "$HOST_ROOT$HANDLER_DIR"
    rmdir "$HOST_ROOT$PREFIX/handlers" 2>/dev/null || true
    # The release and its links stay while another handler still uses them.
    if [ ! -d "$HOST_ROOT$PREFIX/handlers" ]; then
        for b in runsc containerd-shim-runsc-v1; do
            if [ "$(readlink "$HOST_ROOT$BIN_DIR/$b" 2>/dev/null)" = "$RELEASE_DIR/$b" ]; then
                rm -f "$HOST_ROOT$BIN_DIR/$b"
            fi
        done
        rm -rf "$HOST_ROOT$RELEASE_DIR"
        rmdir "$HOST_ROOT$PREFIX" 2>/dev/null || true
        log "removed $PREFIX"
    fi
    log "done: runtime handler $HANDLER removed"
}

# Helm pre-delete hook. Deletes the installer DaemonSet first, so that no
# installer pod puts gVisor back, then runs the uninstall Job template
# ($JOB_TEMPLATE, JSON) once on each node carrying $GVISOR_NODE_LABEL.
# $INSTALLER_SELECTOR is the label selector of the DaemonSet's pods.
do_uninstall_nodes() {
    : "${POD_NAMESPACE:?}" "${DAEMONSET:?}" "${INSTALLER_SELECTOR:?}" "${JOB_TEMPLATE:?}" "${NODE_LABEL:?}"
    timeout=${UNINSTALL_TIMEOUT:-600}
    ns=$POD_NAMESPACE

    api DELETE "/apis/apps/v1/namespaces/$ns/daemonsets/$DAEMONSET" -o /dev/null
    sel=$(jq -rn --arg s "$INSTALLER_SELECTOR" '$s | @uri')
    i=0
    while [ "$(api GET "/api/v1/namespaces/$ns/pods?labelSelector=$sel" | jq '.items | length')" != 0 ]; do
        i=$((i + 1)); [ $i -lt 60 ] || die "installer pods still exist 120s after deleting DaemonSet $DAEMONSET"
        sleep 2
    done

    key=$(jq -rn --arg s "$NODE_LABEL" '$s | @uri')
    nodes=$(api GET "/api/v1/nodes?labelSelector=$key" | jq -r '.items[].metadata.name')
    if [ -z "$nodes" ]; then
        log "no node carries $NODE_LABEL; nothing to uninstall"
        return 0
    fi

    jobs=""
    for n in $nodes; do
        name="$DAEMONSET-uninstall-$(printf '%s' "$n" | sha1sum | cut -c1-10)"
        api DELETE "/apis/batch/v1/namespaces/$ns/jobs/$name?propagationPolicy=Background" -o /dev/null
        i=0
        while [ "$(api GET "/apis/batch/v1/namespaces/$ns/jobs/$name" -o /dev/null -w '%{http_code}')" = 200 ]; do
            i=$((i + 1)); [ $i -lt 30 ] || die "old Job $name is not going away"
            sleep 2
        done
        code=$(jq --arg name "$name" --arg node "$n" \
                '.metadata.name = $name | .metadata.labels["gvisor-installer/node"] = $node | .spec.template.spec.nodeName = $node' \
                "$JOB_TEMPLATE" |
            api POST "/apis/batch/v1/namespaces/$ns/jobs" -H 'Content-Type: application/json' -d @- -o /dev/null -w '%{http_code}')
        [ "$code" = 201 ] || die "creating Job $name for node $n failed (HTTP $code)"
        log "node $n: uninstall Job $name"
        jobs="$jobs $n:$name"
    done

    failed=0
    deadline=$(( $(date +%s) + timeout ))
    for j in $jobs; do
        n=${j%%:*} name=${j#*:}
        while :; do
            st=$(api GET "/apis/batch/v1/namespaces/$ns/jobs/$name" | jq -r '
                if (.status.succeeded // 0) > 0 then "ok"
                elif (.status.failed // 0) > 0 then "failed"
                else "running" end')
            [ "$st" = running ] || break
            [ "$(date +%s)" -lt "$deadline" ] || { st=timeout; break; }
            sleep 3
        done
        log "node $n: $st"
        [ "$st" = ok ] || failed=$((failed + 1))
    done
    [ $failed = 0 ] || die "uninstall failed on $failed node(s); see the Jobs' pod logs in namespace $ns"
}

case "${1:-install}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    uninstall-nodes) do_uninstall_nodes ;;
    *) die "usage: gvisor-installer install|uninstall|uninstall-nodes" ;;
esac
