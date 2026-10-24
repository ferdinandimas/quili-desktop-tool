#!/usr/bin/env bash
# Stages everything and makes one local commit as the personal GitHub identity (ferdinandimas). It never pushes.
#
#   tools/commit.sh "Short subject" ["Body paragraph" ...]
#
# Every argument becomes its own paragraph of the commit message (the first one is the subject), so the message is
# the parameter. Run it from anywhere inside the repository.
set -euo pipefail

NAME="Ferdinand Dimas"
EMAIL="ferdinandimas@gmail.com"

if [ "$#" -lt 1 ] || [ -z "${1// }" ]; then
  echo "usage: tools/commit.sh \"Short subject\" [\"Body paragraph\" ...]" >&2
  exit 2
fi

cd "$(git rev-parse --show-toplevel)"

# This repository only ever uses the personal identity: fix the repo-local config if it drifted (the global one is
# the work identity).
[ "$(git config --local user.name || true)" = "$NAME" ] || git config --local user.name "$NAME"
[ "$(git config --local user.email || true)" = "$EMAIL" ] || git config --local user.email "$EMAIL"

git add -A
if git diff --cached --quiet; then
  echo "Nothing to commit." >&2
  exit 1
fi

set -- "${@/Co-Authored-By: Claude <noreply@anthropic.com>/}"

args=()
for paragraph in "$@"; do args+=(-m "$paragraph"); done
git commit -q "${args[@]}"
git log --oneline -1
