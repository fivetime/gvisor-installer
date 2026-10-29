FROM alpine:3.24

ARG TARGETARCH
# A dated gVisor release (YYYYMMDD.N), see GVISOR_RELEASE. Pinned, not
# "latest": the image says which runsc it carries, and the same tag always
# installs the same runsc.
ARG GVISOR_RELEASE

# curl and jq: the uninstall dispatcher and the node label talk to the
# Kubernetes API. util-linux: nsenter, to restart the host's CRI runtime.
RUN apk add --no-cache ca-certificates curl jq util-linux zstd

# From 20260831.0 on, gVisor publishes one tarball per architecture instead of
# runsc and containerd-shim-runsc-v1 on their own, and runsc starts a sandbox
# through the sidecars in the tarball's gvisor-bin/, next to its executable.
# A runsc without them refuses to start any sandbox, so the whole tree is kept.
RUN set -eu; \
    test -n "${GVISOR_RELEASE}" || { echo "GVISOR_RELEASE is not set" >&2; exit 1; }; \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://storage.googleapis.com/gvisor/releases/release/${GVISOR_RELEASE}/${arch}"; \
    mkdir -p /tmp/gvisor /gvisor; cd /tmp/gvisor; \
    curl -fsSLO "${url}/gvisor.tar.zstd"; \
    curl -fsSLO "${url}/gvisor.tar.zstd.sha512"; \
    sha512sum -c gvisor.tar.zstd.sha512; \
    zstd -dc gvisor.tar.zstd | tar -x -C /gvisor; \
    ls -la /gvisor /gvisor/gvisor-bin; \
    test -x /gvisor/runsc; \
    test -x /gvisor/containerd-shim-runsc-v1; \
    test -x /gvisor/gvisor-bin/gvisor_sentry; \
    echo "${GVISOR_RELEASE}" > /gvisor/RELEASE; \
    cd /; rm -rf /tmp/gvisor

COPY --chmod=0755 installer.sh /usr/local/bin/gvisor-installer

ENTRYPOINT ["/usr/local/bin/gvisor-installer"]
CMD ["install"]
