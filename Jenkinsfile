// Jenkins Pipeline job: "Pipeline script from SCM" pointing at this repo,
// with Script Path = Jenkinsfile.
//
// ACTION=deploy/status/scale-out/scale-in/backup/restore are wired up.
// scale-in and restore require TARGET_HOST (scale-in) or run against
// whatever's in inventory (backup/restore aren't host-scoped) and are
// gated behind a manual approval stage - both are irreversible-ish
// enough to want a human in the loop, per the project's own design
// notes. Rolling upgrade is still Phase 3 - see docs/roadmap.md -
// deliberately not stubbed with a stage that doesn't do anything real
// yet.
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
//   3. For backup/restore: set a real BACKUP_SECRET_KEY credential
//      (Secret text) with ID BACKUP_SECRET_KEY_CREDENTIALS_ID below.

def AGENT_NODE_LABEL = 'CHANGE_ME_COCKROACHDB_AGENT_LABEL'
def BACKUP_SECRET_KEY_CREDENTIALS_ID = 'cockroachdb-backup-secret-key'

pipeline {
    agent { label AGENT_NODE_LABEL }

    options {
        disableConcurrentBuilds()
        timestamps()
    }

    parameters {
        choice(
            name: 'ACTION',
            choices: ['deploy', 'status', 'scale-out', 'scale-in', 'backup', 'restore'],
            description: 'deploy/status: see docs/architecture.md. scale-out/scale-in: need TARGET_HOST. backup: BACKUP DATABASE to RustFS. restore: backup + restore-verify round-trip. Rolling upgrade is Phase 3 (docs/roadmap.md), not offered here.'
        )
        string(
            name: 'TARGET_HOST',
            defaultValue: '',
            description: 'Inventory host to target - required for scale-out/scale-in, ignored otherwise (e.g. crdb4).'
        )
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Confirm destructive action') {
            // scale-in decommissions a node; restore round-trips through
            // a real RESTORE. Both get a human in the loop before
            // running, per the spec's requirement that destructive
            // operations be explicit and manually approved - deploy,
            // status, scale-out, and backup are all non-destructive
            // (backup only ever writes new backups, never removes data)
            // and don't need this gate.
            when { expression { params.ACTION == 'scale-in' || params.ACTION == 'restore' } }
            steps {
                input message: "Confirm ${params.ACTION}${params.ACTION == 'scale-in' ? " on ${params.TARGET_HOST}" : ''}?"
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

        stage('Scale out') {
            when { expression { params.ACTION == 'scale-out' } }
            steps {
                sh "ansible-playbook playbooks/scale_out.yml --limit '${params.TARGET_HOST}'"
            }
        }

        stage('Scale in') {
            when { expression { params.ACTION == 'scale-in' } }
            steps {
                sh "ansible-playbook playbooks/scale_in.yml --limit '${params.TARGET_HOST}'"
            }
        }

        stage('Backup') {
            when { expression { params.ACTION == 'backup' } }
            steps {
                withCredentials([string(credentialsId: BACKUP_SECRET_KEY_CREDENTIALS_ID, variable: 'BACKUP_SECRET_KEY')]) {
                    sh 'ansible-playbook playbooks/backup.yml -e cockroach_backup_secret_key="$BACKUP_SECRET_KEY"'
                }
            }
        }

        stage('Backup + restore verify') {
            when { expression { params.ACTION == 'restore' } }
            steps {
                withCredentials([string(credentialsId: BACKUP_SECRET_KEY_CREDENTIALS_ID, variable: 'BACKUP_SECRET_KEY')]) {
                    sh 'ansible-playbook playbooks/backup_and_verify.yml -e cockroach_backup_secret_key="$BACKUP_SECRET_KEY"'
                }
            }
        }
    }
}
