# Notes from building an agent-loop substrate on Cloudflare Artifacts

> *Ivar Vong, May 2026*

I spent a few sessions building the obvious thing: an agent-loop persistence
layer on top of Cloudflare Artifacts. Specifically — can a fungible agent
process boot against a CF-backed git repo, mutate state through a uniform
filesystem surface, push a turn-boundary commit, drop *all* in-memory state,
and have a fresh process on a different machine rehydrate from the artifact
and continue?

Short answer: **yes, with one specific protocol gap I'll get to**. Long
answer below. Three integration tests against real CF Artifacts; two green,
one tracked-limitation. The repo is [`ivarvong/vfs`](https://github.com/ivarvong/vfs);
the relevant files are in `test/integration/`.

## What I built

The agent loop has the shape every agent loop has: durable per-session
state (the repo), ephemeral per-turn scratch (notes, intermediate
artifacts), and a uniform read/write surface for tool calls. I built it
three ways against the same CF Artifact in five phases — provision, seed,
agent-1 boots and mutates and pushes, drop state, agent-2 rehydrates and
reads the writes back.

### Variant A: `git` binary + temp folders (`cloudflare_artifacts_baseline_test.exs`)

The baseline anyone would build. `mkdir`, `git clone -c http.extraHeader=...`,
`File.read!`, `File.write!`, `git commit`, `git push`. ~110 lines of test
code. Works. Token lives in `.git/config` on disk; one OS process per agent
session; needs a `git` binary on PATH.

### Variant B: `exgit` + `VFS` mount table (`cloudflare_artifacts_test.exs`)

Pure-Elixir git (no binary), in-process object/ref stores, a `VFS` protocol
mount table exposing `/repo` (the workspace on the artifact) alongside
`/scratch` (an in-memory ephemeral mount). Token stays in process memory.
~120 lines. Also works. Runs on Workers/Lambda/Nerves — anywhere you can run
BEAM but can't shell out to `git`.

Both variants pass against real CF five times in a row. The rehydration
property is real: fresh process, zero shared cache, fresh `Exgit.clone` or
`git clone`, agent-2 reads agent-1's writes byte-for-byte.

The two demos earn ~the same line count. What changes between them isn't
volume of code — it's the **runtime envelope**. Variant B is the only path
into sandboxes that can't host a `git` binary, and into the in-process
multi-tenant case (N concurrent agent sessions in one BEAM node, each with
its own object store, no `cwd` dancing, no temp-folder cleanup).

### Variant C: the probe (`cloudflare_artifacts_partial_test.exs`)

This one's the finding. CF Artifacts is being positioned as an agent
substrate; for that story to work at scale, agents need to boot in time
bounded by what they actually read, not by repo size. Git protocol v2 has
the exact primitive: the `filter` fetch capability, with `filter=blob:none`
shipping refs + commits + trees but omitting all blob bytes. The agent then
fetches blobs on demand the first time it opens a file. Boot time stays
flat as history grows.

The probe attempts `Exgit.clone(transport, filter: {:blob, :none},
if_unsupported: :error)` against CF. It fails with
`{:error, {:filter_unsupported, ["shallow"]}}`. Receipts below.

## What CF Artifacts already does well as an agent substrate

Before the gap, the things that are right. The product is well-shaped for
agent workloads in ways that aren't obvious until you try to build one:

- **Each repo is a routable durable instance.** From the docs: "Like
  Durable Objects, a repo is a single logical instance that Cloudflare
  can route to from any region." That maps one-to-one onto "each agent
  session has a durable backing instance that any agent process can
  resume." The fungibility property the demos prove is enabled by the
  product, not bolted on.
- **Repo-scoped tokens with TTLs and read/write scoping** are the right
  primitive for sandboxed agents. Mint a `write` token at session boot
  with TTL ≥ expected session length; the agent process holds it for the
  session and it expires. The root API token never leaves your control
  plane. The "tokens encode expiry in their URL suffix" detail is cute
  and right — agents can introspect expiry without a separate call.
- **Synchronous cross-DC replication.** A push that returns success has
  reached durable storage. Agent-loop semantics don't have to reason
  about a write-acknowledgement window; turn-boundary commits are
  immediately resumable elsewhere.
- **Fork is a first-class server-side operation** (`POST /repos/:name/fork`).
  This is the one that changed how I think about the research story
  below — see "Implications for the agent loop."

## The finding, with the receipts

CF Artifacts runs a custom git server identified as `gitty/1.0` — not stock
`git-upload-pack`. Asking it for its protocol v2 capabilities yields:

```
$ GIT_TRACE_PACKET=1 git -c protocol.version=2 ls-remote <artifact> 2>&1 \
    | grep -E '(version|agent|fetch=|ls-refs)'

packet: version 2
packet: agent=gitty/1.0
packet: ls-refs=unborn
packet: fetch=shallow
packet: server-option
packet: object-format=sha1
```

The `fetch=shallow` line is the whole story. A server that supports filter
advertises something like `fetch=shallow filter wait-for-done
sideband-all`. `gitty/1.0` lists `shallow` only.

Independently: running stock git directly,

```
$ git clone --filter=blob:none <artifact> /tmp/probe
warning: filtering not recognized by server, ignoring
Cloning into '/tmp/probe'...
```

The git CLI sees the same gap and silently falls back to a full clone.
exgit errors loudly via `:filter_unsupported`; for agent callers that's the
right shape — silent fallback would mask the boot-time regression.

## Implications for the agent loop

The gap is narrower than I first framed it — but it's real, and it's
specifically in the **cold-boot resumption** path.

For the **fork case** — "agent reaches a decision point, wants to explore
two trajectories, picks the winner" — CF already has the right primitive
at the API layer: `POST /repos/:name/fork` produces a new isolated repo
with its own routing, tokens, and durable state, starting from the
parent's history. That's strictly better than git's partial-clone story
for forking: no per-process pack management, no client-side dedup
concerns, no cross-fork blob-fetch RTTs. The agent decides to fork via
HTTP, the platform handles the rest. Beautiful.

For the **resumption case** — "fresh agent process boots against an
existing long-lived repo and reads its way into the state" — only two
options exist today:

1. **Full clone.** Boot fetches every blob in the repo's history. Fine
   for small repos. For an agent that's been running for hundreds of
   turns — where each turn is a commit, and each commit carries blob
   deltas — boot time grows linearly with cumulative blob bytes. The
   "fungible agent on a long-lived state repo" property degrades over
   time.

2. **Shallow clone (`--depth=N`).** Boot is bounded, but you lose
   history past depth N. This is the thing that breaks the most
   interesting research story — *the agent reading its own commit log
   to reason about prior turns, audit its own behavior, or replay from
   a past state*. Shallow ≠ blobless. Shallow truncates **history**;
   blobless truncates **payload** while keeping history intact. They are
   not interchangeable.

The combination an agent loop actually wants for resumption — full
history available for introspection, blob payload fetched lazily as the
agent opens files — requires `filter`. Without it, CF Artifacts hosts
the storage-layer rehydration story (works today, demonstrated above)
and the fork-and-explore story (works today via the fork API), but not
the metacognition-via-VCS story that's the natural research extension
once both are in place.

## The fix

This is a server-side change in `gitty`. Add `filter` to the `fetch=` line
in the protocol v2 capability advertisement, implement the filter-spec
handling in upload-pack-equivalent code, and the entire ecosystem of
partial-clone-aware tooling (stock git, exgit, libgit2, etc.) lights up
against CF.

It's not a research problem. It's a known git capability with a public
spec ([gitprotocol-v2(5)](https://git-scm.com/docs/gitprotocol-v2)) and
multiple reference implementations to crib from. Implementing the blob
filter alone unlocks the bounded-boot property for agents.

## What I'd want to investigate next

Three threads I think are worth pulling, in rough order of how
research-shaped they are:

1. **Agent commit grain.** If every agent turn is a commit, what does a
   well-shaped commit history look like? Can a model author commit
   messages that are *legible to a human reviewer* as a decision log?
   This has a clean eval surface: take a transcript, generate a history,
   show a human, ask "could you reconstruct what the agent did and why
   from this alone?"

2. **Fork-and-explore policy.** CF's fork API makes the *mechanism*
   essentially free — one HTTP call produces a new routable repo with
   independent state. The interesting question moves up a level:
   what's the right *policy* for an agent to decide when to fork? When
   to merge versus discard? How does it summarize the discarded branch
   back into the main trajectory so the next turn benefits from what it
   learned, without bloating the surviving history? This is a real
   research problem with a clear eval surface (does the fork-equipped
   agent converge faster on tasks where exploration matters?) and the
   substrate to run experiments on.

3. **Multi-agent on one repo.** Two agents on parallel branches, a
   third merging. What does conflict resolution look like when both
   sides are model-authored? Where does CF's concurrent-push behavior
   break? Finding the limits is more interesting than reporting the happy
   path.

The first two together are what I'd most want to work on. (1) is the
question of "are agent decision logs legible to humans"; (2) is the
question of "when given cheap forking, do agents converge better." Both
have eval surfaces that can be built on top of the substrate that
already exists.

## Appendix: how to reproduce

```bash
# Three integration tests, all opt-in.
mix test --include integration_network test/integration/cloudflare_artifacts_test.exs
mix test --include integration_network test/integration/cloudflare_artifacts_baseline_test.exs

# The probe is tagged :known_limitation so it stays out of the default
# integration suite. Run it explicitly to re-check CF for capability
# changes:
mix test --include known_limitation test/integration/cloudflare_artifacts_partial_test.exs
```

Requires `CF_API_TOKEN` and `CF_ACCOUNT_ID` env vars (management API). The
tests provision a fresh repo per run via the management API and delete it
on exit, so they're safe to run against a real account.
