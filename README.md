# Publish to Tonk

A GitHub Action that publishes a directory of [tonk](https://github.com/tonk-labs/tonk)
notation documents, plus the files they include, into a Tonk space. It works
like `gh-pages`: keep the content in your repository, and every push to it
updates the space.

```yaml
on:
  push:
    branches: [main]

jobs:
  publish:
    runs-on: ubuntu-latest
    # One publish at a time; a newer push supersedes a queued one.
    concurrency: tonk-publish
    steps:
      - uses: actions/checkout@v4
      - uses: tonk-labs/publish-action@v1
        with:
          invite: ${{ secrets.TONK_INVITE }}
          directory: tonk
```

## Setup

1. In Tonk, open the space and choose **connect agent**. Copy the link.
2. In the repository, add it as an Actions secret named `TONK_INVITE`
   (*Settings → Secrets and variables → Actions*).
3. Put your documents under `tonk/` (or set `directory`) and push.

The link is a bearer credential: it carries the connection's key and the
grants that let it read and write the space's `main` branch. Anyone holding
it can do what the action does, so keep it in a secret. Revoke the agent
connection in Tonk to cut it off.

## What gets published

Every `*.yaml` / `*.yml` file under `directory` is evaluated, in path order
(`00-schema.yaml` before `posts/hello.yaml`). Hidden files and directories
are skipped. Each document is asserted-notation, the same thing
`tonk eval` runs, so `tonk guide notation` is the reference.

Documents reach other files with `!include` tags, resolved relative to the
document:

| Tag | The field holds |
| --- | --- |
| `!include/text ./post.md` | the file's text |
| `!include ./data.bin` | the file's bytes, inline in the fact |
| `!include/asset ../assets/cover.png` | a content-addressed `asset:<hash>` reference, so declare the field `as: entity`. The file is stored as an asset in the same commit, with its media type and name, and the standard media view renders it (`model=tonk:asset`) |

Files that no document includes are not published.

See [`example/tonk`](example/tonk) for a schema, a view, and a post with a
markdown body and a cover image.

### Write documents that can be re-run

The action runs the whole directory on every push. Two things make that safe:

- **Name your entities.** `this: id:post-hello` updates the same post on every
  run. `this: ?post` mints a new entity each time, so every run would add
  another copy.
- **Publishing asserts; it never retracts.** Deleting a file, or a field in
  one, leaves its facts in the space. One-cardinality fields are superseded
  when you change them; many-cardinality fields gain the new value alongside
  the old. Retract explicitly (a `tonk eval` document, or `tonk retract`)
  when something should go away.

Re-publishing an unchanged directory asserts only facts the space already
holds, which commits nothing and pushes nothing; the `changed` and `pushed`
outputs are then `false`.

## Concurrent writers

The space may change while the action runs: people editing in Tonk, other
agents, another workflow. The action evaluates against the replica it joined, then pulls and pushes.
When the push finds the branch moved, it pulls again, merging both sides'
facts, and pushes, up to `attempts` times. Facts from both sides survive the
merge; where both set the same one-cardinality field, the newer write wins
when read.

## Inputs

| Input | Default | |
| --- | --- | --- |
| `invite` | required | Agent connection link, from a secret. |
| `directory` | `tonk` | Directory of documents, relative to the workspace. |
| `branch` | `main` | Branch to publish to. Only `main` is supported today; see below. |
| `attempts` | `5` | Push attempts when the branch keeps moving. |
| `dry-run` | `false` | Evaluate every document without committing or pushing. Useful on pull requests. |
| `agent-name` | `GitHub Actions (<owner>/<repo>)` | Label shown for this connection in the space owner's settings. |
| `tonk-version` | `latest` | `latest`, `staging`, or a release tag, such as `v0.7.0` or a pinned build's `tonk-<hash>`. |

## Outputs

| Output | |
| --- | --- |
| `changed` | `true` when the documents asserted something new. |
| `pushed` | `true` when the remote branch advanced. |

## Checking documents on pull requests

```yaml
on: pull_request

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: tonk-labs/publish-action@v1
        with:
          invite: ${{ secrets.TONK_INVITE }}
          dry-run: true
```

Workflows triggered from forks do not receive secrets, so this only checks
pull requests from branches of the repository itself.

## Limits

- **`main` only.** Agent connections are granted the `main` branch of a
  space, and the tonk CLI tracks only `main`. `branch` is accepted so
  workflows can name it, but any other value fails before anything runs.
- **Runners.** tonk publishes Linux x86_64 and macOS Apple Silicon builds, so
  use `ubuntu-latest` or `macos-latest`.
- **Every run joins from scratch.** Nothing is cached between runs: the
  connection's credentials and the downloaded replica are deleted when the
  step ends. Each run reports the same installation (derived from the
  repository name) so repeated runs do not pile up connection records.

## How it works

The action installs the tonk CLI and runs:

```sh
tonk join "$TONK_INVITE" --name tonk-publish --agent-name "…" --installation "…"
tonk --space tonk-publish eval tonk/00-schema.yaml tonk/posts/hello.yaml … --no-sync --json   # one commit, in path order
tonk --space tonk-publish pull                                   # merge others' writes
tonk --space tonk-publish push                                   # retried after a pull while the branch moves
```

`tonk eval` with several files works the same on your machine against any space you have
joined, which is the quickest way to try a directory before pushing it:

```sh
tonk --space my-space eval tonk/00-schema.yaml tonk/posts/*.yaml --dry-run
```
