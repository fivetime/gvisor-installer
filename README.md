# gvisor-installer

把 gVisor（`runsc`）装到宿主机上，并注册成 CRI 运行时（containerd 或 CRI-O）的一个 runtime handler。
同一个镜像有两种用法：

- **Kubernetes**：Helm chart，按 nodeSelector / affinity 选择节点安装，`helm uninstall` 时清理这些节点；
- **单机**：Podman Quadlet 服务，开机执行一次安装。

gVisor 是被宿主机的 CRI 运行时直接执行的程序，不是常驻服务，所以它必须装在宿主机的文件系统里，没法像 dockerd 那样整个跑在容器里。
这个镜像就是一个安装器：把文件放到宿主机、写 CRI 配置、必要时重启 CRI 运行时。

## 镜像里装的是什么

`GVISOR_RELEASE` 文件里钉死的 gVisor 发行版（当前 `20261019.0`），chart 的 `appVersion` 与之一致。
20261026.0 先不用：它的 runsc 拒绝加入已有的 UTS 命名空间（google/gvisor#12984），
而 CRI-O 总是为 Pod 固定 UTS 命名空间，CRI-O 下的 Pod 全都起不来（CI 里验证过）。
构建时下载 `gvisor.tar.zstd` 并校验 sha512，整个 tarball 都保留：从 20260831.0 起 gVisor 只发布 tarball，
而且 `runsc` 要靠它旁边 `gvisor-bin/` 里的 `gvisor_sentry` 等 sidecar 启动沙箱，缺了就拒绝启动任何 pod。

宿主机上的布局：

```text
/opt/gvisor/release/                 runsc、containerd-shim-runsc-v1、gvisor-bin/、RELEASE（升级时整体替换）
/opt/gvisor/handlers/<handler>/      runsc.toml（containerd 用）、crio-runsc.toml（CRI-O 用），即 shim 配置和 runsc 参数
/usr/local/bin/runsc                 -> /opt/gvisor/release/runsc
/usr/local/bin/containerd-shim-runsc-v1 -> /opt/gvisor/release/containerd-shim-runsc-v1
/etc/containerd/conf.d/90-gvisor-<handler>.toml   或   /etc/crio/crio.conf.d/90-gvisor-<handler>.conf
```

## Kubernetes（Helm）

```bash
helm install gvisor oci://ghcr.io/fivetime/charts/gvisor-installer --version 0.1.2 \
    -n gvisor-system --create-namespace \
    --set nodeSelector.gvisor=enabled
kubectl label node <节点> gvisor=enabled
```

- 选中的节点上，DaemonSet 的 init 容器执行安装，完成后给节点打 `gvisor-installer.fivetime.io/installed=true`。
  chart 建的 RuntimeClass（默认名 `gvisor`）只调度到带这个标签的节点，所以 pod 不会落到还没装好的节点上。
- 新节点满足选择条件时自动安装；节点重启后 pod 重建，会再检查一次（没有变化就什么都不做）。
- **CRI 运行时只在它的配置真的变了时才重启**（第一次安装、换了 handler 或平台），运行中的容器不受影响。
- `helm uninstall`：pre-delete hook 先删掉 DaemonSet，再在每个带上述标签的节点上跑一个清理 Job，
  删除 drop-in、重启 CRI 运行时、删除 `/opt/gvisor` 和两个链接，最后去掉标签。
  **节点上还有 gVisor pod 在运行时，清理会拒绝执行，`helm uninstall` 失败**，release 保持原样；
  删掉那些 pod 后再执行一次即可。
- 节点不再被选中（比如去掉了选择用的标签）时，DaemonSet 的 pod 会离开，但 gVisor 留在节点上，
  `installed` 标签也留着，RuntimeClass 照样能调度过去。要撤掉一个节点，可以在节点上用下面的单机卸载命令。

主要的 values（全部见 `charts/gvisor-installer/values.yaml`）：

