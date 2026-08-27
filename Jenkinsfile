// Jenkins Pipeline job: "Pipeline script from SCM" pointing at this repo,
// with Script Path = Jenkinsfile.
//
// MVP scope: ACTION=deploy runs playbooks/deploy.yml (idempotent - safe
// to rerun), ACTION=status runs playbooks/status.yml (read-only, no
// side effects). The full action set from the original design
// (scale-out, scale-in, backup, restore, upgrade) is intentionally NOT
// wired up here yet - see docs/roadmap.md for that Phase 2 checklist.
// Deliberately not stubbed with pipeline stages that don't do anything
// real yet.
//
// One-time Jenkins setup required before this works:
//   1. Set AGENT_NODE_LABEL below to the real label of the agent node
//      that has docker + (docker compose plugin OR the standalone
//      docker-compose binary - roles/preflight detects whichever is
//      present) + ansible-core installed, and has its OS user in the
//      `docker` group (checked up front by roles/preflight - a clear
//      failure otherwise, not a silent hang).
//   2. Replace inventory/hosts.ini's placeholder localhost entry with
//      your real target host(s) before running ACTION=deploy for real -
//      see docs/architecture.md for Scenario A vs Scenario B.

def AGENT_NODE_LABEL = 'CHANGE_ME_COCKROACHDB_AGENT_LABEL'

pipeline {
    agent { label AGENT_NODE_LABEL }

    options {
        disableConcurrentBuilds()
        timestamps()
    }

    parameters {
        choice(
            name: 'ACTION',
            choices: ['deploy', 'status'],
            description: 'deploy: idempotent single-node deploy (safe to rerun). status: read-only cluster/node health report. scale-out/scale-in/backup/restore/upgrade are Phase 2 - see docs/roadmap.md.'
        )
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Deploy') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                sh 'ansible-playbook playbooks/deploy.yml'
            }
        }

        stage('Status') {
            when { expression { params.ACTION == 'status' } }
            steps {
                sh 'ansible-playbook playbooks/status.yml'
            }
        }
    }
}
