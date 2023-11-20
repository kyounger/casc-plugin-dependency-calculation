FROM eclipse-temurin:11
ADD  --chmod=655 https://github.com/mikefarah/yq/releases/download/v4.35.2/yq_linux_amd64 /usr/bin/yq
ADD  --chmod=655 https://github.com/jqlang/jq/releases/download/jq-1.7/jq-linux-amd64 /usr/bin/jq
COPY run.sh /usr/local/bin/cascdeps
COPY utils/generate-effective-bundles.sh /usr/local/bin/cascgen

RUN useradd casc-user -ms /bin/bash
WORKDIR /home/casc-user
ENV CACHE_DIR=/tmp/pimt-cache \
    CACHE_BASE_DIR=/tmp/casc-plugin-dependency-calculation-cache \
    TARGET_BASE_DIR=/tmp/casc-plugin-dependency-calculation-target
