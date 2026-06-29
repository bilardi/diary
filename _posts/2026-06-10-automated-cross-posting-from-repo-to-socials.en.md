---
layout: post
title: "Automated cross-posting: from repo to socials"
date: 2026-06-10
categories: [devops]
tags: [GithubActions, CrossPosting, social, api]
repo: bilardi/github-actions-publish
lang: en
pair: 1
social_summary: "I can't clone myself, so let's automate 🚀\n\nHow do you automate #CrossPosting when every #social has its own rules ?\n\n🔮 Spoiler: the #API is the easy part. The real work is everything the docs don't tell you 🧩\n\nIn the article I describe every choice and why, with #GithubActions and workflows playing hide and seek 😄"
---

![cross-posting](https://raw.githubusercontent.com/bilardi/github-actions-publish/master/images/workflow.post.png)

## Write once, publish everywhere

It all started with the blog [bilardi/diary](https://github.com/bilardi/diary), which collects the technical posts from my projects' repos and publishes them by auto-committing. But publishing them on the blog is only half the job: part of the content also goes to Mastodon, LinkedIn, Threads, Twitter, and the whole article to dev.to. Doing it by hand, every time, would be a nightmare.

As a lazy developer, I wanted something that ran the whole thing on its own: I write the post in the repo, and a GitHub Actions workflow does the rest.

The problem is that every social platform plays by its own rules, and almost none is as free as it looks. On top of that, the blog isn't the only repo that should publish to social media, because I organize events and speak at conferences .. and copying the scripts into every repo doesn't scale.

## Centralize just enough

### Four socials, three slots

Mastodon is the simplest: it has an open API, like [dev.to](https://dev.to), a token that never expires, and one `curl` publishes the post. Twitter is the opposite: the Free plan that gave 1,500 tweets a month is gone, and to generate write tokens you need the paid plans, from $200 a month. LinkedIn and Threads don't have the cost problem, but they're more involved to handle. Instagram's automation, instead, asks for too many requirements before you can even tell whether it's worth the trouble.

Is there really no single system to handle them all ? Turns out there are plenty, but few have draft management, which matters when publishing to social media is irreversible. From the comparison [Buffer](https://buffer.com) stood out, offering 3 channels for free. And me with 4 to cover, what do I do ?

The answer is not to put everything on Buffer. Mastodon and dev.to have their own direct APIs, so I rule them out from the start. The four I'd want to handle with Buffer are LinkedIn, Twitter, Threads, and Instagram. Instagram, though, can't be automated at a reasonable cost: it stays manual, and the 3 free slots are enough for the other three.

| Social | Buffer | Reason |
|--------|--------|--------|
| dev.to | no | direct API, yearly token |
| Instagram | no | Meta demands a business account, a Facebook page, and an app review |
| LinkedIn | yes | OAuth API, 60-day token and refresh only for approved partners |
| Mastodon | no | trivial direct API, token that never expires |
| Threads | yes | OAuth API, 60-day token with refresh |
| Twitter | yes | no free write API |

So with Buffer I don't have to log into every account, and the drafts are a lifesaver because
- one more check before publishing never hurts
- on Twitter it's almost mandatory, because a published tweet can't be edited anymore

### Interchangeable blocks

What I had set up for the blog was too custom to also work for event or talk posts. What I needed was something that worked in interchangeable blocks, depending on the kind of post to make.

That's why the scripts were centralized into a single repo, [bilardi/github-actions-publish](https://github.com/bilardi/github-actions-publish), which exposes a workflow reusable by the other repos, like [bilardi/bilardi-posts-manager](https://github.com/bilardi/bilardi-posts-manager).

But how do you handle different formats with the same scripts ?

The piece that holds it all together is an intermediate format: each repo gets to its list of posts in its own way. Right now there are two parsers, one per source type:
- the default parser reads the event repos, with files split into `# long`/`# medium`/`# short`/`# article` sections
- the blog has its own parser: it reads files formatted differently, but produces the same sections

The parsers produce the same JSON, and the github-actions-publish scripts consume it without knowing where it comes from. That way the blog reuses the same scripts while having a parser all its own.

And as a good developer, I couldn't skip the bare minimum:
- the tests are end-to-end on the parsers, in bash: it's not Python, so no `pytest`, and a framework like [sharness](https://github.com/bilardi/see-git-steps/blob/master/test/sharness.test/functional.sh) or [bashunit](https://github.com/bilardi/see-git-steps/blob/master/test/bashunit.test/functional.sh) was too much for the scope
- the dry-run is a smoke test of the whole run: it hits the real APIs but doesn't publish, handy especially for Mastodon, which is direct and irreversible
- the rest is essential: lint with `ruff` on demand, release with bash and `git-cliff`

## What the docs don't tell you

### Buffer and its surprises

After testing feasibility with `curl`, I implemented it in Python with `urllib`, and access to Buffer wasn't working: why ?
The endpoint sits behind Cloudflare, which blocks Python's `urllib` requests with a 1010 error: `curl` gets through, `urllib` doesn't. Without too much fuss, I built the JSON payload with `python3` and made the call with `curl`.

The Free plan allows 100 requests every 24 hours, on a rolling window. A normal run uses 5-6, but a debug session of 10 runs is already at 50-60: in development you burn through them fast.
And no, I didn't mock its responses: I just kept the runs to a minimum. A mock of the API would be the right way to test publishing without burning requests, but it would drift apart at every change in Buffer's API signature, and that's already happened. I don't read Buffer's changelog over my morning coffee: a mock would stay green while the real publishing breaks, without me noticing. Better to work against the real API.

### Dedup at multiple levels

A first thought was not to publish the same post twice on Mastodon: everything else goes through a draft, so it can be deleted, but not Mastodon, it's direct.
So running the workflow twice shouldn't create duplicates on any channel. I implemented per-channel dedup, not global: if LinkedIn already has the post but Threads doesn't, it creates only Threads.

And how do you tell a post has already been made ?

I based it on comparing the URL published in the post: if a post with that URL already exists, it means it's not to be published. This can actually become a limitation, because it means I can't make more than one post for the same event with the same URL, but I've made my peace with it: consistency first.

With this system, though, LinkedIn kept creating a draft of the post I had just published, and it was a headache to find the cause, but above all a reasonably clean solution.

On sending, LinkedIn rewrites the link into an `lnkd.in`: on already-published posts the canonical URL disappears from the text, dedup doesn't find it and re-queues the same post every run .. unless I leave a draft. I tried passing the URL as a structured attachment, which survives the rewrite: but with the attachment Buffer drops the image and shows only the link card, and the image is non-negotiable. So for LinkedIn channels only, dedup compares the first lines of the post body, which stay intact, instead of the URL. It's another compromise I can live with: if you change those lines on an already-sent post, it gets re-queued, and so be it.

But dedup doesn't stop at posts: there's also the one for the closing hashtags. If they're already in the text, why rewrite them at the end ? It saves space, especially on Mastodon, Threads, and Twitter.
The tags saved for the post's closing are lowercase, but inline they're sometimes written uppercase: I chose to compare on the whole word, case-insensitive, otherwise both #AWS and #aws would come out.

### The minimal solution always wins

To clone a child repo, at first I used a simple bash script with the files' code written inside, in a heredoc. A YAML file and a `LICENSE` were enough to handle, then the `README.md` came along, and that's where the trouble started: in the same spot three levels of escaping coexisted, the markdown backticks, the literal variables, and GitHub Actions' `${{ .. }}` expressions. Every change risked breaking the generation.

The choice was to drop the heredocs: the contents became template files with placeholders, replaced with `sed`. No more nested escaping: content and logic live in different places, each readable on its own.

### The workflow that doesn't show up

On the first run of the child repo, something was off: I had pushed everything, but I couldn't start the workflow, why ?

Well, it actually happened to me more than once.

At first I thought it depended on the repo being private: the workflow didn't show up in the Actions tab, and I blamed that. I tried various things, from making it public to new pushes.

But with another repo it happened again, even though I'd made it public from the start and done the first push with everything needed: the workflow still didn't show up in the Actions tab, so it wasn't the visibility.

The real cause is in how GitHub Actions works: it re-validates workflows only when you touch them with a push. And indeed, a small change was all it took: a newline at the end of the file, a push, and it showed up.

### Where I keep the images

This could open a huge debate, but let's stick to the facts.

We're talking about articles, event and talk posts, .. if you get organized, there could be quite a few: versioning the images in the repo isn't an option, and neither is putting them on your own AWS account, especially when several people are involved.

Each event group has its own Google Drive, and I keep the images there. The problem is that the sharing link (`drive.google.com/file/d/../view`) isn't a direct URL to the image, and Buffer and Mastodon want a direct URL. I tried three URL forms:

| Form | Mode | Mastodon | Buffer | Why |
|------|------|----------|--------|-----|
| `uc?export=view` | redirect (303) | yes | no | Buffer doesn't follow the 303 |
| `drive.usercontent.google.com/download` | direct | yes | no | blocked by the CORS restriction |
| `thumbnail?id=..&sz=w1920` | redirect (302) | yes | yes | no restriction |

The parser converts the sharing link into this last format automatically: in the config I paste the link as I copy it from Drive, and it takes care of the rest.

## What could be improved ?

In the end I found myself with a rule of thumb: outside Buffer goes whatever has a direct, low-maintenance API, and the 3 free slots stay for those that don't. Today the only one outside is Mastodon, with its token that never expires.

Threads is the natural candidate to move out: [Meta has an API](https://developers.facebook.com/docs/threads) that publishes via code, and moving it would free up a Buffer slot. Only it's not free like Mastodon: the tokens expire after 60 days and have to be refreshed with a dedicated endpoint, otherwise you're back to doing the OAuth by hand. It would take a scheduled step that refreshes the token and saves it again. If one day I need a Buffer slot for another platform, that'll be the time to do it.

Instagram is handled by hand for now, but the road is longer: you need a business account, a Facebook page, and a Meta app review. It all depends on the status quo: it'll become necessary the moment the weight of posting by hand outgrows that of opening a Facebook account with all the trimmings.

And finally, video. Today it publishes images only: there's no video on any channel. For an event post a short video would sometimes do more than a photo, but each platform has different constraints on format, length, and size, and Buffer treats them differently from images. For now, video stays out.
