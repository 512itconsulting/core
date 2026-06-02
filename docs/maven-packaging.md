# Maven Packaging

dbpm-core (Core) is an Oracle PL/SQL/database tooling project, not a Java
library. Maven is used here for versioning, dependency metadata, artifact
distribution, and future dependency resolution between database repositories.

`dbpm-core` is the external project identity. The Maven artifact coordinates
remain `com.512itconsulting.database:core` for compatibility with existing dbpm
artifact resolution and deployed Core instances. The in-database application
identity also remains `CORE`.

The initial distributable artifact is a ZIP archive of the repository contents:

```text
target/core-3.4.0.zip
```

The ZIP includes source code, install/deployment scripts, documentation, manifests, examples, and tests if present. It excludes local build output, VCS metadata, GitHub workflow metadata, IDE files, and temporary files.

## Local Build

From the repository root:

```sh
mvn package
```

This runs the Maven Assembly Plugin and creates:

```text
target/core-3.4.0.zip
```

The project uses `pom` packaging because Maven is serving as a metadata and distribution tool. There is no Java compile step.

## Build Metadata

The Maven build generates a filtered properties file and packages it inside the ZIP at:

```text
META-INF/core-build.properties
```

Example contents:

```properties
artifact.groupId=com.512itconsulting.database
artifact.artifactId=core
artifact.version=0.1.0-SNAPSHOT
git.commit.id=5af0af4c86abef934e10e76744fcc05854dc580d
git.commit.id.abbrev=5af0af4
git.branch=main
git.dirty=true
build.time=2026-05-22T15:30:00Z
```

The Git values are generated dynamically from the current repository state by `git-commit-id-maven-plugin`. Maven resource filtering then combines those Git values with artifact values from `pom.xml`; `build.time` comes from Maven's build timestamp.

This supports deployment traceability without embedding Git hashes into the Maven version string. Deployment tooling can inspect the ZIP and record exactly which artifact coordinates and Git commit produced a deployed database state. Later, this metadata may be injected into `deploy_wrapper.sql` or loaded into deployment audit tables so Oracle deployments can be tied back to the source commit that produced them.

The `git.dirty` value is included as an additional traceability guard. A value of `true` means the artifact was built with uncommitted working-tree changes, so the commit hash alone does not fully describe the source content. Future release or deployment automation may choose to reject dirty builds.

The plugin first writes Git metadata under `target/generated-git/`. The Maven
Resources Plugin then uses that file as a filter and creates the final metadata
file under `target/generated-build-metadata/`. The assembly descriptor places
the resolved file at `META-INF/core-build.properties` inside the final ZIP. The
template file under `assembly/` is excluded from the ZIP so the artifact
contains resolved metadata rather than unresolved Maven placeholders.

The `core-build.properties` name is intentionally unchanged. dbpm and related
artifact consumers can rely on this path during the dbpm-core rebrand without
needing a migration.

## Publishing To GitHub Packages

The `pom.xml` publishes to GitHub Packages using this repository URL:

```text
https://maven.pkg.github.com/512itconsulting/core
```

Publish with:

```sh
mvn deploy
```

Maven will deploy the POM metadata and the attached ZIP artifact to GitHub Packages.

GitHub's Maven registry documentation is here: [Working with the Apache Maven registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-apache-maven-registry).

## Authentication

GitHub Packages requires Maven credentials in `~/.m2/settings.xml`. The `<server><id>` must match the repository id in `pom.xml`, which is currently `github`.

Example:

```xml
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <servers>
    <server>
      <id>github</id>
      <username>YOUR_GITHUB_USERNAME</username>
      <password>YOUR_GITHUB_TOKEN</password>
    </server>
  </servers>
</settings>
```

Use a GitHub personal access token with permission to publish packages for this repository. For private package consumption, consumers will also need credentials with package read access.

## Assumptions

- The package coordinates are intentionally lowercase and GitHub Packages compatible: `com.512itconsulting.database:core:3.4.0`.
- The GitHub Packages owner/repository path is `512itconsulting/core`, matching the canonical GitHub owner and repository path.
- The ZIP should preserve the repository's current layout instead of moving files into Maven's standard `src/main` tree.
- The ZIP includes Maven packaging files themselves because it is currently a repository-content distribution.
- `.claude/` is excluded as local tooling metadata, similar to IDE files.
- The artifactId remains `core` during the dbpm-core rebrand so existing
  package coordinates and dbpm artifact consumption continue to work.

## Multi-Repo Dependency Notes

Several details may matter as this becomes a dependency ecosystem across database repositories such as `utl_interval`:

- Snapshot versions are mutable by design. For repeatable database deployments, release versions such as `0.1.0` will be safer than long-lived `*-SNAPSHOT` dependencies.
- Maven dependencies can describe ordering and retrieval, but they will not understand PL/SQL install order, schema prerequisites, grants, invalid object recompilation, or rollback semantics without additional conventions.
- GitHub Packages repository URLs are scoped to an owner and repository. A multi-repo ecosystem may need a consistent convention for repository ids, package owners, and dependency repository declarations.
- ZIP artifacts are easy to distribute but opaque to Maven. If consumers need dependency-aware unpacking, install planning, or manifest validation, the ZIP contents and manifest format should become standardized across repos.
- Database compatibility metadata may eventually need to be explicit, for example supported Oracle versions, required schemas, deployment tool versions, and whether a package is installable, test-only, or metadata-only.
