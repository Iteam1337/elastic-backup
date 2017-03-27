FROM alpine:3.5

# https://pkgs.alpinelinux.org/packages
RUN apk add --no-cache "curl<7.53" "bash<4.4" "file<6" "tzdata"

ENV ELASTIC__HOST "localhost:9200"
ENV ELASTIC__BACKUP_DIR "/mnt/elastic_dump"
ENV ELASTIC__BACKUP_COMPRESS "true"
ENV ELASTIC__SNAPSHOT_NAME "elastic_dump"
ENV PATH__BACKUP_DIR "/backup"
ENV PATH__APP "/app"
ENV PATH__LOGS "/var/log"

# https://en.wikipedia.org/wiki/Cron#Overview
ENV CRON_TIME "0 4 */2 * *"

VOLUME ["/backup","/mnt/elastic_dump"]

RUN echo "Europe/Stockholm" > /etc/timezone && \
  cp /usr/share/zoneinfo/Europe/Stockholm /etc/localtime

COPY ./run.sh /app/run.sh

WORKDIR /app

CMD ./run.sh
