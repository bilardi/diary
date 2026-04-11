#!/usr/bin/env bash
set -euo pipefail

# Queue new EN articles to Buffer (LinkedIn, Twitter, Threads) as drafts.
# Uses Buffer GraphQL API. Requires BUFFER_ACCESS_TOKEN environment variable.
# Posts go to Buffer drafts; the user reviews and approves them manually.

if [ -z "${BUFFER_ACCESS_TOKEN:-}" ]; then
  echo "BUFFER_ACCESS_TOKEN not set, skipping Buffer publish"
  exit 0
fi

BUFFER_API="https://api.buffer.com"
SITE_URL="https://alessandra.bilardi.net/diary"
AUTH_HEADER="Authorization: Bearer ${BUFFER_ACCESS_TOKEN}"

# Helper: run a GraphQL query
gql() {
  local query="$1"
  curl -s -X POST "${BUFFER_API}" \
    -H "Content-Type: application/json" \
    -H "${AUTH_HEADER}" \
    -d "{\"query\": $(echo "$query" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")}"
}

# Get organization ID
org_id=$(gql 'query { account { organizations { id } } }' | python3 -c "
import sys, json
data = json.load(sys.stdin)
orgs = data.get('data', {}).get('account', {}).get('organizations', [])
if orgs:
    print(orgs[0]['id'])
")

if [ -z "$org_id" ]; then
  echo "No Buffer organization found, skipping"
  exit 0
fi

echo "Buffer organization: ${org_id}"

# Get channels
channels_json=$(gql "query { channels(input: { organizationId: \"${org_id}\" }) { id name service } }")
echo "Buffer channels:"
echo "$channels_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ch in data.get('data', {}).get('channels', []):
    print(f\"  {ch['service']}: {ch['name']} ({ch['id']})\")
"

# Separate channels by service
twitter_ids=$(echo "$channels_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ch in data.get('data', {}).get('channels', []):
    if ch.get('service', '') == 'twitter':
        print(ch['id'])
")
long_ids=$(echo "$channels_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ch in data.get('data', {}).get('channels', []):
    if ch.get('service', '') != 'twitter':
        print(ch['id'])
")
all_ids=$(echo "$channels_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ch in data.get('data', {}).get('channels', []):
    print(ch['id'])
")

if [ -z "$all_ids" ]; then
  echo "No Buffer channels found, skipping"
  exit 0
fi

# Collect existing post texts for dedup (drafts + scheduled + sent)
known_urls=""
for cid in $all_ids; do
  for status in draft scheduled sent; do
    posts_json=$(gql "query { posts(input: { organizationId: \"${org_id}\", channelIds: [\"${cid}\"], status: ${status}, first: 50 }) { edges { node { text } } } }")
    urls=$(echo "$posts_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
edges = data.get('data', {}).get('posts', {}).get('edges', [])
for e in edges:
    print(e.get('node', {}).get('text', ''))
" 2>/dev/null || true)
    known_urls="${known_urls}
${urls}"
  done
done

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

  # Check if already in Buffer
  if echo "$known_urls" | grep -qF "$canonical_url"; then
    echo "  Already in Buffer: $title"
    continue
  fi

  echo "  Queuing to Buffer: $title"

  # Extract first image URL from post body
  image_url=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$post_file" | \
    grep -oP '!\[.*?\]\(\K[^)]+' | head -1 || true)

  # Build hashtags from tags
  hashtags=$(echo "$tags" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sed 's/^/#/' | tr '\n' ' ')

  # Extract social_summary if available
  social_summary=$(sed -n 's/^social_summary: *"\(.*\)"/\1/p' "$post_file" | head -1 | sed 's/\\n/\n/g')

  # Long text for LinkedIn/Threads
  if [ -n "$social_summary" ]; then
    long_text="${social_summary}

${canonical_url}

#DiaryOfALazyDeveloper ${hashtags}"
  else
    long_text="${title}

${canonical_url}

#DiaryOfALazyDeveloper ${hashtags}"
  fi

  # Short text for Twitter (280 char limit)
  short_text="${title}

${canonical_url}

#DiaryOfALazyDeveloper ${hashtags}"

  # Helper: create draft post on a channel
  create_draft() {
    local text="$1"
    local channel_id="$2"
    local label="$3"

    # Escape text for GraphQL
    local escaped_text
    escaped_text=$(python3 -c "import json; print(json.dumps($( python3 -c "import json; print(json.dumps('''$text'''))" )))" 2>/dev/null || python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" <<< "$text")
    # Remove outer quotes added by json.dumps
    escaped_text=${escaped_text:1:-1}

    local assets=""
    if [ -n "$image_url" ]; then
      assets=", assets: { images: [{ url: \\\"${image_url}\\\" }] }"
    fi

    local mutation="mutation { createPost(input: { text: \\\"${escaped_text}\\\", channelId: \\\"${channel_id}\\\", schedulingType: automatic, mode: addToQueue, saveToDraft: true${assets} }) { ... on PostActionSuccess { post { id } } ... on MutationError { message } } }"

    local response
    response=$(curl -s -X POST "${BUFFER_API}" \
      -H "Content-Type: application/json" \
      -H "${AUTH_HEADER}" \
      -d "{\"query\": \"${mutation}\"}")

    local success
    success=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
post = data.get('data', {}).get('createPost', {}).get('post')
if post:
    print('ok')
else:
    err = data.get('data', {}).get('createPost', {}).get('message', '')
    errs = data.get('errors', [])
    if errs:
        err = errs[0].get('message', '')
    print(f'error: {err}')
" 2>/dev/null || echo "error: parse failed")

    if [ "$success" = "ok" ]; then
      echo "  Queued to Buffer (${label}): $title"
    else
      echo "  Error queuing to Buffer ${label}: $success"
    fi
  }

  # Queue to LinkedIn/Threads with long text
  for cid in $long_ids; do
    create_draft "$long_text" "$cid" "LinkedIn/Threads"
  done

  # Queue to Twitter with short text
  for cid in $twitter_ids; do
    create_draft "$short_text" "$cid" "Twitter"
  done
done

echo "--- Buffer publish done ---"
