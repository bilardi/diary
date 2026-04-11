#!/usr/bin/env bash
set -euo pipefail

# Queue new EN articles to Buffer (LinkedIn, Twitter, Threads) for review.
# Requires BUFFER_ACCESS_TOKEN environment variable.
# Posts go to Buffer queue; the user reviews and approves them manually.

if [ -z "${BUFFER_ACCESS_TOKEN:-}" ]; then
  echo "BUFFER_ACCESS_TOKEN not set, skipping Buffer publish"
  exit 0
fi

BUFFER_API="https://api.bufferapp.com/1"
SITE_URL="https://alessandra.bilardi.net/diary"

# Get all profile IDs
profiles=$(curl -s "${BUFFER_API}/profiles.json?access_token=${BUFFER_ACCESS_TOKEN}")
profile_ids=$(echo "$profiles" | python3 -c "
import sys, json
profiles = json.load(sys.stdin)
for p in profiles:
    print(p['id'], p.get('service', ''), p.get('service_username', ''))
")

echo "Buffer profiles:"
echo "$profile_ids"

# Separate profile IDs by service: twitter (short text) vs others (long text)
twitter_ids=$(echo "$profiles" | python3 -c "
import sys, json
profiles = json.load(sys.stdin)
for p in profiles:
    if p.get('service', '') == 'twitter':
        print(p['id'])
")
long_ids=$(echo "$profiles" | python3 -c "
import sys, json
profiles = json.load(sys.stdin)
for p in profiles:
    if p.get('service', '') != 'twitter':
        print(p['id'])
")
all_ids=$(echo "$profiles" | python3 -c "
import sys, json
profiles = json.load(sys.stdin)
for p in profiles:
    print(p['id'])
")

if [ -z "$all_ids" ]; then
  echo "No Buffer profiles found, skipping"
  exit 0
fi

# Collect pending and sent URLs across all profiles for dedup
known_urls=""
for pid in $all_ids; do
  pending=$(curl -s "${BUFFER_API}/profiles/${pid}/updates/pending.json?access_token=${BUFFER_ACCESS_TOKEN}&count=100")
  sent=$(curl -s "${BUFFER_API}/profiles/${pid}/updates/sent.json?access_token=${BUFFER_ACCESS_TOKEN}&count=100")
  urls=$(echo "$pending" "$sent" | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        data = json.loads(line)
        updates = data.get('updates', [])
        for u in updates:
            print(u.get('text', ''))
    except:
        pass
")
  known_urls="${known_urls}
${urls}"
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

  # Check if already in queue or sent
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

  # Long text for LinkedIn/Threads (social_summary or fallback to title)
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

  # Helper function to queue a post
  queue_post() {
    local text="$1"
    local pids="$2"
    local label="$3"

    [ -z "$pids" ] && return

    local profile_params=""
    for pid in $pids; do
      profile_params="${profile_params} -d profile_ids[]=${pid}"
    done

    if [ -n "$image_url" ]; then
      response=$(curl -s -w "\n%{http_code}" -X POST "${BUFFER_API}/updates/create.json" \
        -d "access_token=${BUFFER_ACCESS_TOKEN}" \
        ${profile_params} \
        --data-urlencode "text=${text}" \
        -d "media[link]=${canonical_url}" \
        -d "media[photo]=${image_url}" \
        --data-urlencode "media[description]=${title}")
    else
      response=$(curl -s -w "\n%{http_code}" -X POST "${BUFFER_API}/updates/create.json" \
        -d "access_token=${BUFFER_ACCESS_TOKEN}" \
        ${profile_params} \
        --data-urlencode "text=${text}" \
        -d "media[link]=${canonical_url}")
    fi

    http_code=$(echo "$response" | tail -1)

    if [ "$http_code" = "200" ]; then
      echo "  Queued to Buffer (${label}): $title"
    else
      echo "  Error queuing to Buffer ${label} (HTTP $http_code)"
      echo "$response" | head -5
    fi
  }

  # Queue to LinkedIn/Threads with long text
  queue_post "$long_text" "$long_ids" "LinkedIn/Threads"

  # Queue to Twitter with short text
  queue_post "$short_text" "$twitter_ids" "Twitter"
done

echo "--- Buffer publish done ---"
