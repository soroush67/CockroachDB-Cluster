# Architecture

This is the full target design this platform is being built toward. Each
section is tagged **Built** (verified for real, see the repo root and
this file's own notes) or **Phase 3** (designed for, not yet built - see
`docs/roadmap.md` for the concrete checklist). Nothing from the original
design is dropped, only sequenced. Phase 1 was a secure single-node MVP;
Phase 2 added scale-out/in, backup/restore, HAProxy, and monitoring -
both are done. Only rolling upgrade and real multi-physical-host
deployment remain.

## 0. Topology

```
Initial Deployment                Target (built, Phase 2)

Application                       Application
     |                                  |
     v                                  v
CockroachDB Node-1               HAProxy (SQL endpoint)
                                         |
                                    +----+----+
                                    |    |    |
                                    v    v    v
                                  CRDB1 CRDB2 CRDB3
```

Two host layouts are supported by the same
[`templates/docker-compose.yml.j2`](../templates/docker-compose.yml.j2) -
which one you get is purely an inventory/`host_vars` decision (override
`cockroach_sql_port`/`cockroach_http_port`/`cockroach_advertise_addr`, or
`cockroach_local_nodes` directly, per host), not a template change:

- **Scenario A** - multiple nodes on one host.
- **Scenario B** - one node per independent host. **This is the production
  preference.** Three containers on one server are not real HA: if that
  server goes down, all three nodes go down together.

**Built and verified**: a real 3-node cluster
(`inventory/hosts.3node-local-demo.ini` - `crdb1`/`crdb2`/`crdb3`, all on
this one sandbox machine via `ansible_connection=local`, distinct ports),
with HAProxy and monitoring in front of it, scale-out to a 4th node and
scale-in (decommission) back down, and a real backup/restore-verify
cycle - all confirmed by actually running them, not assumed. This
sandbox has one real Docker host, so true multi-*physical*-host HA still
isn't tested (a real Scenario B deployment is Phase 3) - what's verified
here is the mechanism (join, decommission, cert distribution, compose
rendering), not physical-host fault tolerance.

## 1. Docker Compose Template — **Built**

One Jinja2 template, [`templates/docker-compose.yml.j2`](../templates/docker-compose.yml.j2),
rendered per-host by `roles/cockroach_node`. Per node: container name,
hostname, SQL port, HTTP/admin port, data volume, cert volume (read-only),
advertise address, join address list, and resource limits are all
independent, driven from `cockroach_local_nodes` (per-host) and
`inventory/group_vars/all.yml` (cluster-wide defaults) - never hardcoded
in the template. Uses `network_mode: host`, not bridge+port-publishing -
required for real: nodes (and HAProxy/Prometheus/Grafana) need to reach
each other by `advertise_addr:port`, and on this sandbox's own
same-machine multi-node demo, `localhost` inside a bridge-networked
container is that container's own loopback, not the shared host's.

## 2. Persistent Storage — **Built** (mount-safety) / **Phase 3** (real dedicated disks)

Data is never inside the container's writable layer - each node gets its
own bind-mounted directory under `cockroach_data_root`. `roles/preflight`
refuses to proceed if `cockroach_require_dedicated_mount: true` and that
path isn't a real separate mountpoint (`mountpoint -q`), so a disk that
failed to mount can't result in CockroachDB silently writing cluster data
onto the OS filesystem. Currently `false` by default (this sandbox has no
second disk) - flip it on once `cockroach_data_root` points at real
dedicated storage (e.g. `/data/cockroach/node1`).

Ownership: the container runs as the deploying host user's own uid/gid
(not root) - see the root README's "Design notes" for why that's a hard
requirement, not a preference, once `cap_drop: ALL` is in play. The same
issue, and the same fix (world-readable config instead, since no secrets
are in those files), came up again for HAProxy/Prometheus/Grafana's own
config mounts - see those sections below.

## 3. Security — **Built**

- `cockroach start --certs-dir=...` - never `--insecure`.
- TLS for node↔node, client↔node, and admin↔node - one CA, one shared
  node cert (SAN-covers every node in the cluster), one client cert
  (`root`), generated once by `roles/cockroach_tls` and distributed to
  every host.
- CA/node/client certs generated via `docker run cockroachdb/cockroach
  cert ...` (no local `cockroach` binary dependency) - matches the
  "shell out via docker run" pattern already used for `minio/mc` in
  `gitlab-backup-with-jenkins-ansible`.
