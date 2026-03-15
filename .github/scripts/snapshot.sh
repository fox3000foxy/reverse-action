#!/usr/bin/env bash
# Helper script to manage the persistent "filesystem" branch used by the tmate runner.
#
# This repository stores the working filesystem state in a dedicated branch named
# "filesystem". This script helps initialize/reset/inspect that branch.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  echo "ERROR: not inside a git repository" >&2
  exit 1
fi
cd "$repo_root"

remote=${REMOTE:-origin}

usage() {
  cat <<'EOF'
Usage: snapshot.sh <command> [args]

Commands:
  init [<ref>]      Create/overwrite the filesystem branch from <ref> (default: HEAD)
  reset <ref>       Reset filesystem branch to <ref> (e.g. main)
  show              Show the current filesystem branch tip
  delete            Delete the filesystem branch (local + remote)
  help              Show this help

Environment:
  REMOTE            Git remote name (default: origin)
EOF
  exit 1
}

if [ $# -lt 1 ]; then
  usage
fi

cmd=$1; shift
case "$cmd" in
  init)
    ref=${1:-HEAD}
    if ! git rev-parse -q --verify "$ref" >/dev/null; then
      echo "ERROR: ref '$ref' not found" >&2
      exit 1
    fi

    git checkout -B filesystem "$ref"
    git push -u "$remote" filesystem:filesystem --force
    ;;

  reset)
    if [ $# -ne 1 ]; then
      usage
    fi
    ref=$1
    if ! git rev-parse -q --verify "$ref" >/dev/null; then
      echo "ERROR: ref '$ref' not found" >&2
      exit 1
    fi

    git checkout -B filesystem "$ref"
    git push --force "$remote" filesystem:filesystem
    ;;

  show)
    if git rev-parse -q --verify "refs/heads/filesystem" >/dev/null; then
      git log -1 --oneline filesystem
    else
      echo "filesystem branch does not exist"
      exit 1
    fi
    ;;

  delete)
    git branch -D filesystem 2>/dev/null || true
    git push --delete "$remote" filesystem 2>/dev/null || true
    echo "Deleted filesystem branch (local + remote)"
    ;;

  help|--help|-h)
    usage
    ;;

  *)
    usage
    ;;
esac
