#!/usr/bin/env bash
# sync-installed-skills.sh — push c11 skill source into the user-scope install.
#
# WHY THIS EXISTS
# ---------------
# c11 installs its skills (Settings → Agent Skills) as ONE-TIME COPIES into
# ~/.claude/skills/<name>/, each stamped with a `.c11-skill.json` marker. The
# app does NOT track the repo source after install — so editing a skill in
# this repo does nothing to the copy an agent actually loads until that copy is
# refreshed. Committing the source is necessary but NOT sufficient: the live
# skill on any machine where it's already installed stays stale.
#
# Run this after editing any installable skill so the installed copy matches
# source. Idempotent. Only touches skills that are (a) marked installable in
# skills/MANIFEST.json AND (b) already installed locally. The `.c11-skill.json`
# install marker is preserved (the app owns it).
#
# Usage:
#   scripts/sync-installed-skills.sh           # sync all installed installable skills
#   scripts/sync-installed-skills.sh c11       # sync just one
set -euo pipefail

REPO_SKILLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills"
DEST_ROOT="${HOME}/.claude/skills"
MANIFEST="${REPO_SKILLS}/MANIFEST.json"

[ -f "$MANIFEST" ] || { echo "error: no MANIFEST.json at $MANIFEST" >&2; exit 1; }

# Installable skill names: from positional args if given, else from the manifest.
# (Avoid `mapfile`/`readarray` — macOS ships bash 3.2, which lacks them.)
INSTALLABLE=()
if [ "$#" -gt 0 ]; then
  INSTALLABLE=("$@")
else
  while IFS= read -r line; do
    [ -n "$line" ] && INSTALLABLE+=("$line")
  done < <(python3 -c '
import json,sys
print("\n".join(json.load(open(sys.argv[1]))["installable"]))' "$MANIFEST")
fi

synced=0 skipped=0
for name in "${INSTALLABLE[@]}"; do
  src="${REPO_SKILLS}/${name}"
  dest="${DEST_ROOT}/${name}"
  if [ ! -d "$src" ]; then
    echo "skip  ${name}: no source dir (${src})" >&2; skipped=$((skipped+1)); continue
  fi
  if [ ! -d "$dest" ]; then
    echo "skip  ${name}: not installed locally (${dest}); install via c11 Settings first" >&2
    skipped=$((skipped+1)); continue
  fi
  # Mirror source → installed copy. --delete keeps removed files from lingering.
  # Preserve the app's install marker.
  rsync -a --delete --exclude='.c11-skill.json' "${src}/" "${dest}/"
  echo "sync  ${name} → ${dest}"
  synced=$((synced+1))
done

echo "done: ${synced} synced, ${skipped} skipped"
