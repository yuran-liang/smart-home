# Scheduled jobs of the stack: backups, disk health check, monitoring and email alerts, guest exit
# traffic, the weekly report and the weekly Nextcloud update check.
# docker:cli brings the Docker client (the update check runs occ in the Nextcloud container); the
# scripts themselves are mounted from the repositories, not baked into the image.
FROM docker:cli

RUN apk add --no-cache bash coreutils findutils tar curl jq tzdata restic smartmontools

COPY crontab /etc/crontabs/root
COPY *.sh /jobs/
RUN chmod +x /jobs/*.sh

# Run cron in the foreground, logging to the container log
CMD ["crond", "-f", "-l", "8"]
