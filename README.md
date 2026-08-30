# 基于 Podman Quadlet 部署 gVisor（runsc）节点运行时

本文采用“Quadlet 安装器 + 宿主机原生运行时”的方式，为使用 containerd 的 Kubernetes 节点安装 gVisor。安装器负责写入二进制和配置；Pod 最终由宿主机 containerd 直接调用 gVisor。

> 本文已于 2026-08-30 在 `container1` 实测通过：Ubuntu 26.04、Podman 5.7.0、containerd 2.3.4（配置 version 4）、gVisor `release-20260817.0`、Kubernetes 1.36。本文的 containerd 2.x 配置不适用于 CRI-O 节点。

## 一、前置检查

```bash
podman --version
containerd --version
systemctl is-active containerd
test -e /dev/kvm && echo "KVM available"
grep -n '^version\|^imports' /etc/containerd/config.toml
```

本文使用 `platform = "kvm"`；没有 `/dev/kvm` 时改用 `systrap`。containerd 主配置必须导入 drop-in，例如：

```toml
version = 4
imports = ['/etc/containerd/conf.d/*.toml']
```

containerd 1.x 的 CRI 插件路径不同，不能直接使用本文配置。

## 二、准备安装器

本仓库提供了经过实测的完整文件：

```text
./
├── Dockerfile
├── containerd-gvisor.toml
├── entrypoint.sh
├── gvisor-installer.container
├── runsc.toml
├── runtimeclass.yaml
└── test-pod.yaml
```

克隆仓库后，构建上下文就是仓库根目录。Quadlet 文件需要单独安装到
`/etc/containers/systemd/`。

### `runsc.toml`

```toml
platform = "kvm"
```

runsc 使用顶层 TOML 选项；原文的 `[log] level = "info"` 不是有效配置。

### `containerd-gvisor.toml`

```toml
version = 4

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.gvisor]
  runtime_type = 'io.containerd.runsc.v1'

  [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.gvisor.options]
    TypeUrl = 'io.containerd.runsc.v1.options'
    ConfigPath = '/etc/containerd/runsc.toml'
```

### `entrypoint.sh`

```sh
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

nsenter -t 1 -m -u -n -i -- \
  /usr/local/bin/containerd --config /etc/containerd/config.toml config dump >/dev/null
nsenter -t 1 -m -u -n -i -- systemctl restart containerd
nsenter -t 1 -m -u -n -i -- systemctl is-active --quiet containerd

echo "gVisor binaries and containerd configuration installed successfully"
```

containerd 没有受支持的配置热重载流程，因此必须使用 `restart`，不能使用原文的 `systemctl reload containerd`。重启通常不终止已有容器，但仍应在变更窗口操作。

### `Dockerfile`

```dockerfile
FROM alpine:3.22

ARG TARGETARCH
ARG GVISOR_CHANNEL=release/latest

RUN apk add --no-cache ca-certificates curl util-linux \
    && case "${TARGETARCH}" in \
         amd64) gvisor_arch=x86_64 ;; \
         arm64) gvisor_arch=aarch64 ;; \
         *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && base_url="https://storage.googleapis.com/gvisor/releases/${GVISOR_CHANNEL}/${gvisor_arch}" \
    && curl -fsSLo /usr/local/bin/runsc "${base_url}/runsc" \
    && curl -fsSLo /usr/local/bin/containerd-shim-runsc-v1 \
       "${base_url}/containerd-shim-runsc-v1" \
    && chmod 0755 /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1

COPY runsc.toml /etc/runsc.toml
COPY containerd-gvisor.toml /etc/containerd-gvisor.toml
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

必须同时安装 `runsc` 和 `containerd-shim-runsc-v1`。`release/latest` 在本次实测中解析为 `release-20260817.0`。

## 三、构建与部署 Quadlet

```bash
cd /opt/gvisor-installer
podman build --pull=always -t localhost/gvisor-installer:v1 .
```

创建 `/etc/containers/systemd/gvisor-installer.container`：

```ini
[Unit]
Description=gVisor host runtime installer
Wants=network-online.target
After=network-online.target containerd.service

[Container]
Image=localhost/gvisor-installer:v1
ContainerName=gvisor-installer
PodmanArgs=--pid=host --privileged
SecurityLabelDisable=true
Volume=/usr/local/bin:/host/usr/local/bin:rw
Volume=/etc/containerd:/etc/containerd:rw

[Service]
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Podman 5.7 Quadlet 应通过 `PodmanArgs` 传入 PID 和特权参数；原文的 `PID=host` 与 `Privileged=true` 会导致配置无效或 service 无法生成。安装结束后无需 `tail -f` 驻留，oneshot 更合适。

```bash
systemctl daemon-reload
systemctl start gvisor-installer.service
systemctl status gvisor-installer.service --no-pager
journalctl -u gvisor-installer.service -n 50 --no-pager
```

不要对生成的 Quadlet service 执行 `systemctl enable`；启用关系由 `.container` 文件的 `[Install]` 在生成时建立。

## 四、验证节点运行时

```bash
/usr/local/bin/runsc --version
test -x /usr/local/bin/containerd-shim-runsc-v1
systemctl is-active containerd
containerd --config /etc/containerd/config.toml config dump \
  | sed -n '/runtimes.gvisor/,+8p'
```

预期 runsc 显示目标版本、shim 可执行、containerd 为 `active`，且配置 dump 存在 `runtimes.gvisor`。`crictl info | grep gvisor` 在不同版本上不一定可靠，最终应以真实 Pod 为准。

## 五、Kubernetes 端到端验证

先创建 RuntimeClass：

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: gvisor
```

然后修改 `test-pod.yaml` 中的节点名，确保 Pod 只调度到已安装 gVisor 的
containerd 节点。目标节点如有污点，还需要按实际情况添加 toleration：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-gvisor-pod
spec:
  runtimeClassName: gvisor
  nodeSelector:
    kubernetes.io/hostname: container1
  restartPolicy: Never
  containers:
    - name: test
      image: docker.io/library/alpine:3.22
      command: ["sh", "-c", "uname -a; sleep 3600"]
```

```bash
kubectl apply -f runtimeclass.yaml
kubectl apply -f test-pod.yaml
kubectl wait --for=condition=Ready pod/test-gvisor-pod --timeout=180s
kubectl get pod test-gvisor-pod -o wide
kubectl exec test-gvisor-pod -- uname -a
kubectl exec test-gvisor-pod -- sh -c 'dmesg | head -3'
```

本次实测输出：

```text
Linux test-gvisor-pod 4.19.0-gvisor ... x86_64 Linux
[   0.000000] Starting gVisor...
```

这同时验证了 RuntimeClass handler、containerd shim、runsc、KVM 平台和 Kubernetes 调度链路。

## 六、升级

```bash
cd /opt/gvisor-installer
podman build --pull=always --no-cache -t localhost/gvisor-installer:v2 .
sed -i 's/gvisor-installer:v1/gvisor-installer:v2/' \
  /etc/containers/systemd/gvisor-installer.container
systemctl daemon-reload
systemctl restart gvisor-installer.service
```

升级过程会重启 containerd，不应描述为“无缝平滑更新”。升级后必须重新执行第四、五节验证。
