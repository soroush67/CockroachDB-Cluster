# CockroachDB-Cluster

Production-shaped, secure, idempotent CockroachDB deployment automation:
`Jenkins + Ansible + Docker Compose`. Scale-out/in (with proper
decommission), backup/restore, HAProxy, and Prometheus/Grafana are all
built and verified for real against a 3-4 node demo cluster - see
`docs/architecture.md` for the full picture and `docs/roadmap.md` for
what's left (rolling upgrade, real multi-physical-host deployment).

## Quickstart (single-node, default inventory)

```
ansible-playbook playbooks/deploy.yml    # idempotent - safe to rerun
ansible-playbook playbooks/status.yml    # read-only status check
```

`inventory/hosts.ini` ships with a placeholder `localhost
ansible_connection=local` entry - replace it with real hosts before a
real deployment (see that file's own comments, and `docs/architecture.md`
section 0 for Scenario A vs Scenario B).

## Quickstart (3-node demo cluster, this sandbox's own verification setup)

```
ansible-playbook -i inventory/hosts.3node-local-demo.ini playbooks/deploy.yml --limit crdb1
ansible-playbook -i inventory/hosts.3node-local-demo.ini playbooks/scale_out.yml --limit crdb2
ansible-playbook -i inventory/hosts.3node-local-demo.ini playbooks/scale_out.yml --limit crdb3
ansible-playbook -i inventory/hosts.3node-local-demo.ini playbooks/deploy.yml   # brings up HAProxy + monitoring

# Backup/restore (needs cockroach_backup_secret_key):
ansible-playbook -i inventory/hosts.3node-local-demo.ini playbooks/backup_and_verify.yml -e cockroach_backup_secret_key='...'

# Scale in (add a 4th host to inventory/host_vars first, scale it out,
# then decommission it back out):
ansible-playbook -i inventory/hosts.3node-local-demo.ini playbooks/scale_in.yml --limit crdb4
```

HAProxy: `localhost:26000` (SQL), `localhost:26001` (stats). Prometheus:
`localhost:9090`. Grafana: `localhost:3000` (anonymous viewer access,
CockroachDB dashboard pre-provisioned).

DB Console: `https://<advertise_addr>:8080` (self-signed CA - the
browser will warn, that's expected; import `certs/ca.crt` if you want
your browser to trust it).

## Design notes

Real issues found and fixed during this project's own build/verification
(same discipline as `gitlab-backup-with-jenkins-ansible`: every fix here
was confirmed by actually running it, not assumed from docs).

**`group_vars` silently never loaded from the project root.** Ansible
only auto-discovers `group_vars`/`host_vars` relative to the inventory
file's own directory or the playbook's directory - a top-level
`group_vars/` next to `inventory/` and `playbooks/` (the layout first
tried here) is invisible to it. Confirmed directly: `cockroach_require_dedicated_mount`
came back "undefined" on the first real run despite being defined in
that file. Fixed by moving it to `inventory/group_vars/all.yml`.

**Same problem, `templates/`.** The project's requested layout has
`templates/docker-compose.yml.j2` at the top level, but Ansible's
`template` module only searches role-relative and playbook-relative
paths for a bare filename - it doesn't check the project root either.
Fixed by giving the `template` task an explicit
`{{ cockroach_project_root }}/templates/...` path instead of a bare
filename.

**`{% do %}` isn't enabled in this Ansible's Jinja environment.** The
compose template's join-address computation first tried
`{% do join_targets.append(...) %}` inside a `{% for %}` loop (a common
pattern elsewhere) - failed with "Encountered unknown tag 'do'".
Rewritten using Jinja's `namespace()` builtin instead
(`{% set ns = namespace(join_targets=[]) %}`), which needs no extension
and worked immediately.

**This host only has the standalone `docker-compose` binary, not the
`docker compose` plugin.** `docker compose version` failed outright
("unknown command") while `docker-compose version` succeeded (v5.2.0) -
confirmed directly, matching what `gitlab-backup-with-jenkins-ansible`
already relies on in this same environment. `roles/preflight` now
detects whichever form is actually present and records it as
`cockroach_compose_cmd`, used by `roles/cockroach_node` instead of a
hardcoded command - works on hosts with either form.

**`cap_drop: [ALL]` + a root container process + a non-root-owned data
directory = permission denied, even though the process is root.** The
first real deploy attempt had the container run as its image default
(root) against a data directory created by Ansible's `file` module
(owned by the deploying host user, not root). It crash-looped with
`open /cockroach/cockroach-data/temp-dirs-record.txt: permission
denied`. The reason: `CAP_DAC_OVERRIDE` is what normally lets root
bypass ownership checks on files it doesn't own, and `cap_drop: ALL`
strips that from root too - so a root process without it behaves like
any other non-owning user for permission purposes. Fixed by running the
container as the deploying host user's own uid/gid instead (`roles/cockroach_node`
queries `id -u`/`id -g` on the target host, the data directory is
created with matching ownership, and the compose template sets `user:
"<uid>:<gid>"`) - the same non-root approach already used for the
`cockroach cert` generation commands in `roles/cockroach_tls`, applied
consistently rather than granting the capability back.

