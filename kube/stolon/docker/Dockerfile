FROM sorintlab/stolon:master-pg11

ENV POSTGIS_MAJOR 3
ENV POSTGIS_VERSION 3.0.1+dfsg-2.pgdg90+1

RUN apt-get update \
      && apt-cache showpkg postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR \
      && apt-get install -y --no-install-recommends \
           postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR=$POSTGIS_VERSION \
           postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR-scripts=$POSTGIS_VERSION \
           curl ca-certificates daemontools cron \
      && rm -rf /var/lib/apt/lists/*

ARG WALG_RELEASE=v0.2.15
RUN cd /usr/local/bin && curl -L https://github.com/wal-g/wal-g/releases/download/$WALG_RELEASE/wal-g.linux-amd64.tar.gz | tar xzf -

RUN mkdir -p /docker-entrypoint-initdb.d
RUN mkdir -p /etc/wal-g.d/env

COPY ./initdb-postgis.sh /docker-entrypoint-initdb.d/10_postgis.sh
COPY ./update-postgis.sh /usr/local/bin
COPY ./backup.sh /usr/local/bin
RUN mkdir -p /etc/cron.d
COPY ./pg-backup-cron /etc/cron.d/

# Give execution rights on the cron job
RUN chmod 0644 /etc/cron.d/pg-backup-cron

# Apply cron job
RUN crontab /etc/cron.d/pg-backup-cron

# Create the log file to be able to run tail
RUN touch /var/log/cron.log

RUN chmod +x /usr/local/bin/backup.sh
