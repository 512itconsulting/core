# dbpm-core

dbpm-core (Core) is an Oracle PL/SQL framework for database application
deployment, versioning, dependency management, and lifecycle tracking.

It provides infrastructure for building composable, semantically-versioned
database applications with deployment provenance, metadata ownership,
dependency tracking, and operational tooling.

## Identity

`dbpm-core` is the external project and repository identity for this
runtime substrate. The in-database application identity remains `CORE` for
backward compatibility with existing deployments, dbpm commands, deployment
manifests, and registry metadata.

Compatibility surfaces intentionally remain stable:
- dbpm package name: `core`
- package coordinates: `com.512itconsulting.database:core`
- build metadata path: `META-INF/core-build.properties`
- deployment commands: `bootstrap-core` and `check-core`
- deployment manifests such as `deploy.sql`, `update.sql`, and
  `uninstall.core.sql`

## Features

### Deployment & Lifecycle Management
- `pkg_application`
  - application registration
  - semantic version tracking
  - deployment lifecycle management
  - dependency management
  - object registration
  - deployment provenance tracking via git commit hash
  - uninstall and cleanup support

### Operational Tooling
- `pkg_syslog`
  - generic logging utility inspired by UNIX syslog

- `pkg_trace`
  - lightweight tracing facility for runtime diagnostics and troubleshooting

### Metadata & Dictionary Services
- `pkg_app_dict`
  - generic application dictionary framework

### Development Utilities
- `assert`
  - design-by-contract style assertion procedure

- `num_tab`
  - reusable numeric collection type for passing arrays of numbers

---

## Core Concepts

### Core and dbpm Responsibilities

Core is the in-database registry and lifecycle substrate. dbpm is the external
package, artifact, and orchestration tool.

See [Core vs dbpm](docs/core-vs-dbpm.md) for the responsibility boundary between
installed database state and external deployment orchestration.

### Semantic Versioned Database Applications

Applications are deployed using semantic version metadata:

- major
- minor
- patch
- pre-release
- build metadata

This allows database applications to evolve in a controlled and traceable way.

### Deployment Provenance

Deployments may optionally record the full 40-character git commit hash
associated with the deployed source state.

This allows environments running the same semantic version to still be
distinguished during active development, hotfixes, or unreleased builds.

### Deployment Environment and Safety Policy

Core stores deployment configuration in `APP_DICTIONARY` for the in-database
`CORE` application.

`DEPLOY_ENVIRONMENT` is a human-readable label for the database, such as
`DEV`, `QLAB01`, `PLAB`, or `PROD`. It answers "Where am I?"

`DEPLOY_LOCKED` is the deployment safety policy flag. It answers "Should
dangerous deployment behavior be blocked?" The value is required during Core
install/bootstrap, must be `Y` or `N`, and is stored normalized to uppercase.

Use `DEPLOY_LOCKED=N` for development-like databases where local development
workflows are allowed. Use `DEPLOY_LOCKED=Y` for production or production-like
databases where deployment tooling should block development-only or destructive
behavior.

Do not infer `DEPLOY_LOCKED` from `DEPLOY_ENVIRONMENT`; store both values
explicitly.

`pkg_app_dict.set_deployment_metadata_p` is an initial configuration helper for
`DEPLOY_LOCKED`. Once `DEPLOY_LOCKED` exists, the procedure will not change it.
Changing the lock value later should be treated as a deliberate operational
dictionary update.

For scripted installs, define both values before running the Core install
manifest:

```sql
DEFINE DEPLOY_ENVIRONMENT = DEV
DEFINE DEPLOY_LOCKED = N

@Deployment_Manifests/deploy.sql <core-commit-hash>
```

For manual installs that use `Deployment_Manifests/deploy_wrapper.sql`, first
generate the local substitution-variable file:

```sh
Deployment_Manifests/generate_env.sh
```

This writes `Deployment_Manifests/env.sql` with the current repository commit
hash for Core. If the script is used in a dbpm-style repository containing
multiple package folders, it writes one substitution variable per package-like
folder using the latest commit that touched that folder. The generated file is
local install state and should not be committed.

### Dependency-Aware Applications

Applications can declare dependencies on:
- other applications
- required system privileges
- required database objects

This helps validate deployment prerequisites and application compatibility.

### Cross-Application Metadata Ownership

Applications may register ownership of rows stored in tables owned by
other applications, enabling automatic cleanup during uninstall.

---

## Example Deployment

```sql
BEGIN
    pkg_application.begin_deployment_p(
        ip_application_name   => 'MYAPP',
        ip_major_version      => 1,
        ip_minor_version      => 0,
        ip_patch_version      => 0,
        ip_pre_release        => 'beta.1',
        ip_deploy_commit_hash => 'a1b2c3d4e5f6789012345678901234567890abcd',
        ip_notes              => 'Initial deployment of MYAPP'
    );
END;
/
```

