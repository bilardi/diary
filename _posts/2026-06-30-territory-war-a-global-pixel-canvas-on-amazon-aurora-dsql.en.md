---
layout: post
title: "Territory War: a global pixel canvas on Amazon Aurora DSQL"
date: 2026-06-30
categories: [database]
tags: [terraform, aws, aurora, h0hackathon]
repo: bilardi/territory-war
lang: en
pair: 1
social_summary: "🎨 Credits and prizes ? The perfect mix to spark creativity !\n\n#H0Hackathon ran a competition to build on Vercel with an #AWS #database 🏗️\n\n🔮 Spoiler: fingers crossed the credits arrive, because keeping a million-scale setup online isn't exactly cheap 💵\n\nIn the article I describe the whole story, wins and constraints alike 😄"
---

![Architecture](https://raw.githubusercontent.com/bilardi/territory-war/master/docs/images/architecture.multi.drawio.png)

## A canvas to test what a database can do

These days I took part in a competition, the [H0 hackathon](https://h01.devpost.com/), which asked for a frontend on [Vercel](https://vercel.com) and an AWS database. The database was the part that caught my interest: I had the chance to play with a database and put it under stress for free ? I couldn't let that chance slip by !

And if we're going to play, let's play for real: I chose to build [Territory War](https://github.com/bilardi/territory-war) because it's a shared pixel canvas, [r/place](https://en.wikipedia.org/wiki/R/place) style, where several teams paint in real time, one pixel per person at a time. The real problem isn't drawing: it's keeping one single coherent canvas when many write to the same cells, maybe from different regions, without two writes producing an ambiguous result and without losing one silently ..

And here's the question that glued me to the competition: pure placement is "last writer wins", and even an eventually consistent database does that well, but what about going global ? Strong consistency becomes the requirement when you want one canvas identical for everyone and in every region: a write committed on one side must be immediately true on the other, and two writes to the same cell can't leave two different truths.

## A database for every occasion

Which database depends on what you need: here are the three allowed ones side by side.

| database | consistency | multi-region | model | when it fits |
| --- | --- | --- | --- | --- |
| [Amazon DynamoDB](https://aws.amazon.com/dynamodb/) | eventual with global tables (strong only single-region) | active-active but eventual | key-value | huge key-value scale, when eventual is fine |
| [Amazon Aurora PostgreSQL](https://aws.amazon.com/rds/aurora/) | strong, but single writer | asynchronous replica (Global Database), not active-active | relational SQL | relational workloads in one region, distributed reads |
| [Amazon Aurora DSQL](https://aws.amazon.com/rds/aurora/dsql/) | strong | active-active | relational SQL, Postgres-compatible | relational, global and coherent data, with multiple writable regions |

Amazon DynamoDB, across regions, diverges for an instant and resolves conflicts with "last writer wins" silently: different truths in different places. Amazon Aurora DSQL doesn't, it's active-active with strong consistency: a committed write is immediately true everywhere, and two writes to the same cell conflict instead of overwriting each other quietly. This game needs relational, global and coherent together: so DSQL, and that's why I went for the million-scale track.

And what if global weren't needed ? It depends on the data model. For a game like this, relational and transactional, Amazon Aurora PostgreSQL is better; Amazon DynamoDB fits when the model is key-value and scale matters more than the relations. DSQL makes sense when you need relational, global and strong consistency together: drop one of the three and one of the other two will do.

## The rules of the game

The only rule "visible" to players is the cooldown: one pixel every N seconds each, the r/place rhythm. The cooldown blocks the double click, but behind the scenes, here's the real question: how do I stop requests from the same player arriving at the same instant from two tabs open with the same identity ?

Under the hood the cooldown relies on a per-player timestamp, the instant of the last placement stored in the database: on every placement, in the same transaction, the system reads that timestamp and, if N seconds have passed, updates it and writes the pixel.
Keeping the check and the write in the same transaction is the "hidden" rule of the game: with REPEATABLE READ every transaction sees a coherent snapshot of the data, and two touching the same row conflict; the one that fails, on retry, finds the cooldown already updated.
And the same principle holds for a cell contested by different players: it can't end up with two owners, just one truth.
So correctness lives in the DSQL transaction: on the browser side [AWS AppSync Events](https://aws.amazon.com/appsync/) updates the canvas in real time, and a lost event costs at most a refresh, never a pixel.

The identity, though, is just an id in the browser: anyone who wants can open several windows and play as several players, because the limit is per identity, not per person, but for a game with no prizes that's fine. And the day this gets serious, authentication will come in !

## Getting to know DSQL before building on it

### Isolation and conflicts

DSQL works at a single isolation level, REPEATABLE READ, and rejects SERIALIZABLE. SERIALIZABLE is the strictest level: it acts as if transactions ran one after another, in line, with no overlap; it's the safest and the most expensive. REPEATABLE READ is one step below: every transaction sees a coherent snapshot of the data taken at the start, but two transactions writing the same row conflict.

And here's DSQL's trait: concurrency is optimistic (optimistic concurrency) and lock-free. Postgres, on the second write to the same row, takes a lock and makes it wait; DSQL doesn't, it lets them run, and when two writes clash the conflict only shows up at save time, with error `40001`. You don't know beforehand, you find out at COMMIT: that's why the placement retries, re-reads and re-applies. Knowing this before building on it is half the work.

As a lazy, broke developer, I didn't use DSQL to write the logic: it's an AWS resource and it costs. Local Postgres has the SERIALIZABLE isolation that produces the same `40001` as optimistic concurrency, so I validated offline, for free, that the cooldown timestamp was checked in the same transaction as the pixel write and that conflicts were handled, before deploying to AWS.

### The scoring

The score has two modes. The default one is simple: it counts a team's cells plus the sides it shares with itself, and rewards staying compact. The interesting one is by connected areas: the score is the sum of the square of the size of each contiguous territory, so a united front is worth a lot and splitting a large area in two penalizes it. It's the scoring that gives the game meaning.

Computing it inside the database would mean a recursive query that, starting from a cell, reaches all those attached to it of the same team. On the real cluster it doesn't hold up: the intermediate result grows with the square of the cells and crosses the 300-second per-transaction limit at around 1300 contiguous cells already. The same computation done outside the database, in Node, with an algorithm that merges neighbouring cells into groups (union-find), is linear: the whole canvas in a few milliseconds, a million cells in a quarter of a second.

The area scoring I compute app-side: the recursive version stays only as proof that on DSQL it runs but doesn't scale. The numbers are in the [scoring report](https://github.com/bilardi/territory-war/blob/master/docs/reports/SCORING_REPORT.md).

### The constraints, the hard way

Most of these limits I didn't read in the documentation, I ran into them one by one using DSQL.

To empty the tables, locally I used TRUNCATE; on DSQL it doesn't exist: I switched to DELETE.

Then, trying out the script that paints the canvas with four teams, I did a reset and the DELETE blew up: a transaction modifies at most 3000 rows, and a full canvas touches many more. Fix: the reset deletes in chunks under 3000.

Applying the schema, the second CREATE TABLE in the same transaction was rejected: a single DDL statement per transaction, so the schema has to be applied one command at a time.

And no foreign keys, because on DSQL there aren't any: integrity between tables (a player must belong to a team that exists) has to be enforced by the app.

The 300-second per-transaction limit surfaced while measuring how far the recursive scoring query would hold (previous paragraph).

And to connect there's no password: DSQL wants a short-lived IAM token, signed for the cluster's region. In multi-region it's an interesting detail: a token for one region isn't valid for the other, each has its own host and its own signature.

### Real conflicts vs overwrites

I wanted to understand whether the conflicts could be shown in a video. To provoke them I launched two scripts painting the same cells at the same time.

At a glance it seemed to work: some pixels changed colour, others stayed, and it looked like watching conflicts live. As the acid test, I counted the retries from 40001, and the truth came out: almost all were plain overwrites, one after another, where the last writer wins, no conflict. Only a fraction of the overwrites were truly simultaneous collisions.

### Active-active, proven with a test

DSQL multi-region is active-active: two regions, both writable, on the same logical database (plus a third "witness" region that only acts as a quorum arbiter, with no endpoint to query; the two active ones must be on the same continent, no cross-continent).

That it's truly coherent you can't see by eye, but a test proves it: write on one region and read back from the other, both ways, and the data is there immediately; and two writes to the same cell from different regions give the same `40001` conflict as before. It's the proof of cross-region strong consistency, the one that eventually consistent global tables don't give. And it's the feature that, as a former DBA, I'd have wished for ..

The details of the test, with the commands to reproduce it, are in the [DSQL report](https://github.com/bilardi/territory-war/blob/master/docs/reports/DSQL_REPORT.md).

## What's missing to be truly million-scale ?

What I built shows you can have a system that scales to millions of players on a globally managed canvas. But to really have it, what's missing ?

For the competition there's one Vercel deploy per region, but they're two distinct URLs. Vercel doesn't route the user to the nearest app on its own, because they're two separate projects: it routes within a project, not between different projects. Today the URL is the user's choice, and automatic routing to the nearest region is missing. On AWS that would come from Amazon Route 53 with latency-based routing, which sends each user to the nearest regional endpoint.

Right now each app talks to the cluster endpoint of its own region, and within the region DSQL handles an availability-zone failure on its own, transparently. And if a region's DSQL endpoint becomes unreachable ? The data isn't lost, it's already alive in the other because it's active-active; what's missing is the connection point: the endpoint is regional, so the app pointed at that region is left with no one to talk to. You'd need automatic failover to the other region's endpoint, which DSQL doesn't offer natively: the client has to handle it, picking the healthy endpoint and re-signing the token for its region.

And the most interesting point: per-region realtime. Today AppSync is a single API in one region, called even by apps from other regions, and it's the bottleneck because the database is already distributed.
The clean path isn't a second event system to keep aligned with the database by hand, but a realtime that comes from the data already committed. One AppSync per region, on its own, isn't enough: if each broadcast only its own region's writes, the canvases would see part of the events, not the same match. This is where DSQL's [change data capture (CDC)](https://aws.amazon.com/about-aws/whats-new/2026/05/amazon-aurora-dsql-change-data-capture-preview/) comes in: it reads the committed writes and delivers them to Amazon Kinesis Data Streams, one stream per region that receives all the cluster's writes, not just that region's; from that stream each region's AppSync is fed, so every canvas gets the whole game. Realtime becomes a consequence of the data, not a parallel system to keep coherent. It's a feature in [preview](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/cdc-streams.html), but it's exactly the right direction. And that the stream may deliver the same event more than once, and out of order, isn't a problem here: on the canvas the last writer wins per cell anyway.

![Future Architecture](https://raw.githubusercontent.com/bilardi/territory-war/master/docs/images/architecture.whats-next.drawio.png)