**`cockroach init` isn't idempotent on its own.** A second run against an
already-initialized cluster errors instead of silently succeeding. This
exact gap was already found and fixed for real in `platform-of-platform`'s
own docker-compose `cockroach-init` service - reused that proven pattern
here rather than rediscovering it: capture the command's output, treat
both "Cluster successfully initialized" (first run) and "...already been
initialized" (every rerun after) as success, anything else as a real
failure.

**Verified end-to-end, not just "should work":** two consecutive
`playbooks/deploy.yml` runs against the same node produced no CA
regeneration, no cert regeneration, and no container recreate (`docker
inspect --format '{{.State.StartedAt}}'` unchanged across both runs);
`cockroach node status` showed the same node ID before and after;
private key files (`ca.key`, `node.key`, `client.root.key`) came out
`0600` without any extra chmod step (CockroachDB's own cert tooling sets
this correctly); the DB Console answered `200` on `https://localhost:8080/health`.

### Phase 2 (scale-out/in, backup/restore, HAProxy, monitoring)

**Bridge networking breaks node-to-node join on a same-machine multi-node
demo.** Nodes need to reach each other at `advertise_addr:port`; with the
default bridge network + port-publishing, `localhost` inside one
container is that container's own loopback, not the shared host's - a
second container's published port is unreachable through it. Switched
every container this project runs (CockroachDB, HAProxy, Prometheus,
Grafana, RustFS) to `network_mode: host` instead - also matches common
production advice for CockroachDB-in-Docker on a dedicated
single-node-per-host deployment (avoids Docker NAT overhead for a
database's own traffic).

**Same root cause as the CockroachDB data-directory permission bug, hit
again for HAProxy and Prometheus/Grafana.** `haproxy:3.2.13-alpine` runs
as uid 99, `prom/prometheus` as uid 65534 (`nobody`), `grafana/grafana`
as uid 472/gid 0 - none of them match the deploying host user, and none
of their config files contain secrets, so the fix here is simpler than
the CockroachDB data directory's uid-matching approach: render those
config files world-readable (`0644`) and their containing directory
world-traversable (`0755`) instead. Confirmed necessary directly:
HAProxy crash-looped with "Could not open configuration file ...:
Permission denied" until this was applied.

**Ansible facts/role-detected vars set on one host aren't visible to a
`delegate_to: localhost` task in a different play/host context.**
`roles/preflight`'s compose-command detection sets a fact scoped to
whatever host is executing that role - fine for `roles/cockroach_node`
running later on the *same* host, but `roles/load_balancer`,
`roles/monitoring`, and `roles/cockroach_backup` all run
`delegate_to: localhost`, and this sandbox's demo inventory hosts are
named `crdb1`/`crdb2`/`crdb3`, not literally `localhost` - so Ansible's
implicit-localhost delegate target never had that fact set by anything.
Fixed by re-running the same tiny compose-command detection inline in
each of those roles rather than relying on a cross-host fact.

**`AWS_USE_PATH_STYLE=true` is required, not optional, for `BACKUP`
against a self-hosted S3-compatible endpoint.** Without it, CockroachDB
addresses the bucket AWS-virtual-hosted-style
(`<bucket>.localhost:9020`), which doesn't resolve - confirmed directly:
"could not find s3 bucket's region: ... dial tcp: lookup
cockroachdb-backups.localhost: no such host". `AWS_REGION` also has to
be set to *something* even though RustFS has no concept of AWS regions -
without it CockroachDB's region-lookup step fails outright.

**A node that's already fully decommissioned refuses new SQL
connections to itself, and disappears from plain `node status` output
entirely.** Two related bugs found running `roles/cockroach_decommission`
against an already-decommissioned node (simulating a resumed operation
after an earlier step failed): (1) the role initially queried cluster
status by connecting to the target node's own address, which failed
with "server is not accepting clients, try another node" once that node
was already draining - fixed by always querying/commanding through a
*different*, healthy node instead. (2) The "how many nodes would remain"
guard counted rows from plain `node status`, but a fully-decommissioned
node stops appearing there at all (it only shows up with the
`--decommission` flag, under a `membership` column) - a naive "row
count minus one" check was wrong on a rerun. Fixed by checking
`membership=decommissioned` explicitly (idempotency: skip straight to
verify/cleanup if already true) and always using `--decommission` for
any status query this role needs.

**Verified end-to-end, Phase 2:** scaled a real 3-node demo cluster out
to 4 nodes and back down via decommission, with `docker inspect
--format '{{.State.StartedAt}}'` confirming zero unwanted restarts of
untouched nodes throughout; ran SQL through HAProxy and confirmed
automatic failover when a backend node was stopped; confirmed Prometheus
scraped all nodes (`/targets` → `UP`) with real live metric values, and
that Grafana's provisioned dashboard/datasource loaded correctly; ran a
real `BACKUP DATABASE` + `RESTORE ... WITH new_db_name` round-trip with
actual seeded data, confirmed row counts matched, and confirmed no
leftover verification database after cleanup.
