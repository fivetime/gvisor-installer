#!/bin/sh
# End-to-end test on a kind cluster (containerd): install with the chart, run
# a pod under gVisor, check that uninstall refuses while it runs, then
# uninstall and check that the node is clean.
set -eu
IMAGE_REPO=$1 IMAGE_TAG=$2
NODE=${NODE:-kind-control-plane}
NS=gvisor-system
on_node() { docker exec "$NODE" sh -c "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

on_node 'grep -n imports /etc/containerd/config.toml; sed -n "1,3p" /etc/containerd/config.toml'

helm install gv charts/gvisor-installer -n $NS --create-namespace \
    --set image.repository="$IMAGE_REPO" --set image.tag="$IMAGE_TAG" --set image.pullPolicy=Never \
    --set-string gvisor.runscFlags.net-raw=true \
    --set 'tolerations[0].operator=Exists' --wait --timeout 5m
kubectl -n $NS rollout status ds/gv-gvisor-installer --timeout=5m
kubectl -n $NS logs ds/gv-gvisor-installer -c install
kubectl wait node "$NODE" --for=jsonpath='{.metadata.labels.gvisor-installer\.fivetime\.io/installed}'=true --timeout=60s

kubectl apply -f examples/test-pod.yaml
kubectl wait pod gvisor-test --for=condition=Ready --timeout=180s
sleep 2
kubectl logs gvisor-test | tee /tmp/pod.log
grep -q 'Starting gVisor' /tmp/pod.log || fail "the pod did not run under gVisor"
on_node 'ps -eo args' | grep '^runsc-sandbox' | head -1 | tee /tmp/sandbox.args
grep -q -- '--net-raw=true' /tmp/sandbox.args || fail "runscFlags did not reach runsc"
grep -q -- '--platform=systrap' /tmp/sandbox.args || fail "platform did not reach runsc"

echo "== uninstall must refuse while a gVisor pod runs"
if helm uninstall gv -n $NS --wait --timeout 3m; then fail "uninstall went ahead with a gVisor pod running"; fi
kubectl -n $NS get jobs
on_node 'test -x /opt/gvisor/release/runsc' || fail "the refused uninstall removed gVisor"

kubectl delete pod gvisor-test --wait --timeout=120s
echo "== uninstall"
helm uninstall gv -n $NS --wait --timeout 5m
labels=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels}')
case $labels in *gvisor-installer*) fail "node label left behind: $labels" ;; esac
on_node 'ls -la /opt/gvisor /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /etc/containerd/conf.d/90-gvisor-gvisor.toml 2>&1' | grep -v 'No such file' && fail "files left behind"
on_node 'containerd config dump' | grep -q 'runtimes.gvisor' && fail "containerd still has the gvisor handler"
kubectl get runtimeclass gvisor 2>/dev/null && fail "RuntimeClass left behind"
echo "PASS"
