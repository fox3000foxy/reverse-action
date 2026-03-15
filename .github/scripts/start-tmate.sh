set -euo pipefail

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# Ensure we have the latest filesystem tag from remote
# If SNAPSHOT is set, try to restore it into the filesystem tag (makes startup match a named snapshot).
if [ -n "${SNAPSHOT:-}" ]; then
  echo "[start-tmate] restoring snapshot: ${SNAPSHOT}"
  git fetch --tags origin "refs/tags/snapshot/${SNAPSHOT}:refs/tags/snapshot/${SNAPSHOT}" || true
  if git rev-parse -q --verify "refs/tags/snapshot/${SNAPSHOT}" >/dev/null; then
    git tag -f filesystem "refs/tags/snapshot/${SNAPSHOT}"
    git push origin --force refs/tags/filesystem:refs/tags/filesystem
  else
    echo "[start-tmate] snapshot '${SNAPSHOT}' not found; continuing with filesystem tag"
  fi
fi

git fetch --tags origin "refs/tags/filesystem:refs/tags/filesystem" || true

# Cache helper scripts so they remain available even if the filesystem tag is empty
RUNNER_SCRIPTS_DIR="/tmp/runner-scripts"
rm -rf "$RUNNER_SCRIPTS_DIR"
mkdir -p "$RUNNER_SCRIPTS_DIR"
cp -r .github/scripts "$RUNNER_SCRIPTS_DIR/" 2>/dev/null || true

# Run optional prestart hook (if present) after restoring the filesystem tag
if [ -f ".github/scripts/prestart.sh" ]; then
  echo "Running prestart script"
  bash .github/scripts/prestart.sh
fi

push_tag() {
  git tag -f filesystem
  # Push tag explicitly (avoid "matches more than one" when a branch has the same name)
  git push origin --force refs/tags/filesystem:refs/tags/filesystem
}

# Checkout the tag content into a working branch so we can modify it.
# Reset/clean to ensure the working tree matches the tag exactly.
if git rev-parse -q --verify "refs/tags/filesystem" >/dev/null; then
  git checkout -B filesystem-workspace refs/tags/filesystem
  git reset --hard refs/tags/filesystem
  # Keep cache dirs (apt cache, etc.) from being deleted and avoid permission issues
  git clean -fdx -e .apt-cache -e .cache -e host.conf -e tmate.sock
else
  # Create an empty filesystem branch (no files) to avoid importing main content
  git checkout --orphan filesystem-workspace
  git rm -rf --cached . || true
  git clean -fdx -e .git -e .apt-cache -e .cache -e .github -e .github/scripts -e .github/workflows
  git commit --allow-empty -m "init filesystem (empty)" || true
  push_tag || true
fi

# Ensure the filesystem tag exists for next run
push_tag || true

autosave() {
  # Watch filesystem changes (ignore Git metadata, caches and temporary session state) and commit/push immediately
  while inotifywait -qq -r -e modify,create,delete,move --exclude '(^|/)(\.git|\.apt-cache|\.cache|host\.conf|tmate\.sock|\.gitignore)(/|$)' .; do
    echo "[autosave] change detected"
    commit_and_push
    # debounce bursty changes (same file saved multiple times quickly)
    sleep 1
  done
}

commit_and_push() {
  # Use an exclusive lock so multiple autosave loops don't run the git commands concurrently.
  (
    flock -n 200 || return

    # Add all changes (respect .gitignore). Explicitly avoid committing workflow/script changes.
    git add -A
    git reset -- .github/workflows/ .github/scripts/ 2>/dev/null || true

    if ! git diff --cached --quiet; then
      # Keep a single commit in the filesystem tag by amending the existing commit.
      if git rev-parse --verify HEAD >/dev/null 2>&1; then
        git commit --amend --no-edit || true
      else
        git commit -m "autosave $(date -u +%Y%m%dT%H%M%SZ)" || true
      fi

      # Push filesystem tag for the current commit.
      push_tag || true

      # Optionally create a named snapshot tag every autosave.
      if [ "${AUTOSNAPSHOT:-0}" = "1" ]; then
        snap="snapshot/auto-$(date -u +%Y%m%dT%H%M%SZ)"
        git tag -f "$snap" HEAD
        git push -f origin "refs/tags/$snap:refs/tags/$snap" || true
        git tag -f snapshot/latest HEAD
        git push -f origin refs/tags/snapshot/latest:refs/tags/snapshot/latest || true
      fi
    fi
  ) 200>/tmp/tmate_autosave.lock
}

autosave &
autosave_pid=$!

periodic_save() {
  while true; do
    git pull
    sleep 5
    echo "[periodic autosave]"
    commit_and_push
  done
}

periodic_save &
periodic_save_pid=$!

if [ -f startup.sh ]; then
  echo "startup.sh exists; running it before starting tmate"
  chmod +x startup.sh
  bash startup.sh &
fi

# Start tmate in a loop so we can restart it automatically if the session ends.
# This makes reconnecting stable even after "exit".
while true; do
  tmate -S /tmp/tmate.sock new-session -d "bash --rcfile $HOME/.bashrc -i"
  # Keep the tmux session alive after the shell exits so clients can reconnect.
  tmate -S /tmp/tmate.sock set-option -g remain-on-exit on

  # Wait for tmate to generate session URLs (can take a short moment)
  until tmate -S /tmp/tmate.sock display -p '#{tmate_ssh}' >/dev/null 2>&1; do
    sleep 0.2
  done

  tmate_ssh=$(tmate -S /tmp/tmate.sock display -p '#{tmate_ssh}')
  tmate_web=$(tmate -S /tmp/tmate.sock display -p '#{tmate_web}')

  # Write a helper script that contains only the host string (username@host).

  # Also write a host.conf file containing only the host string, so it can be fetched via gh api.
  printf '%s' "${tmate_ssh#ssh }" > host.conf

  source "$HOME/.bashrc"

  echo "=== tmate connection ==="
  echo "SSH: ${tmate_ssh}"
  echo "WEB: ${tmate_web}"
  echo "RUN (gh): ssh \"\$(gh api -H 'Accept: application/vnd.github.v3.raw' \"/repos/${GITHUB_REPOSITORY}/contents/host.conf?ref=filesystem\" | tr -d '\r\n')\""
  echo "========================"

  # Update README with the live session link(s)
  python3 "$RUNNER_SCRIPTS_DIR/scripts/update_readme.py" \
    --ssh "$tmate_ssh" \
    --web "$tmate_web" \
    --run-cmd "ssh \"\$(gh api -H 'Accept: application/vnd.github.v3.raw' \"/repos/${GITHUB_REPOSITORY}/contents/host.conf?ref=filesystem\" | tr -d '\r\n')\""

  # Wait until tmate session is gone, then restart it
  while tmate -S /tmp/tmate.sock display -p '#{tmate_ssh}' >/dev/null 2>&1; do
    sleep 2
  done

  echo "tmate session ended; restarting..."
done