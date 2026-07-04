# Deployment Orchestration

## Overview

While each database application is independently deployable, real-world
systems are typically composed of multiple cooperating applications.

In these examples, dbpm-core is the external project/repository name for the
Core runtime substrate. The in-database application identity remains `CORE`,
and dbpm commands such as `bootstrap-core` and `check-core` continue to apply.

For example:

```text
Database/
├── dbpm-core/
├── job_control/
├── utl_interval/
├── yaxform/
├── my_app/
└── Orchestration/
```

In this model:

- each application owns its own deployment manifests
- applications evolve independently
- applications may declare dependencies on other applications
- orchestration coordinates deployment order and provenance tracking

This approach treats database systems as composable software systems
rather than monolithic schema deployments.

---

## Design Philosophy

The orchestration layer is intentionally lightweight.

Responsibilities are separated as follows:

| Layer | Responsibility |
|---|---|
| Application repository | Owns database objects and deployment manifests |
| `pkg_application` | Tracks versions, dependencies, and deployment metadata |
| Orchestration layer | Coordinates deployment order and injects deployment provenance |
| Git | Provides immutable source provenance |

See [Core vs dbpm](core-vs-dbpm.md) for the canonical boundary between Core's
in-database registry responsibilities and dbpm's external orchestration,
artifact, and package responsibilities.

This separation allows:
- independent versioning
- reproducible deployments
- partial upgrades
- environment promotion
- dependency-aware evolution
- exact source traceability

---

## Recommended Structure

A typical multi-application deployment layout:

```text
Database/
├── dbpm-core/
├── job_control/
├── utl_interval/
├── yaxform/
├── my_app/
└── Orchestration/
    ├── setenv.sh
    ├── env.sql
    └── deploy_full.sql
```

### Application Directories

Each application repository contains its own:
- deployment manifests
- schema objects
- metadata
- package specifications and bodies
- uninstall scripts (well, if deployed correctly, CORE can handle this)

For example:

```text
dbpm-core/
├── Deployment_Manifests/
├── Packages/
├── Tables/
├── Types/
└── README.md
```

### Orchestration Directory

The orchestration directory coordinates deployment across applications.

Typical contents:

| File | Purpose |
|---|---|
| `setenv.sh` | Generates deployment provenance variables |
| `env.sql` | SQL*Plus substitution variables containing git commit hashes |
| `deploy_full.sql` | Top-level deployment wrapper |

---

## Deployment Provenance

One of the primary goals of orchestration is deployment provenance.

A deployment should record not only:
- which semantic version was deployed

but also:
- the exact git commit hash associated with the deployed source state
- the exact artifact URI, checksum, package coordinate, and build metadata

This allows:
- reproducible deployments
- environment comparison
- rollback analysis
- hotfix traceability
- auditing
- debugging of in-development versions

---

## Generating env.sql

A common pattern is to generate SQL*Plus substitution variables
containing the current git commit hash for each application.

Example `setenv.sh`:

```bash
#!/usr/bin/env bash

set -euo pipefail

: > env.sql

for dir in ../*/; do
    name="$(basename "$dir")"

    if hash="$(git log -1 --pretty=format:%H -- "$dir" 2>/dev/null)" \
        && [[ -n "$hash" ]]; then

        var_name="$(printf '%s' "$name" \
            | tr '[:lower:]-' '[:upper:]_')"

        printf "DEFINE %s = %s\n" \
            "$var_name" \
            "$hash" \
            >> env.sql
    fi
done
```

Example generated `env.sql`:

```sql
DEFINE CORE = a8194d36446d202c19325b6c063e0c5047485ea8
DEFINE JOB_CONTROL = 5bbaf7a0f38e5d3e91ab15d7dcac53d924f12d44
DEFINE YAXFORM = 2f77c6f7e8f54138f0e4eb1d5d5fbd9dc7b48c6a
```

The full 40-character git hash is recommended.

For manual Core installs, `Deployment_Manifests/generate_env.sh` generates the
local `Deployment_Manifests/env.sql` file consumed by
`Deployment_Manifests/deploy_wrapper.sql`.

---

## Top-Level Deployment Wrapper

The orchestration layer typically contains a top-level deployment wrapper.

Example:

```sql
@./env.sql

PROMPT =========================================================
PROMPT Deploying dbpm-core (CORE)
PROMPT =========================================================

@../dbpm-core/Deployment_Manifests/deploy.core.full.sql &CORE

PROMPT =========================================================
PROMPT Deploying JOB_CONTROL
PROMPT =========================================================

@../job_control/Deployment_Manifests/deploy.job_control.full.sql &JOB_CONTROL

PROMPT =========================================================
PROMPT Deploying YAXFORM
PROMPT =========================================================

@../yaxform/Deployment_Manifests/deploy.yaxform.full.sql &YAXFORM
```

