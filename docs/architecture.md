# Architecture

This is the full target design this platform is being built toward. Each
section is tagged **MVP** (built and verified, see the repo root) or
**Phase 2** (designed for, not yet built - see `docs/roadmap.md` for the
concrete checklist). Nothing from the original design is dropped, only
sequenced.

## 0. Topology

```
Initial Deployment                Target (Phase 2)

Application                       Application
     |                                  |
     v                                  v
CockroachDB Node-1          Load Balancer / DB Endpoint
                                         |
                                    +----+----+
                                    |    |    |
                                    v    v    v
                                  CRDB1 CRDB2 CRDB3
```

Two host layouts are supported by the same
[`templates/docker-compose.yml.j2`](../templates/docker-compose.yml.j2) -
which one you get is purely an inventory/`host_vars` decision (override
`cockroach_local_nodes` per host), not a template change:

- **Scenario A** - multiple nodes on one host (e.g. for a quick multi-node
  test without provisioning separate machines).
- **Scenario B** - one node per independent host. **This is the production
  preference.** Three containers on one server are not real HA: if that
  server goes down, all three nodes go down together. Production should
  end up as 3 CockroachDB nodes on 3 independent hosts.

**MVP status**: single node (`crdb1` equivalent), Scenario B-shaped but
not yet deployed across real separate hosts (no real inventory exists
yet - `inventory/hosts.ini` is a placeholder, see its own comments).

## 1. Docker Compose Template — **MVP**

One Jinja2 template, [`templates/docker-compose.yml.j2`](../templates/docker-compose.yml.j2),
rendered per-host by `roles/cockroach_node`. Per node: container name,
hostname, SQL port, HTTP/admin port, data volume, cert volume (read-only),
advertise address, join address list, and resource limits are all
independent, driven from `cockroach_local_nodes` (per-host) and
`inventory/group_vars/all.yml` (cluster-wide defaults) - never hardcoded
in the template.

## 2. Persistent Storage — **MVP** (mount-safety) / **Phase 2** (real dedicated disks)

Data is never inside the container's writable layer - each node gets its
own bind-mounted directory under `cockroach_data_root`. `roles/preflight`
refuses to proceed if `cockroach_require_dedicated_mount: true` and that
path isn't a real separate mountpoint (`mountpoint -q`), so a disk that
failed to mount can't result in CockroachDB silently writing cluster data
onto the OS filesystem. Currently `false` by default (this sandbox has no
second disk) - flip it on once `cockroach_data_root` points at real
dedicated storage (e.g. `/data/cockroach/node1`).

Ownership: the container runs as the deploying host user's own uid/gid
(not root) - see the "Design notes" entry in the root README for why
that's a hard requirement, not a preference, once `cap_drop: ALL` is in
play.

## 3. Security — **MVP**

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
  `restart: unless-stopped`, no `privileged: true`.
- **Phase 2**: Ansible Vault / Jenkins Credentials for anything secret
  once this handles more than local certs (e.g. cloud backup credentials).

## 4. Network Design — **MVP** (single host) / **Phase 2** (real DNS)

