# -------- Stage 1: builder --------
FROM redhat/ubi10:latest AS builder

ARG IPMI_EXPORTER_VERSION=1.10.1

RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm

RUN dnf install -y \
        wget \
        tar \
        ipmitool \
        freeipmi \
    && dnf clean all

WORKDIR /build

# Download ipmi_exporter
RUN wget https://github.com/prometheus-community/ipmi_exporter/releases/download/v${IPMI_EXPORTER_VERSION}/ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz && \
    tar xvf ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz && \
    mv ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64 ipmi_exporter && \
    rm ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz

# -------- Stage 2: micro --------
FROM redhat/ubi10-micro:latest

# Copy exporter
COPY --from=builder /build/ipmi_exporter /opt/ipmi_exporter

# Copy ipmitool + freeipmi binaries
COPY --from=builder /usr/bin/ipmitool /usr/bin/ipmitool
COPY --from=builder /usr/sbin/ipmi-* /usr/sbin/

# Copy required libraries (broad copy, safer)
COPY --from=builder /usr/lib64 /usr/lib64
COPY --from=builder /lib64 /lib64

# Optional: configs (freeipmi sometimes needs this)
COPY --from=builder /etc/freeipmi /etc/freeipmi


# Copy config
COPY ipmi.yml /opt/ipmi_exporter/ipmi.yml

# Ensure root owns everything (default, but explicit)
RUN chown -R root:root /opt/ipmi_exporter

EXPOSE 9290

CMD ["/opt/ipmi_exporter/ipmi_exporter", \
     "--config.file=/opt/ipmi_exporter/ipmi.yml"]
