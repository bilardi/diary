#!/usr/bin/env bash
set -euo pipefail

# Collect POST.it.md and POST.en.md from source repos and generate Jekyll posts.
# Runs from the diary repo root (pwd = diary/).

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Read repos from sources.yml (simple parsing, no yq needed)
REPOS=$(grep -E '^\s*-\s+' sources.yml | sed 's/^\s*-\s*//')

for repo in $REPOS; do
  echo "--- Processing $repo ---"

  # Special case: bilardi/diary is the current repo
  if [ "$repo" = "bilardi/diary" ]; then
    REPO_DIR="."
  else
    REPO_DIR="$TMPDIR/$repo"
    git clone --depth 1 "https://github.com/${repo}.git" "$REPO_DIR"
  fi

  # Detect default branch
  if [ "$REPO_DIR" = "." ]; then
    DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  else
    DEFAULT_BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)
  fi

  OWNER=$(echo "$repo" | cut -d/ -f1)
  REPONAME=$(echo "$repo" | cut -d/ -f2)

  # Process each POST file (POST.it.md, POST.en.md, and plain POST.md)
  for post_file in "$REPO_DIR"/POST.it.md "$REPO_DIR"/POST.en.md "$REPO_DIR"/POST.md; do
    [ -f "$post_file" ] || continue

    basename_file=$(basename "$post_file")

    # Determine language from filename
    case "$basename_file" in
      POST.it.md) LANG="it" ;;
      POST.en.md) LANG="en" ;;
      POST.md)    LANG="it" ;;  # default to Italian for plain POST.md
      *)          continue ;;
    esac

    echo "  Found $basename_file (lang=$LANG)"

    # Extract frontmatter (between first and second ---)
    frontmatter=$(sed -n '/^---$/,/^---$/p' "$post_file" | sed '1d;$d')

    # Extract fields from frontmatter
    title=$(echo "$frontmatter" | grep '^title:' | sed 's/^title:\s*//' | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
    date=$(echo "$frontmatter" | grep '^date:' | sed 's/^date:\s*//')
    categories=$(echo "$frontmatter" | grep '^categories:' | sed 's/^categories:\s*//')
    tags=$(echo "$frontmatter" | grep '^tags:' | sed 's/^tags:\s*//')
    fm_repo=$(echo "$frontmatter" | grep '^repo:' | sed 's/^repo:\s*//')
    social_summary=$(echo "$frontmatter" | grep '^social_summary:' | sed 's/^social_summary:\s*//' || true)

    # Use repo from frontmatter if present, otherwise use the source repo
    if [ -z "$fm_repo" ]; then
      fm_repo="$repo"
    fi

    # Generate slug from title: lowercase, replace spaces/special chars with hyphens
    slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

    # Extract body: everything after the second ---
    body=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$post_file")

    # Rewrite any relative image path to a raw.githubusercontent.com URL.
    # Absolute URLs (http://, https://, /) are left untouched.
    RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPONAME}/${DEFAULT_BRANCH}"
    body=$(RAW_BASE="$RAW_BASE" python3 -c '
import os, re, sys
raw_base = os.environ["RAW_BASE"]
def rewrite(m):
    alt, url = m.group(1), m.group(2)
    if url.startswith(("http://", "https://", "/")):
        return m.group(0)
    if url.startswith("./"):
        url = url[2:]
    return f"![{alt}]({raw_base}/{url})"
sys.stdout.write(re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", rewrite, sys.stdin.read()))
' <<< "$body")

    # Determine output filename
    if [ "$LANG" = "it" ]; then
      OUTPUT="_posts/${date}-${slug}.it.md"
    else
      OUTPUT="_posts/${date}-${slug}.en.md"
    fi

    # Write Jekyll post
    # Build optional frontmatter fields
    extra_fm=""
    if [ -n "$social_summary" ]; then
      extra_fm="social_summary: ${social_summary}"
    fi

    cat > "$OUTPUT" <<POSTEOF
---
layout: post
title: "${title}"
date: ${date}
categories: ${categories}
tags: ${tags}
repo: ${fm_repo}
lang: ${LANG}
${extra_fm}
---
${body}
POSTEOF

    echo "  Wrote $OUTPUT"
  done
done

echo "--- Done ---"
