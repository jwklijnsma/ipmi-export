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
RUN mkdir -p /out/usr/local/bin /out/etc/ssl/certs

# Copy binaries
RUN cp /usr/bin/ipmitool           /out/usr/local/bin/ || true
RUN cp /usr/sbin/ipmi-*            /out/usr/local/bin/ || true
RUN cp -r ipmi_exporter            /out/usr/local/bin/

# Collect ALL shared library dependencies for every binary
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
        dest="/out$(dirname $lib)"; \
        mkdir -p "$dest"; \
        cp -v "$lib" "$dest/"; \
    done

# Copy the dynamic linker explicitly
RUN find /lib/x86_64-linux-gnu /lib64 -maxdepth 1 -name 'ld-linux*' 2>/dev/null \
    | while read f; do \
        dest="/out$(dirname $f)"; \
        mkdir -p "$dest"; \
        cp -v "$f" "$dest/"; \
    done || true

# Copy freeipmi runtime config/SDR data
RUN mkdir -p /out/etc/freeipmi && \
    cp -a /etc/freeipmi/. /out/etc/freeipmi/ 2>/dev/null || true

# Copy CA certificates (needed by ipmi_exporter for TLS scraping)
RUN cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/ca-certificates.crt

# Minimal NSS files for user/hostname resolution
RUN echo "root:x:0:0:root:/root:/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin" \
        > /out/etc/passwd && \
    echo "root:x:0:\nnobody:x:65534:" > /out/etc/group && \
    echo "hosts: dns files" > /out/etc/nsswitch.conf


# ---------------- Stage 2: distroless runtime ----------------
# gcr.io/distroless/base-debian12 is built on Debian 12 (Bookworm).
# Since our builder is Debian 13 (Trixie), glibc versions should be
# compatible (Debian 13 ships glibc 2.40 vs distroless base ~2.36).
# If you hit "version GLIBC_X.YY not found" errors at runtime, pin the
# runtime to distroless/base-debian13 once it reaches stable/is available,
# or use the :latest tag which tracks the current stable.
FROM gcr.io/distroless/base-debian13:nonroot

# Overlay everything collected in the builder
COPY --from=builder /out/ /

EXPOSE 9290

# distroless has no shell — CMD must be exec-form (JSON array)
CMD ["/usr/local/bin/ipmi_exporter/ipmi_exporter", "--config.file=/config.yml"]