Applications may then:
- register deployed objects
- register dependencies
- seed metadata
- mark the deployment complete

---

## Deployment Provenance Workflow

Deployment manifests may receive the full 40-character git commit hash
associated with the application source being deployed.

One common workflow is:

1. Generate an `env.sql` file containing SQL*Plus substitution variables
   for each application/repository.
2. Load `env.sql` from the top-level deployment wrapper.
3. Pass the appropriate commit hash into each application deployment
   manifest.
4. Store that hash using `pkg_application.begin_deployment_p`.

Example generated `env.sql`:

```sql
DEFINE CORE = 22058236147ab4a644e68faee4e28f176580a26a
DEFINE UTL_METADATA_SCRIPT = 08aa01ccac28672208c012cc0b13bae6a91b778b
```

Example wrapper usage:

```sql
@./env.sql

-- example only - dbpm-core (the CORE substrate) should be installed first
@../core/Deployment_Manifests/deploy.core.full.sql &CORE
@../utl_metadata_script/Deployment_Manifests/deploy.full.sql &UTL_METADATA_SCRIPT
```

This allows the deployment registry to track not only which semantic
version of an application is installed, but the exact source commit that
produced the deployed database objects.

---

## Uninstalling dbpm-core

This repository includes:

`Deployment_Manifests/uninstall.core.sql`

a self-contained uninstall script for the `CORE` deployment.

- It drops the objects created by `deploy.core.full.sql`
- It does not rely on `APP_OBJECTS` or `pkg_application` metadata being populated
- It prompts for confirmation before proceeding

> [!WARNING]
> `uninstall.core.sql` is destructive and intended only for safe,
> non-production environments.

`pkg_application.delete_system_p` is also destructive. It is intended only for
explicit development reset scenarios, requires exact confirmation text, and is
allowed only when `DEPLOY_LOCKED=N`.

---

## Cross-Application Metadata Ownership

A key feature of `pkg_application` is the ability to register metadata
that belongs to one application but lives in a table owned by another.

This ensures automatic cleanup when `delete_application_p` is called,
with no orphaned rows left behind.

### The problem it solves

Applications frequently seed rows into shared tables owned by other
applications.

For example:
- `MYAPP` inserts rows into `app_dictionary`
- `app_dictionary` is owned by `CORE`

Without ownership tracking, those rows become orphaned when `MYAPP`
is later removed.

### How it works

`add_object_metadata_p` records:
- the target table name
- a discriminator column
- a discriminator value

Together, these identify the rows owned by the registering application.

When `delete_application_p` is called, Core loops through all
registered metadata and executes:

```sql
DELETE FROM <table>
WHERE <discriminator_col> = <discriminator_val>;
```

### Usage example

```sql
-- MYAPP deployment: seed reference data into another app's table
INSERT INTO product_category (
    owning_app,
    category_code,
    description
)
VALUES (
    'MYAPP',
    'WIDGET',
    'Widget category'
);

-- Register those rows for automatic cleanup
EXEC pkg_application.add_object_metadata_p(
       ip_application_name  => 'MYAPP',
       ip_object_name       => 'PRODUCT_CATEGORY',
       ip_object_type       => pkg_application.c_object_type_table,
       ip_discriminator_col => 'OWNING_APP',
       ip_discriminator_val => 'MYAPP');

-- Later: removing MYAPP automatically deletes its rows
EXEC pkg_application.delete_application_p(
       ip_application_name => 'MYAPP');
```

### Custom cleanup with dml_override_proc

When a plain `DELETE` is not sufficient — for example, when an
application creates dynamic database objects such as:
- queues
- sequences
- subsidiary tables

keyed by a discriminator value, the `ip_dml_override_proc`
parameter names a procedure to call instead of the default `DELETE`.

The procedure is invoked as:

```sql
BEGIN <proc_name>; END;
```

and is responsible for all cleanup.

```sql
-- MYAPP creates a private queue at deploy time
EXEC pkg_application.add_object_metadata_p(
       ip_application_name  => 'MYAPP',
       ip_object_name       => 'APP_OBJECTS',
       ip_object_type       => pkg_application.c_object_type_table,
       ip_discriminator_col => 'APPLICATION_NAME',
       ip_discriminator_val => 'MYAPP',
       ip_dml_override_proc => 'myapp_cleanup.drop_private_queue_p');
```

---

## Roadmap

Planned future capabilities include:
- transport-style deployment orchestration
- environment promotion workflows
- deployment validation
- automated dependency resolution
- CI/CD integration
- richer metadata introspection

---

## Compatibility

Currently developed and tested against Oracle Database 19c.

---

## Status

This project is under active development and APIs may evolve.

---

## License

Licensed under the Apache License, Version 2.0.

See the `LICENSE` file for details.
