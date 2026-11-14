# Scheduled jobs of the stack: the daily state and Nextcloud backups, the HDD health check and the
# weekly Nextcloud update check.
# docker:cli brings the Docker client (the update check runs occ in the Nextcloud container); the
# scripts themselves are mounted from the repositories, not baked into the image.
FROM docker:cli

RUN apk add --no-cache bash coreutils tar curl jq tzdata restic smartmontools

COPY crontab /etc/crontabs/root
COPY *.sh /jobs/
RUN chmod +x /jobs/*.sh

# Run cron in the foreground, logging to the container log
CMD ["crond", "-f", "-l", "8"]