| 值 | 默认 | 说明 |
|---|---|---|
| `gvisor.handler` | `gvisor` | runtime handler 名，也是 RuntimeClass 的 handler |
| `gvisor.removeHandlers` | `[]` | 要从节点上删掉的旧 handler 名，见下文"改 handler 名" |
| `gvisor.platform` | `systrap` | `systrap` 不需要 `/dev/kvm`，嵌套虚拟化里也能用；有 `/dev/kvm` 时 `kvm` 更快 |
| `gvisor.runscFlags` | `{}` | 额外的 runsc 参数，如 `{net-raw: "true"}` 允许 pod 用 raw socket（ping） |
| `gvisor.cri` | `auto` | `auto`：CRI-O 在运行就配 CRI-O，否则配 containerd；也可以写 `containerd`、`crio` 或 `"crio containerd"` |
| `gvisor.restartCRI` | `true` | 配置变化时重启 CRI 运行时；关掉的话要自己重启，handler 才会生效 |
| `nodeSelector` / `affinity` / `tolerations` | 空 | 装到哪些节点；空的 nodeSelector 表示所有没有不可容忍污点的节点 |
| `nodeLabel` | `gvisor-installer.fivetime.io/installed` | 装好后打的标签 |
| `runtimeClass.create` / `.name` | `true` / `gvisor` | 集群里已经有同名 RuntimeClass 时，改名或设 `create: false` |
| `runtimeClass.overhead` | `{}` | 如 `{cpu: 250m, memory: 64Mi}` |

## 单机（Podman Quadlet）

```bash
cp quadlet/gvisor-installer.container /etc/containers/systemd/
systemctl daemon-reload
systemctl start gvisor-installer.service
journalctl -u gvisor-installer.service --no-pager
```

设置通过 `.container` 文件里的 `Environment=` 传入，见下表。不要对生成的 service 执行 `systemctl enable`，
启用关系由 `[Install]` 段在生成时建立。

卸载（同样适用于 Kubernetes 里撤掉单个节点）：

```bash
podman run --rm --privileged --pid=host -v /:/host ghcr.io/fivetime/gvisor-installer:0.1.0 uninstall
rm /etc/containers/systemd/gvisor-installer.container && systemctl daemon-reload
```

## 安装器的环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `GVISOR_HANDLER` | `gvisor` | handler 名（小写字母、数字、`-`） |
| `GVISOR_REMOVE_HANDLERS` | 空 | 安装时删掉的旧 handler，空格分隔 |
| `GVISOR_PLATFORM` | `systrap` | runsc 的 `--platform` |
| `GVISOR_RUNSC_FLAGS` | 空 | 空格分隔的 `名=值`，如 `net-raw=true` |
| `GVISOR_CRI` | `auto` | `containerd`、`crio`，或两者都写 |
| `GVISOR_RESTART_CRI` | `true` | |
| `GVISOR_RESTART_TIMEOUT` | `60` | 重启后等 CRI 运行时恢复的秒数，超时即回滚 |
| `GVISOR_PREFIX` | `/opt/gvisor` | |
| `GVISOR_BIN_DIR` | `/usr/local/bin` | 放两个链接的目录；containerd 要在 PATH 里找到 shim |
| `GVISOR_CONTAINERD_CONFIG` | `/etc/containerd/config.toml` | |
| `GVISOR_CONTAINERD_DROPIN_DIR` | `/etc/containerd/conf.d` | 必须被主配置的 `imports` 引入 |
| `GVISOR_CRIO_DROPIN_DIR` | `/etc/crio/crio.conf.d` | |
| `GVISOR_FORCE` | `false` | 卸载时不检查运行中的沙箱 |
| `GVISOR_NODE_LABEL` | 空 | 仅 Kubernetes：装好后给节点打的标签 |

## 改 handler 名

换 `gvisor.handler` 后，节点上会多注册一个新 handler，旧的原样保留，已经在跑的沙箱不受影响。
确认没有 Pod 再用旧 handler 后，把它写进 `gvisor.removeHandlers` 再升级一次：安装器删掉旧 handler 的
drop-in 和 `/opt/gvisor/handlers/<旧名>/`，重启 CRI 运行时，gVisor 本身和节点标签不动。
节点上还有经旧 handler 启动的沙箱时，安装器在改动任何东西之前就拒绝并报错（CRI-O 看沙箱 bundle 里 OCI spec 的 `io.kubernetes.cri-o.RuntimeHandler` 注解，
containerd 用宿主机的 `ctr` 看运行中任务记录的 shim 配置路径），删掉那些 Pod 后 DaemonSet 会自动重试。

