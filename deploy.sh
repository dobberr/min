#!/usr/bin/env bash
# One-shot deploy for the Mineral web client.
#
#   ./deploy.sh                    commit changes as "Update game build", push, publish, verify
#   ./deploy.sh -m "your message"  use a custom commit message
#   ./deploy.sh --force            publish again even when nothing changed
#   ./deploy.sh --dry-run          preflight checks + show pending changes, no writes
#
# Surge caps a project at 450 MB and this repo is ~525 MiB, so .surgeignore
# trims the extra locales and jukebox discs. It is recreated here if missing
# and is deliberately never committed.
set -euo pipefail

cd -- "$(dirname -- "$0")"

DOMAIN="mineral.surge.sh"
MSG="Update game build"
FORCE=0
DRY=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    -m|--message) [[ $# -ge 2 ]] || die "missing message after $1"; MSG="$2"; shift 2 ;;
    -f|--force)   FORCE=1; shift ;;
    -n|--dry-run) DRY=1; shift ;;
    -h|--help)    sed -n '2,9p' "$0"; exit 0 ;;
    *)            die "unknown option: $1 (try --help)" ;;
  esac
done

# ---- preflight -------------------------------------------------------------
for tool in git surge curl node; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done
surge whoami >/dev/null 2>&1 || die "surge is not logged in — run: surge login"
git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote configured"

BRANCH=$(git branch --show-current)
[[ -n "$BRANCH" ]] || die "detached HEAD — check out a branch first"
git fetch --quiet origin || die "git fetch failed"
BEHIND=$(git rev-list --count "HEAD..origin/$BRANCH")
(( BEHIND == 0 )) || die "origin/$BRANCH is $BEHIND commit(s) ahead — pull/rebase first"

if (( DRY )); then
  echo "--- dry run: pending changes ---"
  git status --short
  [[ -f .surgeignore ]] || echo "(would recreate .surgeignore)"
  echo "--- dry run: no commit, push or publish performed ---"
  exit 0
fi

# Keep deploy artifacts out of `git status`; both are local-only.
for f in .surgeignore CNAME; do
  grep -qxF "$f" .git/info/exclude 2>/dev/null || printf '%s\n' "$f" >> .git/info/exclude
done

if [[ ! -f .surgeignore ]]; then
  cat > .surgeignore <<'EOF'
# Surge caps a project at 450 MB; this repo is ~525 MiB.
# The base language (en_us) already ships inside fs/boot.tar.gz, so the
# extra locales under fs/res are the only thing dropped here.
fs/res/assets/minecraft/lang/*
# Jukebox discs: the biggest files left after the locales, and the least
# missed. In-game music (sounds/music) stays.
fs/res/assets/minecraft/sounds/records/*
EOF
  echo "Recreated .surgeignore"
fi

# ---- commit + push ---------------------------------------------------------
# Stage all changes. .surgeignore and CNAME are in .git/info/exclude (set
# above), so git skips them without an explicit pathspec exclude.
git add -A

DID=0
PUSHED=""
if ! git diff --cached --quiet; then
  echo "Committing: $MSG"
  git commit -m "$MSG"
  DID=1
fi

AHEAD=$(git rev-list --count "origin/$BRANCH..HEAD")
if (( AHEAD > 0 )); then
  echo "Pushing $AHEAD commit(s) to origin/$BRANCH"
  git push origin "$BRANCH"
  PUSHED=$(git rev-parse --short HEAD)
  DID=1
fi

if (( DID == 0 && FORCE == 0 )); then
  echo "Nothing changed. Use --force to republish anyway."
  exit 0
fi

# ---- publish ---------------------------------------------------------------
echo "Publishing to https://$DOMAIN ..."
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
surge . "$DOMAIN" 2>&1 | tee "$LOG"
REV=$(grep -oE "[0-9]{10,20}--${DOMAIN//./\\.}" "$LOG" | head -1 || true)

# ---- verify ----------------------------------------------------------------
echo "Verifying deployment..."
node -e '
const fs = require("fs");
const build = JSON.parse(fs.readFileSync("build.json", "utf8"));
for (const path of Object.keys(build)) console.log(path + "\t" + fs.statSync(path).size);
' | while IFS=$'\t' read -r path size; do
  live=$(curl -fsSI "https://$DOMAIN/$path" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2; exit}')
  if [[ "$live" == "$size" ]]; then
    printf '  OK  %s (%s bytes)\n' "$path" "$size"
  else
    printf '  MISMATCH  %s (local %s, live %s)\n' "$path" "$size" "${live:-none}" >&2
    exit 1
  fi
done

echo
surge "$DOMAIN" status
if [[ -n "$PUSHED" ]]; then
  printf '\nGitHub: pushed %s to origin/%s\n' "$PUSHED" "$BRANCH"
else
  printf '\nGitHub: already up to date\n'
fi
printf 'Deployed: https://%s\nRevision: %s\n' "$DOMAIN" "${REV:-unknown}"