`--listen-addr`, `--advertise-addr`, `--sql-addr`\*, `--http-addr`, and
`--join` are all explicit and distinct in the compose template - never
conflated. `--advertise-addr` is driven by `cockroach_advertise_addr`
(defaults to Ansible's `ansible_host`); production Scenario B needs this
to be a real resolvable hostname (`crdb01.example.internal`, not a
Docker-bridge-internal address), so multi-host nodes can find each other
reliably. `--join` is computed automatically from every node across the
whole `cockroach_nodes` inventory group (see the template's `join_addrs`
computation) - adding a host to inventory is enough, no manual join-string
editing.

\* CockroachDB v26.2 combines SQL and inter-node RPC traffic on
`--listen-addr` by default; a separate `--sql-addr` is only needed if you
want SQL clients on a different port than node-to-node traffic, which
isn't a Phase 1 requirement.

## 5. Initial Single-Node Deployment — **MVP**

`playbooks/deploy.yml`: `preflight` → `cockroach_tls` → `cockroach_node`
→ `cockroach_cluster`. `cockroach init` only actually initializes on the
first run - reruns detect "already initialized" and treat it as success,
not failure (see the root README's Design notes for where this pattern
came from). Verified directly: two consecutive `deploy.yml` runs against
the same node left the container's `StartedAt` timestamp unchanged and
the cluster's node ID unchanged - nothing destructive happened on rerun.

## 6-7. Scale-Out / Single→3-Node — **Phase 2**

See `docs/roadmap.md`. The join-address computation and shared-CA
cert distribution in the current roles are already shaped so that adding
a host to inventory and rerunning `deploy.yml` should be most of what
scale-out needs - the missing piece is the Jenkins
`ACTION=scale-out`/`TARGET_HOST` workflow and post-join membership
verification, not a redesign of the roles built so far.

## 8. Replication Behavior — **Phase 2** (needs real verification once >1 node exists)

Not yet applicable with one node - a single-node cluster has no
replication to speak of (replication factor still defaults to 3 at the
range level, but with one node every range's replicas necessarily
collapse onto that node; nothing meaningful can be verified about
rebalancing, quorum, or leaseholder distribution until a second and
third node actually exist). Documented here so Phase 2 doesn't assume
adding a node automatically means HA is active - that has to be checked
via `cockroach node status` / range reports, not assumed.

## 9. Load Balancing — **Phase 2**

HAProxy (or an equivalent) in front of the SQL port, with health checks
against each node's `/health?ready=1`, so a down node stops receiving
new connections. Not needed with one node.

## 10. Cluster Map / Visualization — **MVP** (DB Console reachable) / **Phase 2** (Prometheus/Grafana)

The DB Console is reachable over HTTPS on `cockroach_http_port` (verified
directly: `curl -ksS https://localhost:8080/health` → `200`) and shows
nodes, ranges, replicas, SQL activity, and resource usage out of the box
- no extra setup needed for that part. Locality flags
(`cockroach_locality`, e.g. `region=dc1,zone=z1`) are wired into the
template and empty by default; set them per-host once nodes are spread
across real regions/zones. Prometheus + Grafana alongside the DB Console
(recommended, not a replacement for it) is Phase 2.

## 11. Monitoring — **Phase 2**

Prometheus scraping CockroachDB's `/_status/vars` endpoint, Grafana
dashboards (node availability, CPU/memory/disk, SQL latency, QPS,
under-replicated/unavailable ranges, Raft, certificate expiration), and
alerting. See `docs/roadmap.md`.

## 12. Jenkins Pipeline — **MVP** (deploy/status) / **Phase 2** (everything else)

Current `Jenkinsfile`: `ACTION` choice of `deploy` or `status` only.
`scale-out`, `scale-in`, `backup`, `restore`, `upgrade` are documented as
Phase 2 rather than stubbed with pipeline stages that don't do anything
real yet. Manual-approval gating for the destructive ones
(`scale-in`, `restore`, `upgrade`) is a Phase 2 requirement, not
implemented yet since those actions don't exist yet either.

## 13. Ansible Structure — **MVP**

```
CockroachDB-Cluster/
├── Jenkinsfile
├── README.md
├── inventory/hosts.ini, inventory/group_vars/all.yml
├── templates/docker-compose.yml.j2
├── roles/{preflight,cockroach_tls,cockroach_node,cockroach_cluster}/
├── playbooks/{deploy,status}.yml
├── scripts/health-check.sh
└── docs/{architecture,roadmap}.md
```

`group_vars` lives under `inventory/` (not the project root) - Ansible
only auto-discovers `group_vars`/`host_vars` relative to the inventory
file's own directory or the playbook's directory, confirmed directly
after a top-level `group_vars/` was silently never loaded.

## 14. Idempotency — **MVP**, verified directly

Every role checks state before acting: certs (does the file already
exist?), cluster init (already initialized?), container (already
running and healthy?). Verified end-to-end: two consecutive `deploy.yml`
runs produced no CA regeneration, no cert regeneration, no container
recreate (`docker inspect --format '{{.State.StartedAt}}'` unchanged),
and no failure from `cockroach init` running twice.

## 15. Scale-In — **Phase 2**

Never just `docker compose down`. Real workflow: cluster health check →
check replication is sufficient without this node → `cockroach node
decommission <id>` → wait for rebalancing/replica evacuation → verify
evacuation → stop the container → data removal as a **separate**,
manually-confirmed step. See `docs/roadmap.md`.

## 16. Backup — **Phase 2**

Independent of replication (3 replicas is not a backup). Full + incremental
backups to S3-compatible object storage, retention, encryption,
verification via restore test - the same discipline already built for
real in `gitlab-backup-with-jenkins-ansible`, adapted for
`BACKUP`/`RESTORE` SQL statements instead of GitLab's export API.

## 17. Upgrade — **Phase 2**

Rolling, one node at a time, with a health check between each, plus a
pre-upgrade backup and version-compatibility check. Never all nodes
restarted simultaneously.

## 18. Failure Scenarios — **Phase 2** (runbook) / relevant now for the single-node case

With one node (current MVP state), any node failure is total downtime -
there is no HA to speak of yet, which is exactly why Scenario B (3
independent hosts) is the production target. Once 3 nodes exist with
replication factor 3, losing one node keeps the cluster available
(quorum survives with 2 of 3), but losing two loses quorum - this needs
to be demonstrated for real once Phase 2's second and third nodes exist,
not assumed.

## 19. Preflight Validation — **MVP** (subset) / **Phase 2** (full list)

Currently checked by `roles/preflight`: Docker daemon reachable, a
compose command is available (plugin or standalone - both detected,
since this sandbox itself only has the standalone binary), dedicated
mount (when required), and required ports free. **Phase 2** additions
once real multi-host exists: DNS resolution between hosts, clock sync,
Docker version, available CPU/RAM/disk space, existing-data conflict
detection, cert validity, connectivity to the existing cluster before
joining a new node.

## 20. Resource Management — **MVP**

`cockroach_cpu_limit`, `cockroach_mem_limit`, `cockroach_ulimit_nofile`
in `inventory/group_vars/all.yml` - never hardcoded in the template,
adjustable per environment.

## 21. Repository Design — **MVP** (this layout)

See section 13 above - matches the requested top-level shape
(`Jenkinsfile`, `ansible`-equivalent structure at the root rather than
nested under an `ansible/` directory, `templates/`, `docs/`), adapted
slightly: `scripts/` currently has one file (`health-check.sh`); more
land there as Phase 2 operations (`cluster-status.sh`, `preflight.sh`)
get built.
