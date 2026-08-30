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
