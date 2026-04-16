# ---------------- Stage 1: builder ----------------
FROM debian:13 AS builder

ARG IPMI_EXPORTER_VERSION=1.10.1

RUN apt-get update && apt-get install -y --no-install-recommends \
        wget \
        tar \
        ipmitool \
        freeipmi-tools \
        findutils \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download ipmi_exporter
RUN wget -q https://github.com/prometheus-community/ipmi_exporter/releases/download/v${IPMI_EXPORTER_VERSION}/ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz && \
    tar xvf ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz && \
    mv ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64 ipmi_exporter

# ---------------- dependency collection ----------------
RUN mkdir -p \
        /out/usr/local/bin \
        /out/usr/local/lib \
        /out/usr/lib/x86_64-linux-gnu \
        /out/etc/ssl/certs \
        /out/etc/freeipmi

# Copy binaries
RUN cp /usr/bin/ipmitool        /out/usr/local/bin/ || true
RUN cp /usr/sbin/ipmi-*         /out/usr/local/bin/ || true
RUN cp -r ipmi_exporter         /out/usr/local/bin/

# Collect ALL shared library dependencies for every binary.
# Resolve symlinks and copy both the real file and the symlink name so
# the dynamic linker finds everything under /usr/lib/x86_64-linux-gnu.
RUN for bin in \
        /out/usr/local/bin/ipmitool \
        /out/usr/local/bin/ipmi-* \
        /out/usr/local/bin/ipmi_exporter/ipmi_exporter; \
    do \
        ldd "$bin" 2>/dev/null \
          | awk '/=>/ { print $3 } /^\// { print $1 }' \
          | grep -E '^/' \
          || true; \
    done \
    | sort -u \
    | while read lib; do \
        # skip anything that would land under /lib (a symlink in distroless)
        echo "$lib"; \
    done \
    | while read lib; do \
        real=$(readlink -f "$lib"); \
        cp -v "$real" /out/usr/lib/x86_64-linux-gnu/ 2>/dev/null || true; \
        base=$(basename "$lib"); \
        realbase=$(basename "$real"); \
        if [ "$base" != "$realbase" ]; then \
            ln -sf "$realbase" "/out/usr/lib/x86_64-linux-gnu/$base" 2>/dev/null || true; \
        fi; \
    done

# Copy the dynamic linker — resolve its real path so we get the actual file.
# Place it under /usr/lib/x86_64-linux-gnu (safe, not a symlink in distroless).
RUN real=$(readlink -f /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2); \
    cp -v "$real" /out/usr/lib/x86_64-linux-gnu/ && \
    ln -sf "$(basename $real)" /out/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 || true

# Copy freeipmi runtime config/SDR data
RUN cp -a /etc/freeipmi/. /out/etc/freeipmi/ 2>/dev/null || true

# Copy CA certificates
RUN cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/ca-certificates.crt

# Minimal NSS files
RUN printf 'root:x:0:0:root:/root:/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin\n' \
        > /out/etc/passwd && \
    printf 'root:x:0:\nnobody:x:65534:\n' > /out/etc/group && \
    printf 'hosts: dns files\n' > /out/etc/nsswitch.conf


# ---------------- Stage 2: distroless runtime ----------------
FROM gcr.io/distroless/base-debian12:nonroot

# Copy binaries and their libs into paths that are real directories
# (not symlinks) in distroless — avoids the BuildKit symlink conflict.
COPY --from=builder /out/usr/  /usr/
COPY --from=builder /out/etc/  /etc/

# Tell the dynamic linker where our libs live
ENV LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu

EXPOSE 9290

CMD ["/usr/local/bin/ipmi_exporter/ipmi_exporter", "--config.file=/config.yml"]
