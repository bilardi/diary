---
layout: page
permalink: about.html
---
#### Diary of a lazy developer

Tech posts from my projects. Each post lives in its project repo as `POST.it.md` and `POST.en.md`, and gets published here automatically by a GitHub Action.

- Theme: [leonids](https://github.com/bilardi/leonids) (Jekyll)
- Automation: [publish.yml](https://github.com/bilardi/diary/blob/master/.github/workflows/publish.yml)
- Sources: [sources.yml](https://github.com/bilardi/diary/blob/master/sources.yml)

## Publishing

The Action runs automatically every Saturday at 6:00 UTC. To trigger it manually:

1. Go to Actions > Publish posts
2. Click "Run workflow" > "Run workflow"

Or from CLI:

```sh
gh workflow run publish.yml
```

## Cross-posting

EN posts are cross-posted automatically. All secrets go in repo Settings > Secrets and variables > Actions > New repository secret.

### dev.to (draft)

1. On dev.to: Settings > Extensions > DEV Community API Keys > Generate API Key
2. Secret: `DEV_TO_API_KEY`

### Mastodon (public post with image)

1. On mastodon.social: Settings > Development > New Application > generate access token
2. Secret: `MASTODON_ACCESS_TOKEN`

### Twitter/X (public tweet with image)

1. On developer.twitter.com: create App > Keys and tokens
2. Secrets: `TWITTER_API_KEY`, `TWITTER_API_SECRET`, `TWITTER_ACCESS_TOKEN`, `TWITTER_ACCESS_SECRET`

## Development

```sh
docker compose up
```

If something is not updated,

```sh
rm -rf _site .jekyll-cache .jekyll-metadata
touch .jekyll-metadata; chmod 777 .jekyll-metadata
touch Gemfile.lock; chmod 777 Gemfile.lock
docker compose up
```

Not commit (there are also in the .gitignore file)

* _site
* .jekyll-cache
* .jekyll-metadata
* Gemfile.lock
