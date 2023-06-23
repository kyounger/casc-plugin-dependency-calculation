FROM eclipse-temurin:11
ADD  --chmod=655 https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 /usr/bin/yq
ADD  --chmod=655 https://github.com/jqlang/jq/releases/latest/download/jq-linux64 /usr/bin/jq
RUN useradd casc-user -ms /bin/bash

USER casc-user
WORKDIR /home/casc-user
ENV CACHE_DIR=/home/casc-user
COPY --chown=casc-user run.sh run.sh
