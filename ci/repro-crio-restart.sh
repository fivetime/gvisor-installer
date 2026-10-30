#!/bin/sh
# Reproduces a CRI-O crash: a VM-type (runtime_type = "vm") pod that was
# running when CRI-O restarted is stopped afterwards.
#   $1: runtime: gvisor, kata-go or kata-rs
#   $2: KillMode for crio.service: default (the unit's, control-group) or
#       process
#   $3: the gvisor-installer image (gvisor only)
set -u
RUNTIME=$1 KILLMODE=$2 IMAGE=${3:-}
HANDLER=vm

shims() { pgrep -f "containerd-shim-(runsc-v1|kata-v2)" || true; }
vmprocs() { pgrep -f '^runsc-sandbox|qemu-system|cloud-hypervisor' || true; }
show() {
    for p in "$@"; do
        printf '  pid %s: %s\n      cgroup %s\n' "$p" \
            "$(tr '\0' ' ' < /proc/"$p"/cmdline | cut -c1-90)" "$(cat /proc/"$p"/cgroup)"
    done
}

case $RUNTIME in
gvisor)
    sudo docker run --rm --privileged --pid=host -v /:/host \
        -e GVISOR_CRI=crio -e GVISOR_HANDLER=$HANDLER "$IMAGE" install || exit 1
    ;;
kata-go|kata-rs)
    sudo tar --zstd -xf /tmp/kata-static.tar.zst -C /
    sudo tar --zstd -xf /tmp/kata-go-static.tar.zst -C /
    if [ "$RUNTIME" = kata-go ]; then
        shim=/opt/kata/bin/containerd-shim-kata-v2
        cfg=/opt/kata/share/defaults/kata-containers/configuration-qemu.toml
    else
        shim=/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
        cfg=$(find /opt/kata/share/defaults/kata-containers -name 'configuration-qemu-runtime-rs.toml' | head -1)
    fi
    ls -l "$shim" "$cfg" || exit 1
    printf '[crio.runtime.runtimes.%s]\nruntime_path = "%s"\nruntime_type = "vm"\nruntime_root = "/run/vc"\nruntime_config_path = "%s"\nprivileged_without_host_devices = true\n' \
        $HANDLER "$shim" "$cfg" | sudo tee /etc/crio/crio.conf.d/90-vm.conf
    sudo systemctl restart crio
    ;;
esac
if [ "$KILLMODE" = process ]; then
    sudo mkdir -p /etc/systemd/system/crio.service.d
    printf '[Service]\nKillMode=process\n' | sudo tee /etc/systemd/system/crio.service.d/killmode.conf
    sudo systemctl daemon-reload
    sudo systemctl restart crio
fi
# CRI-O made its overlay home a private mount at its first start; Kata's
# shim would not see container root filesystems in it.
sudo mount --make-shared /var/lib/containers/storage/overlay 2>/dev/null || true
crio --version | head -1
echo "crio.service KillMode: $(systemctl show crio -p KillMode --value)"

cat > /tmp/pod.json <<'J'
{"metadata": {"name": "vm-pod", "namespace": "default", "uid": "vm-pod"},
 "log_directory": "/tmp/vm-pod", "linux": {"cgroup_parent": "vm_pod.slice"}}
J
cat > /tmp/ctr.json <<'J'
{"metadata": {"name": "app"}, "image": {"image": "docker.io/library/busybox:1.37"},
 "command": ["sleep", "3600"], "log_path": "app.log"}
J
sudo crictl pull docker.io/library/busybox:1.37 >/dev/null
pod=$(sudo crictl runp --runtime $HANDLER /tmp/pod.json) || exit 1
ctr=$(sudo crictl create "$pod" /tmp/ctr.json /tmp/pod.json) || exit 1
sudo crictl start "$ctr" || exit 1
sudo crictl ps
echo "== before the restart: CRI-O pid $(systemctl show crio -p MainPID --value)"
echo " shims:"; show $(shims)
echo " sandbox/VM processes:"; show $(vmprocs)

echo "== restart CRI-O"
sudo systemctl restart crio
sleep 5
echo "== after the restart: CRI-O pid $(systemctl show crio -p MainPID --value)"
echo " shims:"; show $(shims)
echo " sandbox/VM processes:"; show $(vmprocs)
sudo crictl ps -a

echo "== stop the pod"
sudo crictl stopp "$pod"; echo "stopp exit $?"
sleep 5
echo "== CRI-O after the stop: $(systemctl show crio -p MainPID -p NRestarts -p ActiveState --value | tr '\n' ' ')"
sleep 15
sudo crictl rmp "$pod" || sudo crictl rmp "$pod"; echo "rmp exit $?"
echo "== left on the host after the pod is gone"
echo " shims:"; show $(shims)
echo " sandbox/VM processes:"; show $(vmprocs)

sudo journalctl -u crio --no-pager -o cat | tee /tmp/crio.log >/dev/null
echo "== restore warnings"
grep -E 'Error updating the container status|shim address|reconnect to shim|marking container stopped' /tmp/crio.log | cut -c1-300
echo "== panic header and the panicking goroutine"
grep -n -m1 -A20 -E '^(panic|fatal error):' /tmp/crio.log || echo "no panic in the log"
