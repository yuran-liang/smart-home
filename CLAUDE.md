# CLAUDE.md

Guidance for Claude Code in this repository.

## What this is

The Docker Compose stack for a home automation Raspberry Pi (`docker/`), firmware for an ESP8266
room sensor (`sensor/`, not deployed), and the deploy script (`scripts/deploy.sh`). The service
configs live in home-config, a separate private repository.

The Pi runs the stack from a clone of this repository, `~/smart-home` on SSH host `pi`. It
controls the lights and roller shutters of a lived-in house: a restart takes them offline for
about half a minute, and a broken config can take them offline until someone fixes it.

## Workflow

- `main` is protected and is what gets deployed. Never push to it: work on a branch (`feat/`,
  `fix/`, `docs/`, `chore/`), open a pull request, wait for CI, and let the owner review and merge.
- PR descriptions say what changed, why, and how it was verified.
- Commit messages: imperative subject line, a body that explains why.
- Deploy only when asked, after the merge and once CI on `main` has passed: run
  `scripts/deploy.sh --dry-run` first, then `scripts/deploy.sh`.
- Ask before anything else that restarts services or changes files on the Pi. Move files aside
  instead of deleting them unless told otherwise.
- `deploy.sh` runs `docker compose up -d`, which does not remove a service dropped from
  `docker-compose.yml`; remove the orphaned container (and its image and data, if asked) by hand.

## Documentation

- Update every affected README in the same pull request: the top-level `README.md` (intro,
  architecture diagram, notes, components table), `docker/README.md` and `sensor/README.md`.
  Check all of them, not only the one next to the change. `.env.example` and the variable table in
  `docker/README.md` must list the same variables.
- The architecture diagram is Mermaid. Render it before pushing, e.g.
  `npx -y @mermaid-js/mermaid-cli -p <puppeteer config with executablePath> -i arch.mmd -o arch.png`,
  and keep it free of crossing edges.
- This repository is public: no IP addresses, hostnames on the LAN, room names, device serial
  numbers or credentials, in files or in commit messages.

## Checks before pushing

- Compose: `cd docker && cp .env.example .env && docker compose config --quiet` (then remove `.env`).
- Scripts: `shellcheck scripts/*.sh`. `deploy.sh` runs on macOS, whose `/bin/bash` is 3.2: no
  associative arrays or other bash 4 features.
- Firmware: `cd sensor && cp include/secrets.h.example include/secrets.h && pio run`, then delete
  `include/secrets.h`.
- Workflows: `actionlint`.

## Things that are easy to get wrong

- `COMPOSE_PROJECT_NAME=pi` in the Pi's `.env` keeps the existing containers and the
  `pi_portainer_data` volume. Changing it gives Portainer an empty volume.
- Watchtower updates images daily, so `docker compose up -d` may recreate a container that
  Watchtower replaced; that is expected.
- The firmware moved to ElegantOTA 3 and has not been flashed since; library versions are pinned
  in `platformio.ini` because unpinned ones resolved to incompatible forks.
