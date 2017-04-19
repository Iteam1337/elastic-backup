FROM alpine:3.5

# https://pkgs.alpinelinux.org/packages
RUN apk add --no-cache "curl<7.53" "bash<4.4" "file<6" "tzdata"

ARG LOCATION

ENV LOCATION ${LOCATION:-"Europe/Stockholm"}

ENV ELASTIC__HOST localhost:9200
ENV ELASTIC__BACKUP_DIR /mnt/elastic_backup
ENV ELASTIC__BACKUP_COMPRESS true
ENV ELASTIC__SNAPSHOT_NAME elastic_dump

ENV DUMP__NAME dump
ENV DUMP__LOCATION /opt/backup

# set to "true" to run backup on start
ENV RUN_ON_STARTUP false

# https://en.wikipedia.org/wiki/Cron#Overview
ENV CRON_TIME "0 4 */2 * *"

RUN echo "$LOCATION" > /etc/timezone && \
  cp /usr/share/zoneinfo/$LOCATION /etc/localtime

ADD run.sh /opt/run.sh
RUN chmod +x /opt/run.sh

WORKDIR "/opt"

VOLUME "/opt/backup"
VOLUME "/mnt/elastic_backup"

ENTRYPOINT "/opt/run.sh"

CMD "opt/run.sh"