- Private keys never committed (`certs/` is gitignored) and are `0600`
  (CockroachDB's own cert tooling sets this correctly, confirmed
  directly rather than assumed).
- CA is generated once and never regenerated automatically -
  regenerating it would invalidate every certificate already issued.
- Container hardening: `cap_drop: [ALL]`, `security_opt:
  [no-new-privileges:true]`, explicit `mem_limit`/`cpus`, `ulimits.nofile`,
  `restart: unless-stopped`, no `privileged: true` - applied to every
  container this project runs (CockroachDB, HAProxy, Prometheus,
  Grafana, RustFS), not just the database.
- **Phase 3**: Ansible Vault / Jenkins Credentials for anything secret
  beyond local certs - the backup secret key is currently passed via
  `-e`/Jenkins credential binding only, matching
  `gitlab-backup-with-jenkins-ansible`'s own pattern.

## 4. Network Design — **Built** (single sandbox machine) / **Phase 3** (real DNS)

`--listen-addr`, `--advertise-addr`\*, `--http-addr`, and `--join` are
all explicit and distinct in the compose template - never conflated.
`--advertise-addr` is driven by `cockroach_advertise_addr` (defaults to
Ansible's `ansible_host`); production Scenario B needs this to be a real
resolvable hostname (`crdb01.example.internal`), not this sandbox's
`localhost`-for-every-node shortcut. `--join` is computed automatically
from every node across the whole `cockroach_nodes` inventory group (see
the template's `join_addrs` computation, and the same pattern reused in
`templates/haproxy.cfg.j2` and `templates/prometheus.yml.j2`) - adding a
host to inventory is enough, no manual join-string editing anywhere.

\* CockroachDB v26.2 combines SQL and inter-node RPC traffic on
`--listen-addr` by default; a separate `--sql-addr` isn't needed unless
you want SQL clients on a different port than node-to-node traffic.

## 5. Initial Single-Node Deployment — **Built**

`playbooks/deploy.yml`: `preflight` → `cockroach_tls` → `cockroach_node`
→ `cockroach_cluster` → `load_balancer` → `monitoring`. `cockroach init`
only actually initializes on the first run - reruns detect "already
initialized" and treat it as success, not failure (see the root README's
Design notes for where this pattern came from).

## 6-7. Scale-Out / Single→3-Node — **Built**

No dedicated role needed - CockroachDB nodes join via gossip once given
`--join` pointing at existing nodes, and existing nodes don't need to be
touched or restart when a new one joins. `playbooks/scale_out.yml` is a
thin wrapper around `playbooks/deploy.yml --limit <new_host>` - the
compose template's `join_addrs` computation already spans the *entire*
`cockroach_nodes` group regardless of which host `--limit` restricts
execution to, so the new node's own rendered compose file correctly
lists every node from the start. Verified for real: scaled a 3-node demo
cluster (`crdb1`/`crdb2`/`crdb3`) out to a 4th node (`crdb4`) with
`docker inspect --format '{{.State.StartedAt}}'` confirming none of the
existing three containers restarted.

## 8. Replication Behavior — **Built** (verified with 4 real nodes)

Verified directly against the local demo cluster: `cockroach node
status` showed all 4 nodes `is_available=true`/`is_live=true` once
`crdb4` joined, and after decommissioning `crdb4` back out (see section
15), `crdb1`-`crdb3` stayed available throughout with zero restarts.
Full HA-loss-of-a-real-physical-host testing is still Phase 3 (this
sandbox's 4 "hosts" all share one real machine's fate) - what's proven
here is the join/decommission/rebalancing mechanism itself.

## 9. Load Balancing — **Built**

HAProxy (`roles/load_balancer`, `templates/haproxy.cfg.j2`,
`templates/docker-compose.haproxy.yml.j2`) in `mode tcp` on
`cockroach_lb_sql_port`, `option httpchk GET /health?ready=1` +
`check-ssl verify none` (the admin port is TLS) against each node's HTTP
port. Verified for real: ran `cockroach sql` through HAProxy
successfully; stopped one backend node's container and confirmed
HAProxy's own stats page (`cockroach_lb_stats_port`) marked it `DOWN`
within one health-check interval while SQL traffic kept flowing through
the other two nodes; restarted it and confirmed it came back `UP`.
Deployed as standing infrastructure in `playbooks/deploy.yml` (gated by
`cockroach_enable_load_balancer`, default `true`), not a separate
on-demand Jenkins action.

