#!/bin/bash

ELASTIC__HOST=$(           [[ ! -z $ELASTIC__HOST ]]            && echo "$ELASTIC__HOST"            || echo "localhost:9200")
ELASTIC__BACKUP_DIR=$(     [[ ! -z $ELASTIC__BACKUP_DIR ]]      && echo "$ELASTIC__BACKUP_DIR"      || echo "/data/es-backup")
ELASTIC__SNAPSHOT_NAME=$(  [[ ! -z $ELASTIC__SNAPSHOT_NAME ]]   && echo "$ELASTIC__SNAPSHOT_NAME"   || echo "data")
ELASTIC__BACKUP_COMPRESS=$([[ ! -z $ELASTIC__BACKUP_COMPRESS ]] && echo "$ELASTIC__BACKUP_COMPRESS" || echo "true")

ELASTIC__PATH="$ELASTIC__HOST/_snapshot/$ELASTIC__SNAPSHOT_NAME"

CRON_TIME=$([[ ! -z $CRON_TIME ]] && echo "$CRON_TIME" || echo "0 4 */2 * *")

PATH__APP=$(       [[ ! -z $PATH__APP ]]        && echo "$PATH__APP"        || echo "/app")
PATH__LOGS=$(      [[ ! -z $PATH__LOGS ]]       && echo "$PATH__LOGS"       || echo "/var/log")
PATH__BACKUP_DIR=$([[ ! -z $PATH__BACKUP_DIR ]] && echo "$PATH__BACKUP_DIR" || echo "/data/backup")

_main() {
  if [[ ! -z $(ps aux|grep [c]ron) ]]; then
    echo "service already started"
    tail -f $PATH__LOGS/backup.log
    return 0
  fi

  cat <<EOF > "$PATH__APP/std_out"
#!/bin/bash

function pdate {
  echo \$(date +%Y-%m-%dT%H:%M:%S)
  return 0
}
function einf {
  echo "  > \$1 @ \$(pdate)"
  return 0
}
function eerr {
  echo "!!> \$1 @ \$(pdate)" 1>&2
  return 0
}
function estd {
  echo "  > \$1"
  return 0
}
EOF
  chmod u+x "$PATH__APP/std_out"
  source "$PATH__APP/std_out"

  estd "generate backup script"
  cat <<EOF > $PATH__APP/backup.sh
#!/bin/bash

source "$PATH__APP/std_out"

BACKUP_NAME=\$(date +%Y-%m-%d-%H-%M)
D="$ELASTIC__BACKUP_DIR"
BACKUP_FILE="$PATH__BACKUP_DIR/${ELASTIC__SNAPSHOT_NAME}_\$BACKUP_NAME.tar.gz"
ELASTIC__URL="$ELASTIC__PATH/\$BACKUP_NAME?wait_for_completion=true&pretty"

_main() {
  ACTION=\$(curl --silent -XPUT "\$ELASTIC__URL") || {
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

  tar -zcf "\$BACKUP_FILE" index indices/ meta-\$BACKUP_NAME.dat snap-\$BACKUP_NAME.dat

  estd "backup \"\$BACKUP_FILE\" moved from \"$ELASTIC__BACKUP_DIR\""

  ACTION=\$(curl --silent -XDELETE "\$ELASTIC__URL") || {
    eerr "delete action failed"
    return 1
  }

  estd "removing $ELASTIC__BACKUP_DIR/index and $ELASTIC__BACKUP_DIR/indices"
  rm -r $ELASTIC__BACKUP_DIR/index $ELASTIC__BACKUP_DIR/indices

  return 0
}

_main
EOF
  chmod u+x backup.sh

  estd "generate restore script"
  cat <<EOF > $PATH__APP/restore.sh
#!/bin/bash

source "$PATH__APP/std_out"

RESTORE_PATH=\$([[ ! -z \$1 ]] && echo "\$1" || echo $PATH__BACKUP_DIR/\$(ls $PATH__BACKUP_DIR/|sort|tail -n 1))

_main() {
  if [ ! -f "\$RESTORE_PATH" ]; then
    eerr "path not set (first argument)"
    return 1
  fi

  file_type=\$(file --mime-type -b "\$RESTORE_PATH")
  backup_file=\$(basename \$RESTORE_PATH)

  if [[ \$file_type != application/x-gzip ]]; then
    eerr "path not gzip (currently unsupported)"
    return 1
  fi

  einf "restoring using \"\$backup_file\""s

  cp \$RESTORE_PATH $ELASTIC__BACKUP_DIR
  cd $ELASTIC__BACKUP_DIR

  tar -xzf \$backup_file && rm \$backup_file

  backup_name=\$(echo "\$backup_file"|sed 's/${ELASTIC__SNAPSHOT_NAME}_//'|sed 's/\.tar\.gz//i')

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
  chmod u+x $PATH__APP/restore.sh

  if [ ! -d "$ELASTIC__BACKUP_DIR" ]; then
    eerr "ELASTIC__BACKUP_DIR: $ELASTIC__BACKUP_DIR does not exist"
    return 1
  fi

  if [ ! -d "$PATH__BACKUP_DIR" ]; then
    estd "PATH__BACKUP_DIR: $PATH__BACKUP_DIR does not exist, creating"
    mkdir -p "$PATH__BACKUP_DIR"
  fi

  ACTION=$(curl --silent -XPUT "$ELASTIC__PATH" -d "{
    \"type\": \"fs\",
    \"compress\": $ELASTIC__BACKUP_COMPRESS,
    \"settings\": {
      \"location\": \"$ELASTIC__BACKUP_DIR\",
    }
  }") || {
    eerr "$ELASTIC__HOST not reachable"
    return 1
  }

  if [[ ! -z $(echo $ACTION|grep "\"status\":5") ]]; then
    eerr "Backup not ready"
    echo $ACTION
    return 1
  fi

  sh $PATH__APP/backup.sh || {
    return 1
  }

  estd "starting logger"
  touch $PATH__LOGS/backup.log
  tail -f $PATH__LOGS/backup.log &

  echo "$CRON_TIME $PATH__APP/backup.sh >> $PATH__LOGS/backup.log 2>&1" > crontab.conf

  crontab crontab.conf
  estd "running elastic backups at $CRON_TIME"

  exec crond -f
  exit 0
}

_main
