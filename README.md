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

The Action handles blog publishing and cross-posting. Scheduled publishing (every Saturday at 6:00 UTC) is currently disabled; trigger manually.

```mermaid
flowchart LR
    A[source repos] -->|collect posts| B[diary blog]
    B -->|direct| D[dev.to]
    B -->|direct| C[Mastodon]
    B -->|queue| E[Buffer]
    E -->|review & approve| F[LinkedIn]
    E -->|review & approve| G[Twitter/X]
    E -->|review & approve| H[Threads]
```

```mermaid
sequenceDiagram
    participant GH as GitHub Action
    participant Blog as diary blog
    participant DT as dev.to
    participant M as Mastodon
    participant B as Buffer
    participant U as User

    GH->>Blog: collect posts from source repos
    GH->>Blog: commit & push new posts
    GH->>DT: publish EN posts as draft
    GH->>M: publish EN posts (skip if already posted)
    GH->>B: queue EN posts (skip if already queued)
    U->>B: review, edit and approve
    B->>B: publish to LinkedIn, Twitter, Threads
```

To trigger it manually:

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

1. On mastodon.social: Settings > Development > New Application > select read, write and profile
2. Copy the token: `MASTODON_ACCESS_TOKEN`

### Buffer (LinkedIn, Twitter, Threads queue with review)

1. Create a free account on [buffer.com](https://buffer.com) and connect LinkedIn, Twitter/X and Threads
2. On buffer.com: My Organization (bottom left) > Apps & Integrations > API (beta) > + New Key
3. Secret: `BUFFER_ACCESS_TOKEN`

## Post frontmatter

Each post in a source repo has this frontmatter:

```yaml
---
title: "Docker on EC2 with Terraform"
date: 2026-04-10
categories: [devops]
tags: [terraform, docker, aws, ec2]
repo: bilardi/aws-docker-host
social_summary: "I wrote my first article in the #DiaryOfALazyDeveloper series 🚀\n\n..."
---
```

| Field | Required | Used by |
|-------|----------|---------|
| title | yes | blog, all social |
| date | yes | blog URL |
| categories | yes | blog |
| tags | yes | blog, social hashtags |
| repo | yes | collect-posts.sh |
| social_summary | no | EN posts only. Used by Mastodon, Buffer (LinkedIn/Threads). If missing, title is used. Twitter always uses title (280 char limit). Must be under 500 characters including link and hashtags (Mastodon/Threads limit). |

`#DiaryOfALazyDeveloper` is added automatically on all social posts.

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
