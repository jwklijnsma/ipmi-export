# ---------------- Stage 1: builder ----------------
FROM rockylinux:9 AS builder

ARG IPMI_EXPORTER_VERSION=1.10.1

RUN dnf install -y \
        wget \
        tar \
        ipmitool \
        freeipmi \
        findutils \
    && dnf clean all

WORKDIR /build

# Download ipmi_exporter
RUN wget -q https://github.com/prometheus-community/ipmi_exporter/releases/download/v${IPMI_EXPORTER_VERSION}/ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz && \
    tar xvf ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz && \
    mv ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64 ipmi_exporter

# ---------------- dependency collection ----------------
RUN mkdir -p /out/bin /out/lib

# Copy binaries
RUN cp /usr/bin/ipmitool /out/bin/ || true && \
    cp -r /usr/sbin/ipmi-* /out/bin/ || true && \
    cp -r ipmi_exporter /out/bin/

# Copy ONLY required shared libraries (critical step)
RUN for bin in /out/bin/*; do \
        ldd $bin 2>/dev/null | awk '{print $3}' | grep -E '^/' || true; \
    done | sort -u | xargs -I{} cp -v --parents {} /out/lib || true

# ---------------- Stage 2: distroless runtime ----------------
FROM redhat/ubi10-micro

COPY --from=builder /out/bin/ /usr/local/bin/
COPY --from=builder /out/lib/ /

COPY ipmi.yml /etc/ipmi.yml

EXPOSE 9290

CMD ["/usr/local/bin/ipmi_exporter/ipmi_exporter", "--config.file=/etc/ipmi.yml"]