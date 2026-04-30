#!/usr/bin/env bash
set -euo pipefail

# Publish new EN posts to dev.to as drafts.
# Requires DEV_TO_API_KEY environment variable.

if [ -z "${DEV_TO_API_KEY:-}" ]; then
  echo "DEV_TO_API_KEY not set, skipping dev.to publish"
  exit 0
fi

SITE_URL="https://alessandra.bilardi.net/diary"

for post_file in _posts/*.en.md; do
  [ -f "$post_file" ] || continue

  # Extract frontmatter fields
  title=$(sed -n 's/^title: *"\(.*\)"/\1/p' "$post_file" | head -1)
  tags=$(sed -n 's/^tags: *\[\(.*\)\]/\1/p' "$post_file" | head -1 | tr -d ' ')
  date=$(sed -n 's/^date: *\(.*\)/\1/p' "$post_file" | head -1)

  # Build canonical URL from permalink pattern: /articles/YYYY-MM/title
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
  year_month=$(echo "$date" | cut -d- -f1-2)
  canonical_url="${SITE_URL}/articles/${year_month}/${slug}.en"

  # Extract body (everything after second ---)
  body=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$post_file")

  # Check if already published on dev.to (search by canonical URL).
  # canonical_url is passed via env var to avoid interpolating into Python code.
  existing=$(curl -s -H "api-key: ${DEV_TO_API_KEY}" \
    "https://dev.to/api/articles/me?per_page=100" | \
    CANONICAL_URL="$canonical_url" python3 -c '
import sys, json, os
articles = json.load(sys.stdin)
url = os.environ["CANONICAL_URL"]
print("found" if any(a.get("canonical_url", "") == url for a in articles) else "not_found")
' 2>/dev/null || echo "error")

  if [ "$existing" = "found" ]; then
    echo "  Already on dev.to: $title"
    continue
  fi

  echo "  Publishing draft to dev.to: $title"

  # Build JSON payload safely: all inputs are passed via environment variables,
  # so titles/bodies containing apostrophes or other special characters are
  # serialized correctly by json.dumps without shell quoting issues.
  payload=$(TITLE="$title" BODY="$body" CANONICAL_URL="$canonical_url" TAGS="$tags" python3 -c '
import json, os
tags = [t.strip() for t in os.environ["TAGS"].split(",") if t.strip()][:4]
print(json.dumps({
    "article": {
        "title": os.environ["TITLE"],
        "body_markdown": os.environ["BODY"],
        "canonical_url": os.environ["CANONICAL_URL"],
        "published": False,
        "tags": tags,
    }
}))')

  # Publish as draft
  response=$(curl -s -w "\n%{http_code}" -X POST "https://dev.to/api/articles" \
    -H "api-key: ${DEV_TO_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  http_code=$(echo "$response" | tail -1)
  response_body=$(echo "$response" | sed '$d')

  if [ "$http_code" = "201" ]; then
    echo "  Draft created on dev.to: $title"
  else
    echo "  Error publishing to dev.to (HTTP $http_code): $response_body"
  fi
done

echo "--- dev.to publish done ---"
