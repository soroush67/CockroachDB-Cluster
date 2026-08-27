# CockroachDB-Cluster

Production-shaped, secure, idempotent CockroachDB deployment automation:
`Jenkins + Ansible + Docker Compose`. Currently a **single-node MVP** -
see `docs/architecture.md` for the full target (multi-host scale-out,
HAProxy, Prometheus/Grafana, backup/restore, rolling upgrade) and
`docs/roadmap.md` for what's Phase 2 and not yet built.

## Quickstart (this repo's own sandbox testing)

```
ansible-playbook playbooks/deploy.yml    # idempotent - safe to rerun
ansible-playbook playbooks/status.yml    # read-only status check
```

`inventory/hosts.ini` ships with a placeholder `localhost
ansible_connection=local` entry - replace it with real hosts before a
real deployment (see that file's own comments, and `docs/architecture.md`
section 0 for Scenario A vs Scenario B).

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
