# -------- Stage 1: builder --------
FROM redhat/ubi10:latest AS builder

ARG IPMI_EXPORTER_VERSION=1.6.0

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

FROM redhat/ubi10-micro:latest

WORKDIR /opt

# Download ipmi-exporter
ENV IPMI_EXPORTER_VERSION=1.10.1

RUN wget https://github.com/prometheus-community/ipmi_exporter/releases/download/v${IPMI_EXPORTER_VERSION}/ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz && \
    tar xvf ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz && \
    mv ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64 ipmi_exporter && \
    rm ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz

# Copy config
COPY ipmi.yml /opt/ipmi_exporter/ipmi.yml

# Ensure root owns everything (default, but explicit)
RUN chown -R root:root /opt/ipmi_exporter

EXPOSE 9290

CMD ["/opt/ipmi_exporter/ipmi_exporter", \
     "--config.file=/opt/ipmi_exporter/ipmi.yml"]
