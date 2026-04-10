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
  canonical_url="${SITE_URL}/articles/${year_month}/${slug}"

  # Extract body (everything after second ---)
  body=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$post_file")

  # Check if already published on dev.to (search by canonical URL)
  existing=$(curl -s -H "api-key: ${DEV_TO_API_KEY}" \
    "https://dev.to/api/articles/me?per_page=100" | \
    python3 -c "import sys,json; articles=json.load(sys.stdin); print('found' if any(a.get('canonical_url','') == '${canonical_url}' for a in articles) else 'not_found')" 2>/dev/null || echo "error")

  if [ "$existing" = "found" ]; then
    echo "  Already on dev.to: $title"
    continue
  fi

  echo "  Publishing draft to dev.to: $title"

  # Convert tags to JSON array (dev.to max 4 tags)
  tags_json=$(echo "$tags" | tr ',' '\n' | head -4 | python3 -c "import sys,json; print(json.dumps([t.strip() for t in sys.stdin.read().strip().split('\n') if t.strip()]))")

  # Escape body for JSON
  body_json=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" <<< "$body")

  # Publish as draft
  response=$(curl -s -w "\n%{http_code}" -X POST "https://dev.to/api/articles" \
    -H "api-key: ${DEV_TO_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json
print(json.dumps({
    'article': {
        'title': $(python3 -c "import json; print(json.dumps('$title'))"),
        'body_markdown': $body_json,
        'canonical_url': '$canonical_url',
        'published': False,
        'tags': $tags_json
    }
}))
")")

  http_code=$(echo "$response" | tail -1)
  response_body=$(echo "$response" | sed '$d')

  if [ "$http_code" = "201" ]; then
    echo "  Draft created on dev.to: $title"
  else
    echo "  Error publishing to dev.to (HTTP $http_code): $response_body"
  fi
done

echo "--- dev.to publish done ---"
