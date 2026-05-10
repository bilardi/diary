#!/usr/bin/env bash
set -euo pipefail

# Queue new EN articles to Buffer (LinkedIn, Twitter, Threads) as drafts.
# Uses Buffer GraphQL API. Requires BUFFER_ACCESS_TOKEN environment variable.
# Posts go to Buffer drafts; the user reviews and approves them manually.
#
# API limits: 100 requests/24h. This script uses 3 queries (org + channels + dedup)
# plus 1 mutation per channel per new post (max 3). Total: 3-6 per run.

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

# Query 1: get org ID and channels in one call
setup_json=$(gql 'query { account { organizations { id } } }')
org_id=$(echo "$setup_json" | python3 -c "
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

channels_json=$(gql "query { channels(input: { organizationId: \"${org_id}\" }) { id name service } }")

# Parse channels into service groups
eval "$(echo "$channels_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
channels = data.get('data', {}).get('channels', [])
twitter = []
long = []
all_ids = []
for ch in channels:
    cid = ch['id']
    svc = ch.get('service', '')
    print(f\"  {svc}: {ch['name']} ({cid})\", file=sys.stderr)
    all_ids.append(cid)
    if svc == 'twitter':
        twitter.append(cid)
    else:
        long.append(cid)
print(f'twitter_ids=\"{chr(10).join(twitter)}\"')
print(f'long_ids=\"{chr(10).join(long)}\"')
print(f'all_ids=\"{chr(10).join(all_ids)}\"')
")"

if [ -z "$all_ids" ]; then
  echo "No Buffer channels found, skipping"
  exit 0
fi

# Query 2: get all existing posts for dedup (single query, no channel filter)
dedup_json=$(gql "query { posts(first: 50, input: { organizationId: \"${org_id}\", filter: { status: [draft, scheduled, sent] } }) { edges { node { text channelId } } } }")

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

  echo "  Processing: $title"

  # Extract first image URL from post body
  image_url=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$post_file" | \
    grep -oP '!\[.*?\]\(\K[^)]+' | head -1 || true)

  # Extract social_summary FIRST (so we can dedup hashtags against it)
  social_summary=$(python3 -c "
for line in open('${post_file}'):
    if line.startswith('social_summary:'):
        val = line.split(':', 1)[1].strip().strip('\"')
        print(val.replace('\\\\n', '\n'))
        break
" 2>/dev/null || true)

  # Build hashtags from tags, skipping ones already present in social_summary.
  # Case-insensitive, word-boundary match: lets authors write inline hashtags with
  # proper-noun capitalization (#Iceberg, #AWS) while frontmatter stays lowercase
  hashtags=$(TAGS="$tags" SOCIAL="$social_summary" python3 -c "
import os, re
tags = [t.strip() for t in os.environ['TAGS'].split(',') if t.strip()]
text = os.environ['SOCIAL']
filtered = []
for tag in tags:
    hashtag = f'#{tag}'
    pattern = re.escape(hashtag) + r'(?![a-zA-Z0-9_])'
    if not re.search(pattern, text, re.IGNORECASE):
        filtered.append(hashtag)
print(' '.join(filtered))
" 2>/dev/null || true)

  # Add #DiaryOfALazyDeveloper only if not already in text
  diary_tag=""
  if [ -n "$social_summary" ]; then
    echo "$social_summary" | grep -qF "#DiaryOfALazyDeveloper" || diary_tag="#DiaryOfALazyDeveloper "
  else
    diary_tag="#DiaryOfALazyDeveloper "
  fi

  # Long text for LinkedIn/Threads (social_summary or fallback to title)
  if [ -n "$social_summary" ]; then
    long_text="${social_summary}

${canonical_url}

${diary_tag}${hashtags}"
  else
    long_text="${title}

${canonical_url}

${diary_tag}${hashtags}"
  fi

  # Short text for Twitter (280 char limit)
  short_text="${title}

${canonical_url}

#DiaryOfALazyDeveloper ${hashtags}"

  # Check which channels already have this post
  channels_with_post=$(echo "$dedup_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
url = '${canonical_url}'
edges = data.get('data', {}).get('posts', {}).get('edges', [])
for e in edges:
    node = e.get('node', {})
    if url in node.get('text', ''):
        print(node.get('channelId', ''))
" 2>/dev/null || true)

  # Helper: create draft post on a channel
  create_draft() {
    local text="$1"
    local channel_id="$2"
    local label="$3"

    # Build JSON payload with python3 (handles multiline text escaping)
    local payload
    payload=$(python3 -c "
import json, sys

text = sys.stdin.read().strip()
channel_id = '${channel_id}'
image_url = '${image_url}'

mutation = '''mutation CreateDraftPost(\$input: CreatePostInput!) {
  createPost(input: \$input) {
    ... on PostActionSuccess { post { id } }
    ... on MutationError { message }
  }
}'''

variables = {
    'input': {
        'text': text,
        'channelId': channel_id,
        'schedulingType': 'automatic',
        'mode': 'addToQueue',
        'saveToDraft': True
    }
}

if image_url:
    variables['input']['assets'] = {'images': [{'url': image_url}]}

print(json.dumps({'query': mutation, 'variables': variables}))
" <<< "$text")

    local response
    response=$(curl -s -X POST "${BUFFER_API}" \
      -H "Content-Type: application/json" \
      -H "${AUTH_HEADER}" \
      -d "$payload")

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

  # Queue to LinkedIn/Threads with long text (skip if already posted on that channel)
  for cid in $long_ids; do
    if echo "$channels_with_post" | grep -qF "$cid"; then
      echo "  Already in Buffer (LinkedIn/Threads): $title"
    else
      create_draft "$long_text" "$cid" "LinkedIn/Threads"
    fi
  done

  # Queue to Twitter with short text (skip if already posted on that channel)
  for cid in $twitter_ids; do
    if echo "$channels_with_post" | grep -qF "$cid"; then
      echo "  Already in Buffer (Twitter): $title"
    else
      create_draft "$short_text" "$cid" "Twitter"
    fi
  done
done

echo "--- Buffer publish done ---"
