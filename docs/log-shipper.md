# Log Shipper

This repo now contains a cross-distro Ansible playbook for shipping host logs to VictoriaLogs at `192.168.254.2:9428`.

## Behavior

- Debian hosts use `systemd-journal-upload` and send native journald records to `/insert/journald`.
- Proxmox hosts on Debian also run Vector for selected file-only logs under `/var/log`.
- Alpine hosts use Vector, tail `/var/log/messages`, and send JSON lines to `/insert/jsonline`.

## Files

- `playbooks/log-shipper.yml`
- `roles/debian_journald_shipper`
- `roles/proxmox_vector_file_shipper`
- `roles/alpine_vector_shipper`
- `scripts/bootstrap-log-shipper.sh`

## Bootstrap

Default one-liner:

```sh
curl -fsSL https://raw.githubusercontent.com/callumj/infra/main/scripts/bootstrap-log-shipper.sh | sudo sh
```

Override the VictoriaLogs target without editing the repo:

```sh
curl -fsSL https://raw.githubusercontent.com/callumj/infra/main/scripts/bootstrap-log-shipper.sh | sudo env VICTORIALOGS_HOST=192.168.254.2 VICTORIALOGS_PORT=9428 sh
```

Point the bootstrap at a different branch:

```sh
curl -fsSL https://raw.githubusercontent.com/callumj/infra/main/scripts/bootstrap-log-shipper.sh | sudo env GITHUB_REF=my-branch sh
```

## Notes

- Debian hosts are configured for persistent journald storage via `/etc/systemd/journald.conf.d/10-persistent-storage.conf`.
- Debian defaults to `debian_journald_initial_position=tail`, so first install starts shipping new logs instead of replaying the entire existing journal backlog.
- Set `DEBIAN_JOURNALD_INITIAL_POSITION=head` if you explicitly want a full historical backfill on first install.
- Proxmox hosts automatically tail file-based logs such as `pveproxy/access.log`, `pveam.log`, `pve-firewall.log`, `ultimate-updater.log`, `vzdump/*.log`, and `pve/tasks/*`.
- Alpine defaults to `/var/log/messages`. Override `alpine_vector_log_paths` if a host writes logs elsewhere.
- The Alpine Vector sink uses a disk buffer rooted in `/var/lib/vector`.
