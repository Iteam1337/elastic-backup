#!/bin/bash

set -e

ELASTIC__HOST=${ELASTIC__HOST:-"localhost:9200"}
ELASTIC__BACKUP_DIR=${ELASTIC__BACKUP_DIR:-"/mnt/elastic_dump"}
ELASTIC__SNAPSHOT_NAME=${ELASTIC__SNAPSHOT_NAME:-"elastic_dump"}
ELASTIC__BACKUP_COMPRESS=${ELASTIC__BACKUP_COMPRESS:-"true"}

ELASTIC__PATH="$ELASTIC__HOST/_snapshot/$ELASTIC__SNAPSHOT_NAME"

DUMP__NAME=${DUMP__NAME:-"dump"}
DUMP__LOCATION=${DUMP__LOCATION:-"/opt/backup"}

RUN_ON_STARTUP=${RUN_ON_STARTUP:-"false"}

CRON_TIME=${CRON_TIME:-"0 4 */2 * *"}

_main() {
  if [[ ! -z $(ps aux|grep [c]ron) ]]; then
    echo "service already started"
    tail -f /var/log/backup.log
    return 0
  fi

  mkdir -p /opt/bin

  cat <<EOF > /opt/bin/helper.sh
#!/bin/bash

set -e

function pdate {
  echo \$(date +%Y-%m-%dT%H:%M:%S)
  return 0
}
function einf {
  echo " > \$1 @ \$(pdate)"
  return 0
}
function eerr {
  echo "!!> \$1 @ \$(pdate)" 1>&2
  return 1
}
function estd {
  echo "  > \$1"
  return 0
}
EOF

  chmod +x /opt/bin/helper.sh
  source /opt/bin/helper.sh

  _check_status() {
    local n=0
    local retries=5
    local status=1

    until [[ $n -ge $retries ]]; do
      if curl --silent -XGET "$ELASTIC__HOST" > /dev/null ; then
        status=0
        break
      fi
      ((n++))
      estd "retry count: $n for host $ELASTIC__HOST"
      sleep 3
    done

    return $status
  }

  if ! _check_status ; then
    eerr "host unreachable"
  fi

  if [ ! -d "$ELASTIC__BACKUP_DIR" ]; then
    eerr "ELASTIC__BACKUP_DIR: $ELASTIC__BACKUP_DIR does not exist"
    return 1
  fi

  if [ ! -d "$DUMP__LOCATION" ]; then
    estd "DUMP__LOCATION: $DUMP__LOCATION does not exist, creating"
    mkdir -p "$DUMP__LOCATION"
  fi

  estd "generate clear script"
  cat <<EOF > /opt/bin/clear.sh
#!/bin/bash

set -e

source /opt/bin/helper.sh

_main() {
  estd "removing ind* and (snap|meta)-*.dat from $ELASTIC__BACKUP_DIR"

  find $ELASTIC__BACKUP_DIR -name "ind*" -exec rm -r {} \;
  find $ELASTIC__BACKUP_DIR \( -name "meta-*.dat" -o -name "snap-*.dat" \) -delete
}

_main
EOF
  chmod u+x /opt/bin/clear.sh

  estd "generate backup script"
  cat <<EOF > /opt/bin/backup.sh
#!/bin/bash

set -e

source /opt/bin/helper.sh

dump_date=\$(date +%Y%m%d%H%M)
dump_file=$DUMP__LOCATION/$DUMP__NAME.\$dump_date.tar.gz
elastic_url="$ELASTIC__PATH/\$dump_date?wait_for_completion=true&pretty"

_main() {
  ACTION=\$(curl --silent -XPUT "\$elastic_url") || {
    eerr "create action failed"
    return 1
  }

  if [[ -z "\$(echo \$ACTION|grep SUCCESS)" ]]; then
    eerr "backup failed"
    echo \$ACTION
    return 1
  fi

  einf "backup succeeded"

  cd $ELASTIC__BACKUP_DIR

  tar -zcf "\$dump_file" ind* meta-*.dat snap-*.dat

  estd "backup \"\$dump_file\" moved from \"$ELASTIC__BACKUP_DIR\""

  curl --silent -XDELETE "\$elastic_url" > /dev/null || {
    eerr "delete action failed"
    return 1
  }

  /opt/bin/clear.sh > /dev/null || {
    eerr "clear failed for \$dump_date"
    return 1
  }

  return 0
}

_main
EOF
  chmod u+x /opt/bin/backup.sh

  estd "generate restore script"
  cat <<EOF > /opt/bin/restore.sh
#!/bin/bash

set -e

source /opt/bin/helper.sh

restore_path=""

while getopts ":p:" opt; do
  case "\$opt" in
    p) restore_path="\$OPTARG" ;;
  esac
