#!/bin/sh
# End-to-end test on the runner itself with CRI-O, the installer run the way
# the Quadlet unit runs it: a drop-in CRI-O does not start with is rolled back
# and not retried, a sandbox runs under gVisor with the runsc flags,
# uninstall refuses while it runs, and uninstall leaves the host clean.
set -eu
IMAGE=$1
# runsc's logs, for the workflow to show when this fails.
RUNSC_DEBUG="debug=true debug-log=/tmp/runsc/"
fail() { echo "FAIL: $*" >&2; exit 1; }
installer() {
    docker run --rm --privileged --pid=host -v /:/host \
        -e GVISOR_CRI=crio -e GVISOR_RUNSC_FLAGS="net-raw=true $RUNSC_DEBUG" "$@"
}
started() { systemctl show crio -p ActiveEnterTimestampMonotonic --value; }
DROPIN=/etc/crio/crio.conf.d/90-gvisor-gvisor.conf

crio --version

echo "== a configuration CRI-O cannot start with is rolled back"
# Stands in for a drop-in CRI-O rejects: CRI-O does not start while it exists.
sudo mkdir -p /etc/systemd/system/crio.service.d
printf '[Service]\nExecStartPre=/bin/sh -c "! test -e %s"\n' $DROPIN |
    sudo tee /etc/systemd/system/crio.service.d/reject-gvisor.conf
sudo systemctl daemon-reload
if installer "$IMAGE" install; then fail "install succeeded although CRI-O did not start"; fi
systemctl is-active crio || fail "CRI-O was left down"
test ! -e $DROPIN || fail "the rejected drop-in was left in place"
test -f /opt/gvisor/handlers/gvisor/90-gvisor-gvisor.conf.rejected || fail "the rejected drop-in was not kept"

echo "== and not tried again"
before=$(started)
if installer "$IMAGE" install; then fail "install succeeded the second time"; fi
test "$(started)" = "$before" || fail "CRI-O was restarted for a configuration it rejected before"
sudo rm /etc/systemd/system/crio.service.d/reject-gvisor.conf /opt/gvisor/handlers/gvisor/90-gvisor-gvisor.conf.rejected
sudo systemctl daemon-reload

echo "== install"
installer "$IMAGE" install
systemctl is-active crio
cat $DROPIN /opt/gvisor/handlers/gvisor/crio-runsc.toml
test ! -e /opt/gvisor/handlers/gvisor/90-gvisor-gvisor.conf.rejected || fail "the rejected drop-in outlived a good install"
before=$(started)
installer "$IMAGE" install
test "$(started)" = "$before" || fail "an unchanged install restarted CRI-O"

echo "== a pod under gVisor"
cat > /tmp/pod.json <<'EOF'
{"metadata": {"name": "gvisor-test", "namespace": "default", "uid": "gvisor-test"},
 "log_directory": "/tmp/gvisor-test",
 "linux": {"cgroup_parent": "gvisor_test.slice"}}
EOF
cat > /tmp/ctr.json <<'EOF'
{"metadata": {"name": "test"},
 "image": {"image": "docker.io/library/busybox:1.37"},
 "command": ["sh", "-c", "dmesg; ping -c 1 127.0.0.1; sleep 600"],
 "log_path": "test.log",
 "linux": {"security_context": {"capabilities": {"add_capabilities": ["NET_RAW"]}}}}
EOF
sudo crictl pull docker.io/library/busybox:1.37
pod=$(sudo crictl runp --runtime gvisor /tmp/pod.json)
ctr=$(sudo crictl create "$pod" /tmp/ctr.json /tmp/pod.json)
sudo crictl start "$ctr"
sleep 3
sudo crictl logs "$ctr" | tee /tmp/ctr.log
grep -q 'Starting gVisor' /tmp/ctr.log || fail "the pod did not run under gVisor"
grep -q '1 packets received' /tmp/ctr.log || fail "ping failed under gVisor"
pgrep -a -f '^runsc-sandbox' | head -1 | tee /tmp/sandbox.args
grep -q -- '--net-raw=true' /tmp/sandbox.args || fail "runscFlags did not reach runsc"
grep -q -- '--platform=systrap' /tmp/sandbox.args || fail "platform did not reach runsc"
grep -q -- '--systemd-cgroup=true' /tmp/sandbox.args || fail "runsc runs without --systemd-cgroup under CRI-O's systemd cgroup manager"

echo "== uninstall must refuse while a gVisor pod runs"
if installer "$IMAGE" uninstall; then fail "uninstall went ahead with a gVisor pod running"; fi
test -f $DROPIN || fail "the refused uninstall removed the drop-in"

echo "== removing the gvisor handler is refused while its pod runs"
before_rename=$(started)
if installer -e GVISOR_HANDLER=runsc -e GVISOR_REMOVE_HANDLERS=gvisor "$IMAGE" install; then
    fail "removing the gvisor handler went ahead with its pod running"
fi
# Refused before anything changed: no runsc handler, and no CRI-O restart,
# which would leave CRI-O 1.37 unable to stop this pod (it crashes in
# runtimeVM.StopContainer for a VM-type sandbox it did not start).
test "$(started)" = "$before_rename" || fail "the refused rename restarted CRI-O"
crio config 2>/dev/null | grep -q 'runtimes.runsc\]' && fail "the refused rename added the runsc handler"
test -f $DROPIN || fail "the refused removal took the gvisor drop-in away"

sudo crictl stopp "$pod"
# runsc fails the first delete under CRI-O, which has unmounted the rootfs
# that held the sandbox's filestore by then (runsc ignores ENOENT for shared
# mounts' filestores but not for the rootfs'). Its state is gone by then, and
# a retry, as kubelet's, succeeds.
sudo crictl rmp "$pod" || sudo crictl rmp "$pod"
echo "== the gvisor handler goes once its pod is gone"
installer -e GVISOR_HANDLER=runsc -e GVISOR_REMOVE_HANDLERS=gvisor "$IMAGE" install
crio config 2>/dev/null | grep -q 'runtimes.gvisor\]' && fail "CRI-O still has the gvisor handler"
crio config 2>/dev/null | grep -q 'runtimes.runsc\]' || fail "CRI-O lost the runsc handler"
for f in $DROPIN /opt/gvisor/handlers/gvisor; do
    test ! -e "$f" || fail "$f left after removing the gvisor handler"
done
test -x /opt/gvisor/release/runsc || fail "removing a handler removed gVisor"

echo "== uninstall"
installer -e GVISOR_HANDLER=runsc "$IMAGE" uninstall
systemctl is-active crio || fail "CRI-O is down after uninstall"
for f in /opt/gvisor /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 $DROPIN /etc/crio/crio.conf.d/90-gvisor-runsc.conf; do
    if [ -e "$f" ] || [ -L "$f" ]; then fail "$f left behind"; fi
done
crio config 2>/dev/null | grep -qE 'runtimes.(gvisor|runsc)\]' && fail "CRI-O still has a gVisor handler"
echo "PASS"
