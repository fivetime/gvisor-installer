#!/bin/sh
# Reproduces a CRI-O crash: a VM-type (runtime_type = "vm") pod that was
# running when CRI-O restarted is stopped afterwards.
#   $1: the installer image (registers gVisor's shim as the handler "runsc")
#   $2: what to do after the restart: stopp (stop the pod right away),
#       inspect (crictl inspectp/ps first, then stop)
set -u
IMAGE=$1 MODE=$2
sudo docker run --rm --privileged --pid=host -v /:/host \
    -e GVISOR_CRI=crio -e GVISOR_HANDLER=runsc "$IMAGE" install || exit 1
crio --version
sudo crio config 2>/dev/null | sed -n '/runtimes.runsc\]/,/^$/p'

cat > /tmp/pod.json <<'J'
{"metadata": {"name": "vm-pod", "namespace": "default", "uid": "vm-pod"},
 "log_directory": "/tmp/vm-pod", "linux": {"cgroup_parent": "vm_pod.slice"}}
J
cat > /tmp/ctr.json <<'J'
{"metadata": {"name": "app"}, "image": {"image": "docker.io/library/busybox:1.37"},
 "command": ["sleep", "3600"], "log_path": "app.log"}
J
sudo crictl pull docker.io/library/busybox:1.37 >/dev/null
pod=$(sudo crictl runp --runtime runsc /tmp/pod.json)
ctr=$(sudo crictl create "$pod" /tmp/ctr.json /tmp/pod.json)
sudo crictl start "$ctr"
sudo crictl ps
pid=$(systemctl show crio -p MainPID --value)
echo "== restart CRI-O (pid $pid)"
sudo systemctl restart crio
sleep 5
echo "== CRI-O pid now $(systemctl show crio -p MainPID --value)"
if [ "$MODE" = inspect ]; then
    sudo crictl ps -a
    sudo crictl inspectp "$pod" | head -20
fi
echo "== stop the pod"
sudo crictl stopp "$pod"; echo "stopp exit $?"
sleep 5
echo "== CRI-O after the stop: $(systemctl show crio -p MainPID -p NRestarts -p ActiveState --value | tr '\n' ' ')"
sudo journalctl -u crio --no-pager -o cat | tee /tmp/crio.log >/dev/null
echo "== panic header and the panicking goroutine"
grep -n -m1 -B2 -A40 -E '^(panic|fatal error):' /tmp/crio.log || echo "no panic in the log"
