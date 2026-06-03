# Package Publishing

dbpm-core (Core) is packaged and published with dbpm. The repository does not
use Maven build files; dbpm builds the ZIP artifact, generates Maven repository
metadata, and publishes both the ZIP and generated POM to GitHub Packages.

See [Core vs dbpm](core-vs-dbpm.md) for the boundary between Core's in-database
registry responsibilities and dbpm's package, artifact, and orchestration
responsibilities.

`dbpm-core` is the external project identity. The package coordinates remain
`com.512itconsulting.database:core` for compatibility with existing dbpm
artifact resolution and deployed Core instances. The in-database application
identity remains `CORE`.

## Publishing

From the repository root:

```sh
dbpm publish . --target gh-maven:512itconsulting/core
```

GitHub Packages publishing requires:
- `DBPM_SIGNING_KEY` set to the GPG key id, fingerprint, or email used for
  artifact signing
- `DBPM_GITHUB_TOKEN` or `GITHUB_TOKEN` with permission to publish packages

The publish settings live in `dbpm.yaml`:

```yaml
publish:
  group: com.512itconsulting.database
  artifact_id: core
```

dbpm publishes:
- `core-<version>.zip`
- `core-<version>.zip.asc`
- checksum files for the ZIP
- a generated `core-<version>.pom`
- Maven metadata for the package version list

Use `--dry-run` to verify the resolved target, group, artifact id, version, and
generated artifact names without uploading:

```sh
dbpm publish . --target gh-maven:512itconsulting/core --dry-run
```

## Build Metadata

dbpm packages build metadata inside the ZIP at:

```text
META-INF/core-build.properties
```

Example contents:

```properties
artifact.groupId=com.512itconsulting.database
artifact.artifactId=core
artifact.version=3.4.1
artifact.extension=zip
build.version=3.4.1
build.time=2026-06-02T16:49:02Z
build.source=dbpm
git.commit.id=b6cfc3d752d4c812578b04d15697d0d3f632f5d4
git.commit.id.abbrev=b6cfc3d
git.branch=main
git.dirty=false
```

This metadata allows dbpm and Core deployment provenance to record the exact
artifact coordinates, source commit, and build state for a deployed database
state.

## Assumptions

- dbpm publish support must include artifact metadata generation, first added
  on dbpm main in commit `3b86504`.
- The package coordinates are intentionally lowercase and GitHub Packages
  compatible: `com.512itconsulting.database:core:3.4.1`.
- The GitHub Packages owner/repository path is `512itconsulting/core`, matching
  the canonical GitHub owner and repository path.
- Historical Maven-built artifacts remain valid; new Core artifacts should be
  published through dbpm.
