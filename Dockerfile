# ---------------- Stage 1: builder ----------------
# Match the runtime base (debian12 / bookworm) so glibc versions align with
# gcr.io/distroless/base-debian12. Building on debian:13 against a debian12
# runtime causes glibc symbol mismatches that break freeipmi tools silently.
FROM debian:12-slim AS builder

ARG IPMI_EXPORTER_VERSION=1.10.1
ARG TARGETARCH=amd64

RUN apt-get update && apt-get install -y --no-install-recommends \
        wget \
        ca-certificates \
        tar \
        ipmitool \
        freeipmi-tools \
        libfreeipmi17 \
        findutils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download ipmi_exporter
RUN wget -q https://github.com/prometheus-community/ipmi_exporter/releases/download/v${IPMI_EXPORTER_VERSION}/ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-${TARGETARCH}.tar.gz && \
    tar xf ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-${TARGETARCH}.tar.gz && \
    mv ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-${TARGETARCH} ipmi_exporter

# ---------------- dependency collection ----------------
RUN mkdir -p \
        /out/usr/local/bin \
        /out/usr/lib/x86_64-linux-gnu \
        /out/usr/share/freeipmi \
        /out/etc/ssl/certs \
        /out/etc/freeipmi \
        /out/var/cache/freeipmi \
        /out/tmp \
        /out/home/nonroot

# Copy binaries
RUN cp /usr/bin/ipmitool  /out/usr/local/bin/
RUN cp /usr/sbin/ipmi-sensors /usr/sbin/ipmi-dcmi /usr/sbin/ipmi-chassis \
       /usr/sbin/bmc-info /usr/sbin/ipmi-sel /usr/sbin/ipmi-raw \
       /out/usr/local/bin/ 2>/dev/null || true
RUN cp -r ipmi_exporter /out/usr/local/bin/

# Collect ALL shared library dependencies for every binary.
# Resolve symlinks and copy both the real file and the symlink name so
# the dynamic linker finds everything under /usr/lib/x86_64-linux-gnu.
RUN set -eu; \
    for bin in \
        /out/usr/local/bin/ipmitool \
        /out/usr/local/bin/ipmi-sensors \
        /out/usr/local/bin/ipmi-dcmi \
        /out/usr/local/bin/ipmi-chassis \
        /out/usr/local/bin/bmc-info \
        /out/usr/local/bin/ipmi-sel \
        /out/usr/local/bin/ipmi-raw \
        /out/usr/local/bin/ipmi_exporter/ipmi_exporter; \
    do \
        [ -f "$bin" ] || continue; \
        ldd "$bin" 2>/dev/null \
          | awk '/=>/ { print $3 } /^\t\// { print $1 }' \
          | grep -E '^/' || true; \
    done \
    | sort -u \
    | while read -r lib; do \
        [ -z "$lib" ] && continue; \
        real=$(readlink -f "$lib"); \
        cp -v "$real" /out/usr/lib/x86_64-linux-gnu/ 2>/dev/null || true; \
        base=$(basename "$lib"); \
        realbase=$(basename "$real"); \
        if [ "$base" != "$realbase" ]; then \
            ln -sf "$realbase" "/out/usr/lib/x86_64-linux-gnu/$base"; \
        fi; \
    done

# CRITICAL: freeipmi dlopen()s its interpreter/config modules at runtime —
# ldd does NOT see these. Without them the exporter runs but returns no
# sensor metrics. Copy the whole plugin tree + shared data files.
RUN cp -a /usr/lib/x86_64-linux-gnu/freeipmi /out/usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
RUN cp -a /usr/share/freeipmi/. /out/usr/share/freeipmi/ 2>/dev/null || true
RUN cp -a /etc/freeipmi/. /out/etc/freeipmi/ 2>/dev/null || true

# Copy the dynamic linker
RUN real=$(readlink -f /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2); \
    cp -v "$real" /out/usr/lib/x86_64-linux-gnu/ && \
    ln -sf "$(basename $real)" /out/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2

# Copy CA certificates
RUN cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/ca-certificates.crt

# Minimal NSS files
RUN printf 'root:x:0:0:root:/root:/sbin/nologin\nnonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin\n' \
        > /out/etc/passwd && \
    printf 'root:x:0:\nnonroot:x:65532:\nnobody:x:65534:\n' > /out/etc/group && \
    printf 'hosts: dns files\n' > /out/etc/nsswitch.conf

# Make freeipmi's runtime-writable dirs owned by nonroot (UID 65532)
RUN chown -R 65532:65532 /out/var/cache/freeipmi /out/tmp /out/home/nonroot

# ---------------- Stage 2: distroless runtime ----------------
FROM gcr.io/distroless/base-debian12:nonroot

COPY --from=builder /out/usr/  /usr/
COPY --from=builder /out/etc/  /etc/
COPY --from=builder --chown=65532:65532 /out/var/  /var/
COPY --from=builder --chown=65532:65532 /out/tmp/  /tmp/
COPY --from=builder --chown=65532:65532 /out/home/ /home/

# Tell the dynamic linker where our libs live and give freeipmi a writable
# home for its SDR cache fallback.
ENV LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu \
    HOME=/home/nonroot \
    TMPDIR=/tmp

EXPOSE 9290

USER nonroot

ENTRYPOINT ["/usr/local/bin/ipmi_exporter/ipmi_exporter"]
CMD ["--config.file=/config.yml"]
