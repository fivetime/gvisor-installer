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

echo "== removing the gvisor handler is refused while its pod runs"
# The RuntimeClass's handler cannot change: the chart drops it here.
helm upgrade gv charts/gvisor-installer -n $NS --reuse-values \
    --set gvisor.handler=runsc --set 'gvisor.removeHandlers={gvisor}' --set runtimeClass.create=false
i=0
until kubectl -n $NS logs -l app.kubernetes.io/component=installer -c install --tail=-1 2>/dev/null |
        grep -q 'handler gvisor still run'; do
    i=$((i + 1)); [ $i -lt 60 ] || fail "removing the gvisor handler did not refuse while its pod runs"
    sleep 3
done
on_node 'containerd config dump' | grep -q 'runtimes.gvisor\]' || fail "the refused removal took the gvisor handler away"
on_node 'containerd config dump' | grep -q 'runtimes.runsc\]' && fail "the refused rename added the runsc handler"

kubectl delete pod gvisor-test --wait --timeout=120s
echo "== the gvisor handler goes once its pod is gone"
# Restarted now rather than after the init container's back-off.
kubectl -n $NS delete pod -l app.kubernetes.io/component=installer --wait=false
kubectl -n $NS rollout status ds/gv-gvisor-installer --timeout=5m
on_node 'containerd config dump' | grep -q 'runtimes.gvisor\]' && fail "containerd still has the gvisor handler"
on_node 'containerd config dump' | grep -q 'runtimes.runsc\]' || fail "containerd lost the runsc handler"
on_node 'test ! -e /opt/gvisor/handlers/gvisor && test -x /opt/gvisor/release/runsc' || fail "wrong files after removing the gvisor handler"

echo "== uninstall must refuse while a gVisor pod runs"
kubectl create -f - <<'EOF2'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: runsc
handler: runsc
EOF2
sed 's/runtimeClassName: gvisor/runtimeClassName: runsc/' examples/test-pod.yaml | kubectl apply -f -
kubectl wait pod gvisor-test --for=condition=Ready --timeout=180s
if helm uninstall gv -n $NS --wait --timeout 3m; then fail "uninstall went ahead with a gVisor pod running"; fi
kubectl -n $NS get jobs
on_node 'test -x /opt/gvisor/release/runsc' || fail "the refused uninstall removed gVisor"

kubectl delete pod gvisor-test --wait --timeout=120s
kubectl delete runtimeclass runsc
echo "== uninstall"
helm uninstall gv -n $NS --wait --timeout 5m
labels=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels}')
case $labels in *gvisor-installer*) fail "node label left behind: $labels" ;; esac
on_node 'ls -la /opt/gvisor /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /etc/containerd/conf.d/90-gvisor-gvisor.toml /etc/containerd/conf.d/90-gvisor-runsc.toml 2>&1' | grep -v 'No such file' && fail "files left behind"
on_node 'containerd config dump' | grep -qE 'runtimes.(gvisor|runsc)' && fail "containerd still has a gVisor handler"
kubectl get runtimeclass gvisor 2>/dev/null && fail "RuntimeClass left behind"
echo "PASS"
