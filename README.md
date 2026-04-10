---
layout: page
permalink: about.html
---
#### diary of a lazy developer

Tech posts from my projects. Each post lives in its project repo as `POST.it.md` and `POST.en.md`, and gets published here automatically by a GitHub Action.

- Theme: [leonids](https://github.com/bilardi/leonids) (Jekyll)
- Automation: [publish.yml](.github/workflows/publish.yml)
- Sources: [sources.yml](sources.yml)

## Cross-posting

EN posts are published as drafts on [dev.to](https://dev.to) with canonical URL pointing to this blog.

Setup:

1. On dev.to: Settings > Extensions > DEV Community API Keys > Generate API Key
2. On GitHub: repo Settings > Secrets and variables > Actions > New repository secret
3. Name: `DEV_TO_API_KEY`, Value: the key from step 1

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