RuntimeClass 的 handler 字段建好后不能改：`runtimeClass.create: true` 时换 handler，
`helm upgrade` 会失败。先删掉 RuntimeClass（运行中的 Pod 不受影响）再升级，chart 会按新 handler 重建。

单机：`GVISOR_REMOVE_HANDLERS`，空格分隔。

## 对 CRI 运行时的要求

- **containerd** 2.x 或 1.7，配置 version 2–4。主配置必须引入 drop-in 目录，安装器不会改主配置：

  ```toml
  imports = ["/etc/containerd/conf.d/*.toml"]
  ```

  drop-in 按主配置的 version 写，写完先用 `containerd config dump` 确认 handler 生效，不生效就撤回 drop-in 并报错，不会重启。
  runsc 参数放在 shim 配置的 `[runsc_config]` 段。
- **CRI-O** 1.37 或更新，`selinux = false`（gVisor 不支持 SELinux 标签）。按 gVisor 的
  [CRI-O 文档](https://gvisor.dev/docs/user_guide/containerd/crio/)，handler 是
  `runtime_type = "vm"` 的 `containerd-shim-runsc-v1`（和 Kata 一样），shim 配置带 `grouping = true`，
  让 Pod 里的应用容器加入 pause 容器的沙箱。把 runsc 当普通 OCI 运行时交给 conmon 是行不通的。
  CRI-O 用 systemd cgroup 驱动（默认）时自动加上 `systemd-cgroup = "true"`。
  已知问题：删除 Pod 时 runsc 第一次会报 `failed to delete filestore file`（CRI-O 已先卸载了 rootfs），
  kubelet 重试一次即成功，不影响使用。
- 两者都不支持热加载 handler，所以配置变化后要 `systemctl restart`。

## 重启失败时的回滚

重启 CRI 运行时后，如果它在 `GVISOR_RESTART_TIMEOUT` 秒内没起来，安装器会：

1. 把 drop-in 恢复成写之前的样子（原来没有就删掉），再重启一次；
2. 把被拒绝的 drop-in 存成 `/opt/gvisor/handlers/<handler>/<drop-in 文件名>.rejected`，以错误退出，带上运行时日志里的报错。

之后同样内容的 drop-in 不会再试（DaemonSet 的 init 容器重试也不会再把运行时弄挂），
改了配置会生成不同的 drop-in，可以直接再装；要原样重试就删掉那个 `.rejected` 文件。

## 和容器化的 dockerd 一起用

dockerd 跑在容器里时，要把宿主机的 `/opt/gvisor` 挂进去，并在 `daemon.json` 里直接指向真实路径，
而不是挂 `/usr/local/bin/runsc` 这个链接（挂进去的是文件本身，`gvisor-bin/` 不会跟着进去，沙箱会起不来）：

```json
{ "runtimes": { "runsc": { "path": "/opt/gvisor/release/runsc", "runtimeArgs": ["--platform=systrap"] } } }
```

## 构建与发布

`.github/workflows/ci.yaml`：

- 每次 push 和 PR：shellcheck、`helm lint`，再做两组端到端测试：
  - kind（containerd）里用 chart 安装、跑 gVisor pod、改 handler 名（旧 handler 在用时拒绝删除）、
    确认卸载在 pod 运行时会拒绝、卸载后节点干净；
  - runner 上装 CRI-O 1.37，按 Quadlet 的方式跑安装器：CRI-O 起不来时回滚且不再重试、
    跑 gVisor pod（含 ping 和 runsc 参数）、改 handler 名、卸载拒绝与清理；
- 每次 push：多架构镜像推到 `ghcr.io/fivetime/gvisor-installer:sha-<commit>`；
- `v<chart version>` 标签：镜像加上 `:<chart version>` 标签，chart 推到 `oci://ghcr.io/fivetime/charts/gvisor-installer`。

升级 gVisor：改 `GVISOR_RELEASE` 和 chart 的 `appVersion`，升 chart 的 `version`，打标签。
