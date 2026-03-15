# reverse-action (tmate remote session runner)

This repository is set up to run an interactive `tmate` session inside a GitHub Actions workflow and persist the filesystem state between runs using a Git tag named `filesystem`.

## 🧠 Snapshot system (full VPS-like save/restore)

We provide a small helper script to take named snapshots of the workspace and restore them later.

### How it works

- Snapshots are stored as **git tags** named `snapshot/<name>`.
- The workflow uses a special tag `filesystem` to represent the current working state of the remote session.
- Restoring a snapshot updates the `filesystem` tag so the next workflow run boots into that state.

### Available snapshot actions

Run the helper script in the repo root:

```bash
# Create a snapshot named "clean" (pushes to remote):
./.github/scripts/snapshot.sh save clean

# Restore a snapshot into the next tmate session:
./.github/scripts/snapshot.sh restore clean

# List available snapshots:
./.github/scripts/snapshot.sh list

# Show the latest snapshot pointer:
./.github/scripts/snapshot.sh latest

# Delete a snapshot:
./.github/scripts/snapshot.sh delete clean
```

### Booting a specific snapshot automatically

You can set the `SNAPSHOT` environment variable in the workflow dispatch or in the workflow YAML to boot a specific snapshot.

Example (workflow `ssh.yml`):

```yaml
jobs:
  debug:
    runs-on: ubuntu-latest
    env:
      SNAPSHOT: clean
    steps:
      # ...
```

This makes the runner behave more like a VPS restore: it will start directly from the named snapshot.

### Autosave snapshots (optional)

If you want the system to keep historical snapshots automatically (in addition to the rolling `filesystem` tag), enable the `AUTOSNAPSHOT` flag.

```yaml
env:
  AUTOSNAPSHOT: 1
```

Every autosave will create a timestamped tag like `snapshot/auto-20260101T123456Z` and update `snapshot/latest`.

---

## 🧩 Live session link in README

The workflow will keep `README.md` updated with the live `tmate` session links inside a block named:

```md
<!-- TMATE-SESSION-START -->
## Live tmate session

- SSH: ...
- Web: ...
<!-- TMATE-SESSION-END -->
```

When the workflow runs, it updates that block automatically.
