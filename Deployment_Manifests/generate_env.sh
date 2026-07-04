#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir/.." rev-parse --show-toplevel)
out_file="${1:-$script_dir/env.sql}"

# Manual orchestration scripts commonly live in a Deployment_Manifests folder
# beside the package folders. In that shape, scan the parent folder. In Core's
# single-package shape, this still falls back to the repository root below.
if [ "$(basename "$script_dir")" = "Deployment_Manifests" ]; then
   scan_root=$(dirname "$script_dir")
else
   scan_root=$repo_root
fi

# SQL*Plus DEFINE names are easier to use consistently when they are uppercase
# and do not contain hyphens.
to_define_name() {
   printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

# A dbpm workspace may contain several package folders in one git repository.
# We identify package folders by the conventional database source directories
# rather than by requiring dbpm.yaml.
is_package_dir() {
   [ -d "$1/Deployment_Manifests" ] ||
      [ -d "$1/Packages" ] ||
      [ -d "$1/Tables" ] ||
      [ -d "$1/Types" ] ||
      [ -d "$1/Metadata" ]
}

# Record the most recent commit that touched this package folder. This lets
# multiple packages in the same repository carry distinct provenance values.
write_define() {
   package_dir=$1
   package_name=$(basename "$package_dir")
   define_name=$(to_define_name "$package_name")

   if package_hash=$(git -C "$repo_root" log -1 --pretty=format:%H -- "$package_dir") &&
      [ -n "$package_hash" ]; then
      printf "DEFINE %s = %s\n" "$define_name" "$package_hash" >> "$out_file"
   fi
}

# Recreate the generated file each time so removed packages do not leave stale
# substitution variables behind.
: > "$out_file"
package_found=N

# First look for package-like children. This is the multi-package workspace
# shape where each child directory represents an independently deployed package.
for package_dir in "$scan_root"/*; do
   [ -d "$package_dir" ] || continue
   [ "$(basename "$package_dir")" != ".git" ] || continue

   if is_package_dir "$package_dir"; then
      package_found=Y
      write_define "$package_dir"
   fi
done

# If no child package folders were found, treat the repository root itself as
# the package. This is the shape used by Core.
if [ "$package_found" = N ]; then
   write_define "$repo_root"
fi

printf "Wrote %s\n" "$out_file"
