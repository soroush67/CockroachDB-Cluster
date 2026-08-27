# Phase 3 roadmap

Phase 1 (secure single-node MVP) and Phase 2 (scale-out/in, backup/restore,
HAProxy, monitoring) are both built and verified for real - see
`docs/architecture.md`. What's left:

## Rolling upgrade (`ACTION=upgrade`)

Rolling, one node at a time: pre-check → backup → upgrade node → health
check → repeat per node → final cluster verification. Never restart all
nodes simultaneously. Check version compatibility (CockroachDB only
supports upgrading one major version at a time) before starting - verify
the actual current compatibility rules against the docs at upgrade time,
don't assume last year's rules still apply.

## Real multi-physical-host deployment

Everything built so far (scale-out, scale-in, HAProxy, monitoring) was
verified against a demo cluster where all "hosts" share one real sandbox
machine (`inventory/hosts.3node-local-demo.ini`). The mechanism is
proven; genuine host-level HA (a real server going down and the cluster
surviving it) still needs real separate hosts to mean anything. When
real hosts exist: point `inventory/hosts.ini` at them (real
`ansible_host` IPs, real resolvable `cockroach_advertise_addr` hostnames,
no `ansible_connection=local`), confirm DNS resolution between them, and
re-verify the failure-scenario runbook below against real host failures.

## Preflight validation - the rest of the list

Currently checked (`roles/preflight`): Docker daemon, compose command
availability, dedicated mount (when required), free ports. Still to add
once real multi-host exists: DNS resolution between hosts, hostname
uniqueness, clock synchronization, Docker version floor, available
CPU/RAM, disk filesystem/latency, existing-data conflict detection on
the target host, cert validity, and connectivity to the already-running
cluster before a join is attempted.

## Failure-scenario runbook

Demonstrated for real already: a down HAProxy backend node, and a
decommissioned node - both left the rest of the cluster fully available.
Still needed, and specifically requiring a real multi-physical-host
cluster to test meaningfully (this sandbox's nodes all share one
machine's fate): disk full, disk failure, network partition, certificate
expiration, lost quorum (losing 2 of 3 nodes), corrupted volume, load
balancer failure, Docker daemon failure on one host. Write each entry
against a real test of that failure, not a guess.

## Full-cluster backup / incremental backups

The current backup role (`roles/cockroach_backup`) backs up one specific
demo database (`BACKUP DATABASE ... INTO ...`), chosen so restore-verify
can round-trip into the *same* running cluster without needing a whole
separate disposable CockroachDB cluster. A real production deployment
likely wants whole-cluster `BACKUP INTO ...` and scheduled incrementals
(`BACKUP INTO LATEST IN ...`) plus retention pruning (mirroring
`gitlab-backup-with-jenkins-ansible`'s own retention approach) - same
mechanism, just a different backup target and a cron/Jenkins schedule,
not a redesign.

## TLS cert rotation / SAN list changes

`roles/cockroach_tls` deliberately never regenerates an existing node
cert automatically (see its own comments) - adding a node whose address
isn't already covered by the shared node cert's SAN list needs a
deliberate, documented rolling cert refresh across every existing node,
not an automatic one. Not yet designed in detail.
