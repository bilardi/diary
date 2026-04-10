#!/usr/bin/env bash
set -euo pipefail

# Post new EN articles to Twitter/X with image.
# Requires TWITTER_API_KEY, TWITTER_API_SECRET, TWITTER_ACCESS_TOKEN, TWITTER_ACCESS_SECRET.

if [ -z "${TWITTER_API_KEY:-}" ] || [ -z "${TWITTER_API_SECRET:-}" ] || \
   [ -z "${TWITTER_ACCESS_TOKEN:-}" ] || [ -z "${TWITTER_ACCESS_SECRET:-}" ]; then
  echo "Twitter credentials not set, skipping Twitter publish"
  exit 0
fi

SITE_URL="https://alessandra.bilardi.net/diary"

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

  # Check if already posted (search recent tweets for the URL)
  already_posted=$(python3 -c "
import json, sys, urllib.request, urllib.error, hmac, hashlib, base64, time, urllib.parse, os

api_key = os.environ['TWITTER_API_KEY']
api_secret = os.environ['TWITTER_API_SECRET']
access_token = os.environ['TWITTER_ACCESS_TOKEN']
access_secret = os.environ['TWITTER_ACCESS_SECRET']

# Get user ID
def oauth_header(method, url, params=None):
    if params is None:
        params = {}
    oauth_params = {
        'oauth_consumer_key': api_key,
        'oauth_nonce': str(int(time.time() * 1000)),
        'oauth_signature_method': 'HMAC-SHA1',
        'oauth_timestamp': str(int(time.time())),
        'oauth_token': access_token,
        'oauth_version': '1.0'
    }
    all_params = {**oauth_params, **params}
    param_string = '&'.join(f'{urllib.parse.quote(k, safe=\"\")}={urllib.parse.quote(str(v), safe=\"\")}' for k, v in sorted(all_params.items()))
    base_string = f'{method}&{urllib.parse.quote(url, safe=\"\")}&{urllib.parse.quote(param_string, safe=\"\")}'
    signing_key = f'{urllib.parse.quote(api_secret, safe=\"\")}&{urllib.parse.quote(access_secret, safe=\"\")}'
    signature = base64.b64encode(hmac.new(signing_key.encode(), base_string.encode(), hashlib.sha1).digest()).decode()
    oauth_params['oauth_signature'] = signature
    auth_header = 'OAuth ' + ', '.join(f'{urllib.parse.quote(k, safe=\"\")}=\"{urllib.parse.quote(v, safe=\"\")}\"' for k, v in sorted(oauth_params.items()))
    return auth_header

url = 'https://api.twitter.com/2/users/me'
req = urllib.request.Request(url, headers={'Authorization': oauth_header('GET', url)})
try:
    resp = urllib.request.urlopen(req)
    user_id = json.loads(resp.read())['data']['id']
except:
    print('error')
    sys.exit(0)

# Check recent tweets
url = f'https://api.twitter.com/2/users/{user_id}/tweets'
params = {'max_results': '20'}
query = urllib.parse.urlencode(params)
full_url = f'{url}?{query}'
req = urllib.request.Request(full_url, headers={'Authorization': oauth_header('GET', url, params)})
try:
    resp = urllib.request.urlopen(req)
    tweets = json.loads(resp.read()).get('data', [])
    canonical = '${canonical_url}'
    if any(canonical in t.get('text', '') for t in tweets):
        print('found')
    else:
        print('not_found')
except:
    print('not_found')
" 2>/dev/null || echo "not_found")

  if [ "$already_posted" = "found" ]; then
    echo "  Already on Twitter: $title"
    continue
  fi

  echo "  Publishing to Twitter: $title"

  # Extract first image URL from post body
  image_url=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$post_file" | \
    grep -oP '!\[.*?\]\(\K[^)]+' | head -1 || true)

  # Build hashtags from tags
  hashtags=$(echo "$tags" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sed 's/^/#/' | tr '\n' ' ')

  tweet_text="${title}

${canonical_url}

${hashtags}"

  # Post tweet with optional image using Python (OAuth 1.0a required)
  python3 -c "
import json, os, hmac, hashlib, base64, time, urllib.parse, urllib.request, sys

api_key = os.environ['TWITTER_API_KEY']
api_secret = os.environ['TWITTER_API_SECRET']
access_token = os.environ['TWITTER_ACCESS_TOKEN']
access_secret = os.environ['TWITTER_ACCESS_SECRET']

def oauth_header(method, url, params=None, body_params=None):
    if params is None:
        params = {}
    if body_params is None:
        body_params = {}
    oauth_params = {
        'oauth_consumer_key': api_key,
        'oauth_nonce': str(int(time.time() * 1000)),
        'oauth_signature_method': 'HMAC-SHA1',
        'oauth_timestamp': str(int(time.time())),
        'oauth_token': access_token,
        'oauth_version': '1.0'
    }
    all_params = {**oauth_params, **params, **body_params}
    param_string = '&'.join(f'{urllib.parse.quote(k, safe=\"\")}={urllib.parse.quote(str(v), safe=\"\")}' for k, v in sorted(all_params.items()))
    base_string = f'{method}&{urllib.parse.quote(url, safe=\"\")}&{urllib.parse.quote(param_string, safe=\"\")}'
    signing_key = f'{urllib.parse.quote(api_secret, safe=\"\")}&{urllib.parse.quote(access_secret, safe=\"\")}'
    signature = base64.b64encode(hmac.new(signing_key.encode(), base_string.encode(), hashlib.sha1).digest()).decode()
    oauth_params['oauth_signature'] = signature
    return 'OAuth ' + ', '.join(f'{urllib.parse.quote(k, safe=\"\")}=\"{urllib.parse.quote(v, safe=\"\")}\"' for k, v in sorted(oauth_params.items()))

media_id = None
image_url = '${image_url}'

# Upload image if available
if image_url:
    import tempfile
    tmpfile = tempfile.mktemp()
    urllib.request.urlretrieve(image_url, tmpfile)

    with open(tmpfile, 'rb') as f:
        image_data = base64.b64encode(f.read()).decode()
    os.unlink(tmpfile)

    upload_url = 'https://upload.twitter.com/1.1/media/upload.json'
    body_params = {'media_data': image_data}
    body = urllib.parse.urlencode(body_params).encode()
    req = urllib.request.Request(upload_url, data=body, headers={
        'Authorization': oauth_header('POST', upload_url, body_params=body_params),
        'Content-Type': 'application/x-www-form-urlencoded'
    })
    try:
        resp = urllib.request.urlopen(req)
        media_id = json.loads(resp.read())['media_id_string']
        print(f'  Image uploaded: {media_id}', file=sys.stderr)
    except Exception as e:
        print(f'  Image upload failed: {e}', file=sys.stderr)

# Post tweet
tweet_url = 'https://api.twitter.com/2/tweets'
payload = {'text': '''${tweet_text}'''}
if media_id:
    payload['media'] = {'media_ids': [media_id]}

data = json.dumps(payload).encode()
req = urllib.request.Request(tweet_url, data=data, headers={
    'Authorization': oauth_header('POST', tweet_url),
    'Content-Type': 'application/json'
})
try:
    resp = urllib.request.urlopen(req)
    print(f'  Posted to Twitter', file=sys.stderr)
except urllib.error.HTTPError as e:
    print(f'  Error posting to Twitter (HTTP {e.code}): {e.read().decode()}', file=sys.stderr)
"

done

echo "--- Twitter publish done ---"
