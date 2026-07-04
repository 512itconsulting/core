# Core vs dbpm

Core and dbpm work together, but they own different parts of the deployment
system.

Core is the in-database registry and lifecycle substrate. It records the state
of applications after deployment activity reaches the database.

dbpm is the external package, artifact, and orchestration tool. It resolves what
should be deployed, where it comes from, and how deployment commands are run.

Keeping this boundary clear helps Core remain stable while allowing dbpm to
evolve package distribution, dependency resolution, and deployment workflows.

## Core Responsibilities

Core answers questions about installed database state:

- What applications exist in this database?
- What version or deployment of an application is registered?
- Who deployed it?
- When was it deployed?
- What objects belong to an application?
- What privileges and object dependencies were registered?
- What metadata rows are owned by an application?
- What deployment provenance was recorded for the completed deployment?

The primary API boundary for this is `pkg_application`. Normal application
deployments should use `pkg_application` to register deployment metadata,
dependencies, privileges, owned objects, and metadata ownership before creating
or replacing application objects.

Core's own initial deployment is a bootstrap exception because
`pkg_application` does not exist yet.

## Deployment Environment and Lock Policy

Core owns the in-database deployment metadata that describes the current
database and its safety posture.

`DEPLOY_ENVIRONMENT` in `APP_DICTIONARY` is a human-readable label, such as
`DEV`, `QLAB01`, `PLAB`, or `PROD`. It should be used only as a reminder of
where the schema is installed.

`DEPLOY_LOCKED` in `APP_DICTIONARY` is the authoritative deployment safety
policy input. It is required during Core install/bootstrap, must be `Y` or `N`,
and is stored as uppercase. `Y` means dbpm and other deployment tooling should
treat the database as protected and block development-only or destructive
behavior. `N` means development workflows are allowed, subject to explicit
destructive-action flags.

Core's `pkg_app_dict.set_deployment_metadata_p` initializes `DEPLOY_LOCKED` but
does not change an existing lock value. Later lock changes should be deliberate
operational dictionary updates.

dbpm should read `DEPLOY_LOCKED` from Core rather than deriving safety policy
from `DEPLOY_ENVIRONMENT` or from an external environment name.

## dbpm Responsibilities

dbpm answers questions about packages, artifacts, and deployment intent:

- Where do packages come from?
- What package version should be installed?
- What dependency versions are required?
- In what order should applications be deployed?
- How are packages built, published, distributed, and fetched?
- What artifact checksum, source commit, and build metadata were resolved?
- Is this an install, upgrade, validation, dry run, bootstrap, or explicit
  destructive reinstall?

dbpm should own artifact resolution, package repository access, dependency
ordering, provenance injection, and deployment mode selection.

## Shared Concepts

Some concepts appear in both layers, but each layer has a different role.

| Concept | Core Role | dbpm Role |
|---|---|---|
| Application identity | Records installed application state, such as `CORE` | Maps package and repository identities to deployment manifests |
| Version | Stores the deployed semantic version | Selects the version to install or validate |
| Dependencies | Records declared application, privilege, and object dependencies | Resolves dependency versions and deployment order |
| Provenance | Stores provenance for completed deployments | Gathers artifact, checksum, source, and build metadata |
| Artifacts | Records resolved artifact metadata | Builds, publishes, fetches, and verifies artifacts |
| Deployment mode | Records deployment lifecycle metadata | Chooses install, upgrade, validate, dry-run, bootstrap, or reinstall behavior |
| Cleanup | Tracks owned objects and metadata for uninstall | Decides whether destructive behavior is allowed for the environment |

In short:

- Core records what happened in the database.
- dbpm decides what should happen before calling into the database.

## Boundary Rules

- Registry activity should go through `pkg_application`.
- Core should not directly resolve package repositories or artifact locations.
- Core should not choose dependency versions.
- Core should not hard-code source commit hashes in committed deployment
  wrappers.
- dbpm should inject provenance from artifact metadata or repository state.
- dbpm should treat `delete_application_p` before an initial deployment as an
  explicit destructive reinstall path, not as the default install path.
- `pkg_application.delete_system_p` is a destructive development reset API and
  should require exact confirmation and `DEPLOY_LOCKED=N`.
- Destructive reinstall behavior should be gated for development or pre-prod
  environments and avoided for established environments unless clearly
  requested.

## Design Implications

Core should prefer additive, backward-compatible schema and API evolution. It is
the long-lived runtime substrate already installed in databases.

dbpm can move faster around packaging, repository formats, dependency solving,
artifact verification, and workflow ergonomics because those concerns live
outside the database.

When a new feature crosses the boundary, a useful test is:

- If the feature records installed database state, it likely belongs in Core.
- If the feature decides what to install, where to get it, or how to run it, it
  likely belongs in dbpm.

For example, Core can store dependency declarations and completed deployment
provenance. dbpm should resolve those dependencies, verify artifacts, and pass
the resolved provenance values into Core.