Each application deployment manifest receives the commit hash associated
with the deployed source state.

---

## Application Deployment Manifest

Application deployment manifests typically accept the git commit hash
as a parameter and pass it to `pkg_application.begin_deployment_p`.

Example:

```sql
DEFINE GIT_COMMIT_HASH=&1

BEGIN
    pkg_application.begin_deployment_p(
        ip_application_name   => 'CORE',
        ip_major_version      => 1,
        ip_minor_version      => 0,
        ip_patch_version      => 0,
        ip_deploy_commit_hash => '&GIT_COMMIT_HASH'
    );
END;
/
```

This records:
- semantic version
- deployment timestamp
- exact source provenance

inside the deployment registry.

For artifact-managed deployments, deployment tooling can stage provenance
before running the normal deployment manifest:

```sql
BEGIN
    pkg_application.stage_deployment_provenance_p(
        ip_application_name      => 'CORE',
        ip_major_version         => 1,
        ip_minor_version         => 0,
        ip_patch_version         => 0,
        ip_deploy_commit_hash    => '&GIT_COMMIT_HASH',
        ip_artifact_uri          => '&ARTIFACT_URI',
        ip_artifact_checksum     => '&ARTIFACT_CHECKSUM',
        ip_package_coordinate    => '&PACKAGE_COORDINATE'
    );
END;
/
```

The deployment manifest can then call the same `begin_deployment_p` used
for manual deployments. If matching staged provenance exists in
`APP_DEPLOY_PROVENANCE_PENDING`, Core consumes it and records the final
deployment provenance in `APP_DEPLOY_PROVENANCE`.

Tooling that wants a single API call can still call
`pkg_application.begin_artifact_deployment_p`, which starts the deployment
and records provenance together.

When staged provenance was not possible, such as Core's initial bootstrap
where `pkg_application` did not exist before `deploy.sql` ran, dbpm can
backfill provenance after the deployment completes:

```sql
BEGIN
    pkg_application.record_deployment_provenance_p(
        ip_application_name      => 'CORE',
        ip_major_version         => 3,
        ip_minor_version         => 4,
        ip_patch_version         => 0,
        ip_deployment_type       => pkg_application.c_deploy_type_initial,
        ip_deploy_commit_hash    => '&GIT_COMMIT_HASH',
        ip_artifact_uri          => '&ARTIFACT_URI',
        ip_artifact_checksum     => '&ARTIFACT_CHECKSUM',
        ip_package_coordinate    => '&PACKAGE_COORDINATE'
    );
END;
/
```

This backfill API requires exactly one matching completed deployment. It
is idempotent when the same provenance has already been recorded, and it
raises an assertion error if different provenance already exists for that
deployment.

Typical artifact provenance includes:
- artifact URI or local path
- artifact checksum and checksum algorithm
- exact ZIP file name
- package repository coordinate
- source repository and commit
- build id, build URL, build time, and JSON build metadata

Core records completed deployment provenance in `APP_DEPLOY_PROVENANCE`;
dbpm remains responsible for resolving the artifact, verifying its
checksum, and passing the resolved values into Core.

---

## Dependency Ordering

Applications should generally be deployed in dependency order.

Example:

```text
dbpm-core (CORE)
  └── job_control
        └── yaxform
              └── my_app
```

The orchestration layer is responsible for enforcing deployment order.

Future tooling may automate dependency resolution directly from
`pkg_application` metadata.

---

## Why Not Store Orchestration in dbpm-core?

The orchestration layer is intentionally external to dbpm-core.

dbpm-core is:
- a reusable database application framework

The orchestration layer is:
- environment-specific composition and deployment coordination

Keeping orchestration external allows:
- different environments
- different deployment ordering
- partial deployments
- independent application selection
- environment-specific wrappers

without modifying application repositories.

---

## Future Directions

The orchestration pattern described here is intentionally simple.

Possible future enhancements include:
- declarative environment manifests
- automated dependency resolution
- deployment validation
- environment diffing
- deployment rollback support
- CI/CD integration
- environment promotion workflows
- deployment visualization

Example future manifest concept:

```yaml
applications:
  core:
    version: 1.2.0
    commit: a8194d36446d202c19325b6c063e0c5047485ea8
    dependencies: []

  job_control:
    version: 1.0.0
    commit: 5bbaf7a0f38e5d3e91ab15d7dcac53d924f12d44
    dependencies:
      - application: core
        min_version: 1.2.0

  emmt_xform:
    version: 3.1.0
    commit: 2f77c6f7e8f54138f0e4eb1d5d5fbd9dc7b48c6a
    dependencies:
      - application: core
        min_version: 1.2.0
      - application: job_control
        min_version: 1.0.0
```

Such manifests could eventually drive:
- deployment generation
- validation
- reproducibility
- environment auditing
- transport-style promotion workflows
