#!/usr/bin/env python3
"""Diary parser: reads social.yml and _posts/*.en.md, outputs posts.json.

Produces the same intermediate format consumed by the github-actions-publish
publish scripts (mastodon/buffer/devto), so the diary can reuse them instead
of keeping its own copies. The social text construction (social_summary, fixed
hashtag, tag hashtags with case-insensitive dedup) replicates the logic the
diary publish scripts used to do inline.
"""

import json
import re
import sys

import yaml


def parse_frontmatter(content, filepath):
    """Extract frontmatter dict and body string from a Jekyll post."""
    if not content.startswith("---"):
        raise ValueError(f"{filepath}: missing frontmatter (no opening ---)")
    parts = content.split("---", 2)
    if len(parts) < 3:
        raise ValueError(f"{filepath}: malformed frontmatter (no closing ---)")
    fm = yaml.safe_load(parts[1])
    if not isinstance(fm, dict):
        raise ValueError(f"{filepath}: frontmatter is not a YAML mapping")
    return fm, parts[2].lstrip("\n")


def slugify(title):
    """Reproduce the slug collect-posts.sh builds from the title."""
    slug = title.lower()
    slug = re.sub(r"[^a-z0-9]", "-", slug)
    slug = re.sub(r"-+", "-", slug)
    return slug.strip("-")


def first_image(body):
    """Return the first markdown image URL in the body, or '' if none."""
    match = re.search(r"!\[[^\]]*\]\(([^)]+)\)", body)
    return match.group(1) if match else ""


def hashtag_present(hashtag, text):
    """Case-insensitive, word-boundary check for a hashtag in text."""
    pattern = re.escape(hashtag) + r"(?![a-zA-Z0-9_])"
    return re.search(pattern, text, re.IGNORECASE) is not None


def tag_hashtags(tags, text):
    """Build '#tag' hashtags from tags, skipping any already present in text."""
    filtered = []
    for tag in tags:
        hashtag = f"#{tag}"
        if not hashtag_present(hashtag, text):
            filtered.append(hashtag)
    return " ".join(filtered)


def join_tail(*parts):
    """Join non-empty hashtag groups with a single space."""
    return " ".join(p for p in parts if p)


def parse_file(filepath, fixed_hashtag, site_url):
    """Parse a single _posts/*.en.md file into a post dict."""
    with open(filepath) as f:
        content = f.read()

    fm, body = parse_frontmatter(content, filepath)

    title = str(fm.get("title", ""))
    post_date = str(fm["date"])
    tags = [str(t) for t in (fm.get("tags") or [])]
    social_summary = fm.get("social_summary")
    social_summary = str(social_summary) if social_summary else ""

    slug = slugify(title)
    year_month = post_date[:7]
    url = f"{site_url}/articles/{year_month}/{slug}.en"

    # Long/medium share the same text: social_summary (or title) + url + hashtags.
    # The fixed hashtag is added only if not already in the social text.
    social_text = social_summary if social_summary else title
    tags_hashtags = tag_hashtags(tags, social_text)
    fixed_long = "" if hashtag_present(fixed_hashtag, social_text) else fixed_hashtag
    long_text = f"{social_text}\n\n{url}\n\n{join_tail(fixed_long, tags_hashtags)}"

    # Short text (Twitter): title + url + fixed hashtag + tag hashtags.
    short_text = f"{title}\n\n{url}\n\n{join_tail(fixed_hashtag, tags_hashtags)}"

    image = first_image(body)

    return {
        "title": title,
        "date": post_date,
        "long_text": long_text,
        "medium_text": long_text,
        "short_text": short_text,
        "article_body": body.strip(),
        "url": url,
        "images": [image] if image else [],
        "tags": tags,
    }


def main():
    with open("social.yml") as f:
        config = yaml.safe_load(f)

    fixed_hashtag = config["hashtag"]
    content_path = config.get("content_path", "_posts")
    site_url = config["site_url"].rstrip("/")

    import glob
    import os

    posts = []
    errors = []
    for filepath in sorted(glob.glob(os.path.join(content_path, "*.en.md"))):
        try:
            posts.append(parse_file(filepath, fixed_hashtag, site_url))
        except (ValueError, KeyError) as e:
            errors.append(f"{filepath}: {e}")

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        sys.exit(1)

    with open("posts.json", "w") as f:
        json.dump(posts, f, indent=2, ensure_ascii=False)

    print(f"Parsed {len(posts)} post(s) into posts.json")


if __name__ == "__main__":
    main()
