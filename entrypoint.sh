#!/bin/sh
set -eu

HOST_BIN=/host/usr/local/bin
HOST_CONF_DIR=/etc/containerd/conf.d
HOST_RUNSC_CONF=/etc/containerd/runsc.toml

install -D -m 0755 /usr/local/bin/runsc "${HOST_BIN}/runsc"
install -D -m 0755 /usr/local/bin/containerd-shim-runsc-v1 \
  "${HOST_BIN}/containerd-shim-runsc-v1"
install -D -m 0644 /etc/runsc.toml "${HOST_RUNSC_CONF}"
install -D -m 0644 /etc/containerd-gvisor.toml \
  "${HOST_CONF_DIR}/99-gvisor.toml"

# containerd does not implement a configuration reload. Restart it only after
# validating the complete configuration, including all imported drop-ins.
nsenter -t 1 -m -u -n -i -- \
  /usr/local/bin/containerd --config /etc/containerd/config.toml config dump >/dev/null
nsenter -t 1 -m -u -n -i -- systemctl restart containerd
nsenter -t 1 -m -u -n -i -- systemctl is-active --quiet containerd

echo "gVisor binaries and containerd configuration installed successfully"