## 10. Cluster Map / Visualization — **Built**

The DB Console is reachable over HTTPS on `cockroach_http_port` and
shows nodes, ranges, replicas, SQL activity, and resource usage out of
the box. Grafana (see section 11) provides the same data pre-aggregated
across the whole cluster. Locality flags (`cockroach_locality`, e.g.
`region=dc1,zone=z1`) are wired into the template and empty by default;
set them per-host once nodes are spread across real regions/zones -
still untested for real since this sandbox has no real multi-region
hosts (Phase 3).

## 11. Monitoring — **Built**

Prometheus (`roles/monitoring`, `templates/prometheus.yml.j2`) scrapes
every node's `/_status/vars` over HTTPS (`insecure_skip_verify: true` -
documented sandbox simplification; `ca_file` pointing at the real CA is
the production-hardened version). Grafana runs alongside with a
provisioned Prometheus datasource and one dashboard
(`templates/grafana-cockroachdb-dashboard.json`) covering live node
count, SQL connections/QPS/latency (p99, via
`histogram_quantile(0.99, sum(rate(sql_service_latency_bucket[5m])) by (le))`),
CPU, and range replication health. Verified for real: Prometheus's own
`/targets` page showed all cluster nodes `UP`; direct queries (e.g.
`liveness_livenodes`) returned real live data; Grafana's `/api/search`
confirmed the dashboard and datasource both provisioned correctly.
Metric names were checked directly against a live node's
`/_status/vars` output rather than assumed from docs. Deployed as
standing infrastructure in `playbooks/deploy.yml` (gated by
`cockroach_enable_monitoring`, default `true`).

## 12. Jenkins Pipeline — **Built** (deploy/status/scale-out/scale-in/backup/restore)

`Jenkinsfile`: `ACTION` choice of `deploy`, `status`, `scale-out`,
`scale-in`, `backup`, `restore` - `scale-out`/`scale-in` take
`TARGET_HOST`. `scale-in` and `restore` are gated behind a manual
`input` approval stage (destructive/irreversible-ish enough to want a
human in the loop); `deploy`, `status`, `scale-out`, and `backup` are
not (backup only ever adds new backups, never removes data). Rolling
`upgrade` is still Phase 3, not offered as a choice - deliberately not
stubbed with a stage that doesn't do anything real yet.

## 13. Ansible Structure — **Built**

```
CockroachDB-Cluster/
├── Jenkinsfile
├── README.md
├── inventory/
│   ├── hosts.ini                       (default: single-node placeholder)
│   ├── hosts.3node-local-demo.ini      (verification: 3 real nodes, one sandbox machine)
│   ├── group_vars/all.yml
│   └── host_vars/crdb{1,2,3}.yml
├── templates/
│   ├── docker-compose.yml.j2
│   ├── docker-compose.{haproxy,monitoring,rustfs}.yml.j2
│   ├── haproxy.cfg.j2, prometheus.yml.j2
│   └── grafana-*.{yml,json}.j2
├── roles/{preflight,cockroach_tls,cockroach_node,cockroach_cluster,load_balancer,monitoring,cockroach_backup,cockroach_decommission}/
├── playbooks/{deploy,status,scale_out,scale_in,backup,backup_and_verify}.yml
├── scripts/health-check.sh
└── docs/{architecture,roadmap}.md
```

`group_vars`/`host_vars` live under `inventory/` (not the project root) -
Ansible only auto-discovers them relative to the inventory file's own
directory or the playbook's directory, confirmed directly after a
top-level `group_vars/` was silently never loaded.

## 14. Idempotency — **Built**, verified directly

Every role checks state before acting: certs (does the file already
exist?), cluster init (already initialized?), container (already
running and healthy?), decommission (is this node already
`membership=decommissioned`? - confirmed necessary directly: a naive
"count active nodes minus one" guard broke on a resumed decommission,
since an already-decommissioned node stops appearing in plain `node
status` output entirely). Verified end-to-end across the full stack
(3-4 nodes + HAProxy + monitoring): repeated `deploy.yml` runs produced
no CA/cert regeneration, no container recreate, no re-init failure, and
a resumed `scale_in.yml` against an already-decommissioned node
correctly skipped straight to cleanup instead of re-running the guard or
the decommission command.

## 15. Scale-In — **Built**

