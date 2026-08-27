#!/usr/bin/env bash
# Manual-use equivalent of Jenkins' ACTION=status - run this directly for
# a quick local check without going through Jenkins. Read-only, no side
# effects.
set -euo pipefail
cd "$(dirname "$0")/.."
ansible-playbook playbooks/status.yml