done; shift \$((OPTIND-1)); [ "\$1" = "--" ] && shift

_main() {
  if [ -z "\$restore_path" ]; then
    eerr "path not set, use --p"
    return 1
  fi

  einf "restore from \$restore_path"

  file_type=\$(file --mime-type -b "\$restore_path")
  backup_file=\$(basename \$restore_path)

  if [[ \$file_type != application/x-gzip ]]; then
    eerr "path not gzip (currently unsupported)"
    return 1
  fi

  einf "restoring using \"\$backup_file\""s

  cp \$restore_path $ELASTIC__BACKUP_DIR
  cd $ELASTIC__BACKUP_DIR

  tar -xzf \$backup_file && rm \$backup_file

  backup_name=\$(echo "\$backup_file"|sed 's/${ELASTIC__SNAPSHOT_NAME}_//'|sed 's/\.tar\.gz//i'|cut -d. -f2)

  elastic_url="${ELASTIC__PATH}/\${backup_name}/_restore?wait_for_completion=true&pretty"

  estd "backup_file: \$backup_file"
  estd "backup_name: \$backup_name"
  estd "elastic_url: \$elastic_url"

  indices=\$(cd ${ELASTIC__BACKUP_DIR}/indices && find . -maxdepth 1 -mindepth 1|sed 's/\.\///')

  rollback () {
    for index in \$indices; do
      curl --silent -XPOST ${ELASTIC__HOST}/\${index}/_open?wait_for_completion=true > /dev/null || {
        eerr "opening of \$index failed"
        return 1
      }
    done

    /opt/bin/clear.sh > /dev/null || {
      eerr "clear failed for \$backup_name"
      return 1
    }

    einf "rollback done"

    exit
  }

  trap rollback INT TERM EXIT
    for index in \$indices; do
      curl --silent -XPOST ${ELASTIC__HOST}/\${index}/_close?wait_for_completion=true > /dev/null || {
        eerr "closing of \$index failed"
        return 1
      }
    done

    curl --silent -XPOST "\$elastic_url" > /dev/null || {
      eerr "restore action failed"
      return 1
    }
  trap - INT TERM EXIT

  rollback

  return 0
}

_main
EOF

  chmod u+x /opt/bin/restore.sh

  ACTION=$(curl --silent -XPUT "$ELASTIC__PATH" -d "{
    \"type\": \"fs\",
    \"compress\": $ELASTIC__BACKUP_COMPRESS,
    \"settings\": {
      \"location\": \"$ELASTIC__BACKUP_DIR\"
    }
  }") || {
    eerr "$ELASTIC__HOST not reachable"
    return 1
  }

  if [[ ! -z $(echo $ACTION|grep "\"status\":5") ]] || [[ ! -z $(echo $ACTION|grep "\"status\":4") ]] ; then
    echo "$ACTION" 
    eerr "Backup not ready"
    return 1
  fi

  estd "starting logger"
  touch /var/log/backup.log
  tail -f /var/log/backup.log &

  if [ "$RUN_ON_STARTUP" == "true" ]; then
    /opt/bin/backup.sh
  fi

  echo -e "$CRON_TIME /opt/bin/backup.sh >> /var/log/backup.log 2>&1" | crontab -

  estd "running elastic backups at $CRON_TIME"

  exec crond -f
  exit 0
}

_main