`roles/cockroach_decommission`: resolve node ID → refuse below
`cockroach_min_nodes_after_decommission` (default 3) remaining *active*
nodes → `cockroach node decommission <id>` (blocks on its own until
replica evacuation finishes - confirmed default `--wait=all` behavior,
no separate Ansible polling loop needed) → verify `membership=decommissioned`
→ stop the container (`docker stop`, never `docker compose down`) →
data removal as a **separate** step, gated behind
`-e cockroach_confirm_data_removal=true` (default `false`). Verified for
real: decommissioned a real 4th node out of the demo cluster, confirmed
`crdb1`-`crdb3` never restarted throughout, confirmed the decommissioned
node's data directory was kept by default.

## 16. Backup — **Built** (BACKUP DATABASE + restore-verify round-trip)

Independent of replication (3 replicas is not a backup).
`roles/cockroach_backup` runs this project's own RustFS instance (not
`gitlab-backup-with-jenkins-ansible`'s - kept self-contained, different
ports so both can run on this sandbox at once), ensures a bucket exists
via `minio/mc` (same generic S3-client pattern as that sibling project),
and runs `BACKUP DATABASE ... INTO 's3://bucket?AWS_ACCESS_KEY_ID=...&AWS_SECRET_ACCESS_KEY=...&AWS_ENDPOINT=...&AWS_USE_PATH_STYLE=true&AWS_REGION=...'`.
`AWS_USE_PATH_STYLE=true` is required, not optional, for a self-hosted
S3-compatible endpoint - confirmed directly: without it, CockroachDB
addresses the bucket AWS-virtual-hosted-style
(`<bucket>.localhost:9020`), which doesn't resolve.
`playbooks/backup_and_verify.yml` then runs `RESTORE DATABASE ... FROM
LATEST IN '...' WITH new_db_name = 'restore_verify_<timestamp>'` into
the same running cluster, compares row counts against the source table,
and drops the verification database regardless of outcome. Verified for
real with actual seeded data (not an empty table): row counts matched,
and `SHOW DATABASES` confirmed no leftover `restore_verify_*` database
after the run.

Full-cluster `BACKUP` (not just one database) and incremental backups
are the same mechanism, not built separately - Phase 3 if/when needed;
this MVP scope backs up one demo database specifically so restore-verify
can round-trip into the *same* running cluster without needing a whole
separate disposable CockroachDB cluster (unlike GitLab's own
restore-verification, which does need a disposable GitLab instance).

## 17. Upgrade — **Phase 3**

Rolling, one node at a time, with a health check between each, plus a
pre-upgrade backup and version-compatibility check. Never all nodes
restarted simultaneously. Not built - deliberately excluded from this
round's scope.

## 18. Failure Scenarios — **Phase 3** (full runbook) / partially demonstrated

Demonstrated for real: stopping one HAProxy backend node mid-traffic
(section 9) and decommissioning a node (section 15) both left the rest
of the cluster fully available throughout. Not yet demonstrated: disk
full/failure, network partition, certificate expiration, lost quorum
(losing 2 of 3 nodes), corrupted volume, load balancer failure - all
Phase 3, and specifically need a real multi-physical-host cluster to
mean anything (this sandbox's nodes all share one real machine's fate,
so "host failure" can't be tested meaningfully here).

## 19. Preflight Validation — **Built** (subset) / **Phase 3** (full list)

Currently checked by `roles/preflight`: Docker daemon reachable, a
compose command is available (plugin or standalone - both detected,
since this sandbox itself only has the standalone binary), dedicated
mount (when required), and required ports free. **Phase 3** additions
once real multi-host exists: DNS resolution between hosts, clock sync,
Docker version, available CPU/RAM/disk space, existing-data conflict
detection, cert validity, connectivity to the existing cluster before
joining a new node.

## 20. Resource Management — **Built**

`cockroach_cpu_limit`, `cockroach_mem_limit`, `cockroach_ulimit_nofile`
in `inventory/group_vars/all.yml` - never hardcoded in the template,
adjustable per environment. Same discipline applied to HAProxy/Prometheus/
Grafana/RustFS containers (`cap_drop: [ALL]`, `no-new-privileges`, no
hardcoded ports - all from group_vars).

## 21. Repository Design — **Built** (this layout)

See section 13 above - matches the requested top-level shape
(`Jenkinsfile`, `ansible`-equivalent structure at the root rather than
nested under an `ansible/` directory, `templates/`, `docs/`).
