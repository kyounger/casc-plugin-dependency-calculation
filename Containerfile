FROM alpine

# tools
ENV YQ_VERSION=v4.40.2 \
    JQ_VERSION=jq-1.7 \
    KUSTOMIZE_VERSION=v5.2.1 \
    ARCH=amd64

# utils and non-root user
RUN apk add --update --no-cache \
    bash \
    tree \
    curl \
    findutils \
    git \
    zip \
    && addgroup -S -g 1000 casc-user && adduser -S -u 1000 casc-user -G casc-user -s /bin/bash

# kustomize and tools
RUN curl -sLO https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz && \
    tar xvzf kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz && \
    mv kustomize /usr/bin/kustomize && \
    chmod +x /usr/bin/kustomize && \
    rm kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz
ADD  --chmod=655 https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64 /usr/bin/yq
ADD  --chmod=655 https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64 /usr/bin/jq

# environment stuff
WORKDIR /home/casc-user
ENV CACHE_DIR=/tmp/pimt-cache \
    CACHE_BASE_DIR=/tmp/casc-plugin-dependency-calculation-cache \
    TARGET_BASE_DIR=/tmp/casc-plugin-dependency-calculation-target

# scripts
COPY run.sh /usr/local/bin/cascdeps
COPY utils/generate-effective-bundles.sh /usr/local/bin/cascgen

