FROM alpine:3.5

# https://pkgs.alpinelinux.org/packages
RUN apk add --no-cache "curl<7.53" "bash<4.4" "file<6"

ENV ELASTIC__HOST "localhost:9200"
ENV ELASTIC__BACKUP_DIR "/data/es-backup"
ENV ELASTIC__BACKUP_COMPRESS "true"
ENV ELASTIC__SNAPSHOT_NAME "backup"
ENV PATH__BACKUP_DIR "/data/backup"
ENV PATH__APP "/app"
ENV PATH__LOGS "/var/log"

# https://en.wikipedia.org/wiki/Cron#Overview
ENV CRON_TIME "0 4 */2 * *"

VOLUME ["/data/backup","/data/es-backup"]

COPY ./run.sh /app/run.sh

WORKDIR /app

CMD ./run.sh
