# Phase 2 roadmap

The MVP is a secure, idempotent single-node deployment (see the root
README and `docs/architecture.md`). Everything below is designed for but
not yet built - nothing here should be assumed to work until it's
actually implemented and verified against a real run, per this
project's own discipline.

## Licensing note (relevant as soon as Phase 2 adds a 2nd/3rd node)

Self-hosted CockroachDB is under the **CockroachDB Software License**
(applies from v24.3 onward) - free for individual developers, students,
and organizations under $10M annual revenue. **A single-node cluster
needs no license key at all** (the MVP's current state). A 3-node
cluster gets a **7-day grace period** before CockroachDB requires a
(free or paid) license key. Get the license key situation sorted
*before* scale-out, not after the grace period expires mid-Phase-2
testing.

## Scale-out (`ACTION=scale-out`)

- Jenkins parameters: `TARGET_NODE`, `TARGET_HOST`.
- Ansible flow: validate host → prepare storage (same `preflight` checks
  as deploy) → deploy certs (extend `cockroach_tls`'s distribution step,
  already written but only exercised as a no-op so far since this
  sandbox has no second host) → generate compose for the new node → join
  existing cluster → verify node membership (`cockroach node status`
  shows the new node) → monitor rebalancing.
- Add the new host to `inventory/hosts.ini` and rerun `deploy.yml` should
  cover most of this already, since `--join` is computed from the whole
  `cockroach_nodes` group automatically - confirm this is actually true
  once a second real host exists, don't assume it.

## Scale-in (`ACTION=scale-in`)

Never `docker compose down` alone. Workflow: select node → cluster
health check → check replication is sufficient without this node →
`cockroach node decommission <id>` → wait for rebalancing/replica
evacuation to finish → verify evacuation → stop the container → data
removal as a **separate**, manually-confirmed operation. Requires a
Jenkins manual-approval stage.

## Backup / Restore (`ACTION=backup` / `restore`)

- `BACKUP` to S3-compatible object storage (reuse the same RustFS
  instance/pattern already running for `gitlab-backup-with-jenkins-ansible`,
  or a dedicated bucket).
- Full + incremental, retention, encryption, verification via a real
  restore test - the exact discipline already proven in
  `gitlab-backup-with-jenkins-ansible` (sequential, rate-limit-aware,
  verified-by-actually-restoring), adapted for CockroachDB's own
  `BACKUP`/`RESTORE` SQL statements instead of GitLab's export API.
- A separate Jenkins pipeline (or a manual-approval-gated stage) for
  restore verification, matching that project's own split between
  `backup.yml` and `backup_and_verify.yml`.

## Upgrade (`ACTION=upgrade`)

Rolling, one node at a time: pre-check → backup → upgrade node → health
check → repeat per node → final cluster verification. Never restart all
nodes simultaneously. Check version compatibility (CockroachDB only
supports upgrading one major version at a time) before starting - verify
the actual current compatibility rules against the docs at upgrade time,
don't assume last year's rules still apply.

## Load Balancing (HAProxy)

Health-checked reverse proxy in front of the SQL port
(`cockroach_sql_port`) so the application never depends on any single
node's address directly. Health check against each node's
`/health?ready=1` (not plain `/health`) so a node that's up but not
cluster-ready doesn't receive traffic.

## Monitoring (Prometheus + Grafana)

Prometheus scrape config against `/_status/vars` on each node's HTTP
port. Grafana dashboards: node availability, CPU, memory, disk
usage/latency, SQL latency, QPS, connection count, under-replicated /
unavailable ranges, Raft, node restarts, certificate expiration.
Alerting rules for the same. The DB Console (already reachable in the
MVP) covers ad-hoc inspection; Prometheus/Grafana is for
trend/alerting, not a replacement for it.

## Preflight validation - the rest of the list

Currently checked (`roles/preflight`): Docker daemon, compose command
availability, dedicated mount (when required), free ports. Still to add
once real multi-host exists: DNS resolution between hosts, hostname
uniqueness, clock synchronization, Docker version floor, available
CPU/RAM, disk filesystem/latency, existing-data conflict detection on
the target host, cert validity, and connectivity to the already-running
cluster before a join is attempted.

## Failure-scenario runbook

Container failure, host failure, disk full/failed, network partition,
certificate expiration, lost node, lost quorum, corrupted volume, load
balancer failure, Docker daemon failure - each needs a documented
runbook entry once there's a real multi-node cluster to actually test
these against. Writing the runbook without a real cluster to verify
against would just be guessing - do this once Phase 2's 3-node cluster
exists.
