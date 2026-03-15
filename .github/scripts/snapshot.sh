#!/usr/bin/env bash
# Snapshot manager for the "filesystem" tag workflow.
#
# This script lets you create/restore/list named snapshots of the filesystem state
# used by the tmate runner. Snapshots are stored as git tags of the form
# "snapshot/<name>" (and a rolling "snapshot/latest" tag).
#
# Usage:
#   ./snapshot.sh save <name>    # create a snapshot from current working tree
#   ./snapshot.sh restore <name> # restore snapshot into the filesystem tag
#   ./snapshot.sh list           # list available snapshots
#   ./snapshot.sh latest         # show the latest snapshot
#   ./snapshot.sh delete <name>  # delete a snapshot tag (local+remote)

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  echo "ERROR: not inside a git repository" >&2
  exit 1
fi
cd "$repo_root"

remote=${REMOTE:-origin}

push_tag() {
  local tag=$1
  local target=$2
  git tag -f "$tag" "$target"
  git push -f "$remote" "refs/tags/$tag:refs/tags/$tag"
}

fetch_tags() {
  git fetch --tags "$remote" "refs/tags/snapshot/*:refs/tags/snapshot/*" || true
  git fetch --tags "$remote" "refs/tags/filesystem:refs/tags/filesystem" || true
}

ensure_filesystem_tag() {
  # Ensure that the "filesystem" tag exists; if not, create it from current HEAD.
  if ! git rev-parse -q --verify "refs/tags/filesystem" >/dev/null; then
    echo "[snapshot] creating initial filesystem tag"
    git tag filesystem
    git push -f "$remote" "refs/tags/filesystem:refs/tags/filesystem"
  fi
}

usage() {
  cat <<'EOF'
Usage: snapshot.sh <command> [args]

Commands:
  save <name>      Create a snapshot from the current working tree (pushes tag)
  restore <name>   Restore a snapshot into the "filesystem" tag (pushes tag)
  list             List available snapshot tags
  latest           Show the current "latest" snapshot tag
  delete <name>    Delete a snapshot tag (local + remote)
  help             Show this help

Environment:
  REMOTE           Git remote name (default: origin)
EOF
  exit 1
}

if [ $# -lt 1 ]; then
  usage
fi

cmd=$1; shift
case "$cmd" in
  save)
    if [ $# -ne 1 ]; then
      usage
    fi
    name=$1
    fetch_tags
    ensure_filesystem_tag

    # Ensure we are on the filesystem snapshot branch
    if git rev-parse -q --verify "refs/tags/filesystem" >/dev/null; then
      git checkout -B filesystem-workspace refs/tags/filesystem
      git reset --hard refs/tags/filesystem
    else
      git checkout --orphan filesystem-workspace
      git rm -rf --cached . 2>/dev/null || true
      git clean -fdx -e .git -e .gitignore -e .github -e .github/scripts -e .github/workflows
      git commit --allow-empty -m "init filesystem (empty)" || true
    fi

    # Stage everything (respect .gitignore)
    git add -A
    if ! git diff --cached --quiet; then
      git commit -m "snapshot ${name} $(date -u +%Y%m%dT%H%M%SZ)" || true
    fi

    revision=$(git rev-parse HEAD)
    push_tag "snapshot/${name}" "$revision"
    push_tag "snapshot/latest" "$revision"

    # Update the filesystem tag to point at the same commit.
    push_tag filesystem "$revision"

    echo "Saved snapshot: snapshot/${name} (rev ${revision:0:10})"
    ;;

  restore)
    if [ $# -ne 1 ]; then
      usage
    fi
    name=$1
    fetch_tags

    tag="snapshot/${name}"
    if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
      echo "ERROR: snapshot '$name' not found" >&2
      exit 2
    fi

    revision=$(git rev-parse "refs/tags/$tag")
    echo "Restoring snapshot '$name' (rev ${revision:0:10})"

    # Reset workspace to snapshot commit.
    git checkout -B filesystem-workspace "$revision"
    git reset --hard "$revision"

    push_tag filesystem "$revision"
    push_tag "snapshot/latest" "$revision"

    echo "Restored and updated filesystem tag to snapshot/${name}."
    ;;

  list)
    fetch_tags
    git tag --list 'snapshot/*' | sort
    ;;

  latest)
    fetch_tags
    if git rev-parse -q --verify "refs/tags/snapshot/latest" >/dev/null; then
      tag="snapshot/latest"
      rev=$(git rev-parse "$tag")
      echo "$tag -> $rev"
    else
      echo "No snapshot/latest tag found"
      exit 1
    fi
    ;;

  delete)
    if [ $# -ne 1 ]; then
      usage
    fi
    name=$1
    tag="snapshot/${name}"
    git tag -d "$tag" 2>/dev/null || true
    git push --delete "$remote" "$tag" 2>/dev/null || true
    echo "Deleted snapshot: $tag";
    ;;

  help|--help|-h)
    usage
    ;;

  *)
    usage
    ;;
esac
