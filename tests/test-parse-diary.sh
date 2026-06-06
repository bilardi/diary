#!/usr/bin/env bash
set -euo pipefail

# Integration tests for parse-diary.py, run against the oldest real post
# kept as a stable fixture in tests/fixtures/_posts/.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0

run_test() {
  local name="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== parse-diary integration tests ==="

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cp "$FIXTURES/social.yml" "$TMPDIR/"
cp -r "$FIXTURES/_posts" "$TMPDIR/"

cd "$TMPDIR"
bash "$REPO_ROOT/scripts/parse-diary.sh"

run_test "posts.json exists" test -f posts.json

run_test "Exactly one post parsed" python3 -c "
import json
posts = json.load(open('posts.json'))
assert len(posts) == 1, f'Expected 1 post, got {len(posts)}'
"

run_test "Canonical url built from site_url + year-month + slug + .en" python3 -c "
import json
p = json.load(open('posts.json'))[0]
expected = 'https://alessandra.bilardi.net/diary/articles/2026-04/docker-on-ec2-with-terraform.en'
assert p['url'] == expected, f'url={p[\"url\"]}'
"

run_test "medium_text equals long_text" python3 -c "
import json
p = json.load(open('posts.json'))[0]
assert p['medium_text'] == p['long_text'], 'medium_text differs from long_text'
"

run_test "long_text uses social_summary, url and tag hashtags" python3 -c "
import json
p = json.load(open('posts.json'))[0]
t = p['long_text']
assert t.startswith('I wrote my first article in the #DiaryOfALazyDeveloper series'), 'long_text does not start with social_summary'
assert p['url'] in t, 'url missing from long_text'
assert t.rstrip().endswith('#terraform #docker #aws #ec2'), f'tag hashtags missing/wrong at end: {t[-80:]!r}'
"

run_test "Fixed hashtag not doubled in long_text (already in social_summary)" python3 -c "
import json
p = json.load(open('posts.json'))[0]
count = p['long_text'].count('#DiaryOfALazyDeveloper')
assert count == 1, f'#DiaryOfALazyDeveloper appears {count} times in long_text, expected 1'
"

run_test "short_text uses title, url and fixed hashtag + tags" python3 -c "
import json
p = json.load(open('posts.json'))[0]
t = p['short_text']
assert t.startswith('Docker on EC2 with Terraform'), 'short_text does not start with title'
assert p['url'] in t, 'url missing from short_text'
assert '#DiaryOfALazyDeveloper #terraform #docker #aws #ec2' in t, f'tail wrong: {t[-100:]!r}'
"

run_test "Fixed hashtag appears once in short_text" python3 -c "
import json
p = json.load(open('posts.json'))[0]
count = p['short_text'].count('#DiaryOfALazyDeveloper')
assert count == 1, f'#DiaryOfALazyDeveloper appears {count} times in short_text, expected 1'
"

run_test "First image extracted into images list" python3 -c "
import json
p = json.load(open('posts.json'))[0]
expected = 'https://raw.githubusercontent.com/bilardi/aws-docker-host/master/images/architecture.drawio.png'
assert p['images'] == [expected], f'images={p[\"images\"]}'
"

run_test "tags preserved as list" python3 -c "
import json
p = json.load(open('posts.json'))[0]
assert p['tags'] == ['terraform', 'docker', 'aws', 'ec2'], f'tags={p[\"tags\"]}'
"

run_test "article_body is the post body without frontmatter" python3 -c "
import json
p = json.load(open('posts.json'))[0]
b = p['article_body']
assert '## Why this project' in b, 'article_body missing body content'
assert 'layout: post' not in b, 'article_body leaked frontmatter'
assert 'architecture.drawio.png' in b, 'article_body missing image markdown'
"

run_test "title preserved for dev.to" python3 -c "
import json
p = json.load(open('posts.json'))[0]
assert p['title'] == 'Docker on EC2 with Terraform', f'title={p[\"title\"]}'
"

run_test "medium/long/short are non-empty (publish scripts require them)" python3 -c "
import json
p = json.load(open('posts.json'))[0]
for field in ('long_text', 'medium_text', 'short_text'):
    assert p[field].strip(), f'{field} is empty'
"

cd - > /dev/null

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
