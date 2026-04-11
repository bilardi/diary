#!/usr/bin/env bash
set -euo pipefail

# Post new EN articles to Mastodon with image.
# Requires MASTODON_ACCESS_TOKEN environment variable.

if [ -z "${MASTODON_ACCESS_TOKEN:-}" ]; then
  echo "MASTODON_ACCESS_TOKEN not set, skipping Mastodon publish"
  exit 0
fi

MASTODON_INSTANCE="https://mastodon.social"
SITE_URL="https://alessandra.bilardi.net/diary"

# Get account ID
ACCOUNT_ID=$(curl -s -H "Authorization: Bearer ${MASTODON_ACCESS_TOKEN}" \
  "${MASTODON_INSTANCE}/api/v1/accounts/verify_credentials" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

echo "Mastodon account ID: ${ACCOUNT_ID}"

for post_file in _posts/*.en.md; do
  [ -f "$post_file" ] || continue

  # Extract frontmatter fields
  title=$(sed -n 's/^title: *"\(.*\)"/\1/p' "$post_file" | head -1)
  date=$(sed -n 's/^date: *\(.*\)/\1/p' "$post_file" | head -1)
  tags=$(sed -n 's/^tags: *\[\(.*\)\]/\1/p' "$post_file" | head -1 | tr -d ' ')

  # Build canonical URL
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
  year_month=$(echo "$date" | cut -d- -f1-2)
  canonical_url="${SITE_URL}/articles/${year_month}/${slug}.en"

  # Check if already posted (search recent statuses for the URL)
  already_posted=$(curl -s -H "Authorization: Bearer ${MASTODON_ACCESS_TOKEN}" \
    "${MASTODON_INSTANCE}/api/v1/accounts/${ACCOUNT_ID}/statuses?limit=40" | \
    python3 -c "
import sys, json
statuses = json.load(sys.stdin)
url = '${canonical_url}'
print('found' if any(url in s.get('content', '') for s in statuses) else 'not_found')
" 2>/dev/null || echo "error")

  if [ "$already_posted" = "found" ]; then
    echo "  Already on Mastodon: $title"
    continue
  fi

  echo "  Publishing to Mastodon: $title"

  # Extract first image URL from post body
  image_url=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$post_file" | \
    grep -oP '!\[.*?\]\(\K[^)]+' | head -1 || true)

  media_id=""
  if [ -n "$image_url" ]; then
    echo "  Uploading image: $image_url"
    tmpimg=$(mktemp /tmp/mastodon_img.XXXXXX)
    curl -s -o "$tmpimg" "$image_url"

    media_response=$(curl -s -H "Authorization: Bearer ${MASTODON_ACCESS_TOKEN}" \
      -F "file=@${tmpimg}" \
      -F "description=${title}" \
      "${MASTODON_INSTANCE}/api/v2/media")

    media_id=$(echo "$media_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id', ''))" 2>/dev/null || true)
    rm -f "$tmpimg"

    if [ -n "$media_id" ]; then
      echo "  Image uploaded: $media_id"
      # Wait for media processing
      sleep 2
    fi
  fi

  # Build hashtags from tags
  hashtags=$(echo "$tags" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sed 's/^/#/' | tr '\n' ' ')

  # Extract social_summary if available
  social_summary=$(sed -n 's/^social_summary: *"\(.*\)"/\1/p' "$post_file" | head -1 | sed 's/\\n/\n/g')

  # Post status
  if [ -n "$social_summary" ]; then
    status_text="${social_summary}

${canonical_url}

#DiaryOfALazyDeveloper ${hashtags}"
  else
    status_text="${title}

${canonical_url}

#DiaryOfALazyDeveloper ${hashtags}"
  fi

  if [ -n "$media_id" ]; then
    response=$(curl -s -w "\n%{http_code}" -X POST "${MASTODON_INSTANCE}/api/v1/statuses" \
      -H "Authorization: Bearer ${MASTODON_ACCESS_TOKEN}" \
      -F "status=${status_text}" \
      -F "media_ids[]=${media_id}" \
      -F "visibility=public")
  else
    response=$(curl -s -w "\n%{http_code}" -X POST "${MASTODON_INSTANCE}/api/v1/statuses" \
      -H "Authorization: Bearer ${MASTODON_ACCESS_TOKEN}" \
      -F "status=${status_text}" \
      -F "visibility=public")
  fi

  http_code=$(echo "$response" | tail -1)

  if [ "$http_code" = "200" ]; then
    echo "  Posted to Mastodon: $title"
  else
    echo "  Error posting to Mastodon (HTTP $http_code)"
  fi
done

echo "--- Mastodon publish done ---"
