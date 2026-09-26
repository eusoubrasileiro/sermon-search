# CLAUDE.md

This project runs under the [Anti-Vibe Harness](../../amiticia/repositories/standards/standards.md) —
AmiticIA's AI-agent discipline stack (dual git gate, ratcheted quality-gate, LLM
reviewer, worktree dispatch). TypeScript specifics:
`standards/typescript.md`.

## Project Overview

Portuguese-language search over the transcribed sermon archive of the Igreja
Presbiteriana Peregrinos. A visitor types a question in natural Portuguese
("briga na igreja", "Eclesiastes tempo de plantar") and gets the sermons that
answer it, with a playable SoundCloud/Spotify link and the passage that matched.

**Live** at https://ipp-sermons.amiticia.cc. It replaces a retired GPU pipeline:
transcription still happens offline (`tools/corpus-update`, Python + WhisperX),
but retrieval is now API-only — no local models, no GPU, one VPS container.

Corpus: ~610 sermons, ~27 MB of text committed under `data/` — `loadSermons()`
decides what counts. The 77 GB of audio lives on SoundCloud, never here.

## Architecture

```
data/metadata.csv + data/transcripts/*.txt
        │  pnpm index         (chunk → embed via OpenRouter → upsert)
        │  pnpm index:facets  (load the committed CSVs in data/facets/)
        ▼
Postgres 16 + pgvector          ← the whole retrieval engine lives here
  sermons, sermon_chunks(embedding halfvec(1536), fts tsvector)
  bible_books, series, topics, sermon_scriptures, sermon_topics
  hybrid_search()  = BM25-ish lexical ⊕ vector, fused by RRF, facet-filtered
        │
        ▼
backend/  Hono   POST /api/search  → hybrid_search() → cross-encoder rerank
                 GET  /api/facets  → the browse index tree
                 GET  /api/facets/counts → the same, narrowed to active filters
                 GET  /api/sermons → filtered listing, no query, no model
                 GET  /sermao/:id, /biblia/…, /sitemap.xml → prerendered HTML
        │
        ▼
frontend/ Vite + React 19, built into backend/public/ and served same-origin
```

### Why the server renders HTML at all

The SPA fallback answered **every** unmatched GET with the same empty
`index.html`, so the whole archive — exactly the long-tail Portuguese prose a
search engine rewards — was one indexable URL. `lib/seo/` rewrites the built
shell per request.

It is **string injection, not `renderToString`**: the runtime image ships
`backend/dist` and `backend/public` only, and `main.tsx` calls `createRoot`
(not `hydrateRoot`), which clears its container before the first render — so
the injected body never has to match React's output byte for byte, only carry
the same words. Anything it cannot build calls `next()` and lets the static
middleware answer exactly as before. `lib/seo/html.ts` owns the rest.

One container serves API and SPA, so there is no second origin in production.
`shared/` holds the Zod schemas both sides validate against.

### Retrieval design

Two arms, fused by **Reciprocal Rank Fusion** (k=60), plus a third arm on sermon
titles, then a cross-encoder rerank:

- **Lexical** (`ts_rank_cd` over a generated `fts` column, `pt_unaccent` config).
  Earns its place because the corpus is full of proper nouns and scripture
  references that embeddings blur — "Eclesiastes 3.2b-3a", "Jonathan Edwards".
- **Semantic** (`halfvec(1536)` HNSW, cosine). `gemini-embedding-001` truncated
  3072→1536 via Matryoshka and re-normalised.
- **Title** arm, weighted 1.5×. A preacher rarely says the title out loud, so
  "O sétimo mandamento" ranked 52nd for its own title until titles became their
  own arm.
- **Rerank** (`cohere/rerank-4-pro`) over 40 candidates. Every failure mode
  degrades to the RRF order — a slow or unreachable reranker must never turn a
  working search into an error page.

**The fusion is deliberately SQL, not LangChain.** `PGVectorStore` cannot express
a BM25 + RRF fusion; it exposes vector similarity and nothing to fuse it with.
Doing it in application code would mean shipping both candidate lists over the
wire to rank them. `hybrid_search()` in `backend/prisma/sql/003_hybrid_search.sql`
is the honest place for it. Do not "modernise" this into a framework call.

## Code Organization

| Path | Purpose |
|------|---------|
| `shared/src/` | Zod schemas, and the URL/format/paragraph helpers both sides render with — the server prerenders them and the SPA renders them again, so one copy. Built to `dist/` first; everything else depends on it. |
| `backend/src/lib/` | Retrieval, embeddings, rerank, the offline LLM passes, the corpus reader, Spotify liveness. |
| `backend/src/lib/facets/` | Facet derivation — what produces `data/facets/`. |
| `backend/src/lib/browse/` | The browse index: tree, counts narrowed to the active filters, filtered listing. |
| `backend/src/lib/seo/` | Server-rendered HTML for crawlers. |
| `backend/src/scripts/` | Every pipeline stage, plus `eval-golden`. `scripts/corpus-update.sh` owns the order they run in. |
| `backend/prisma/` | `schema.prisma` + `sql/` — **the sql files ARE the migrations** |
| `frontend/src/` | Vite + React 19 + Tailwind SPA, Portuguese UI. Filter state lives in the URL (`lib/facet-params.ts`). |
| `data/` | The corpus, committed. `data/facets/` under it is derived ground truth — a human reviews the diff before it lands. |
| `tools/corpus-update/` | Python: discover → fetch → transcribe → clean. Offline, outside the pnpm workspace and every JS gate — see its own `CLAUDE.md`. |
| `deploy/` | Production compose for the Hostinger VPS |
| `scripts/` | Dev harness (quality-gate, security-review, dispatch-worktree) + `corpus-update.sh`, which owns the order of a corpus update |
| `archive/` | Retired GPU-era Python. Reference only — never revive. |
| `docs/` | Non-normative by construction: designed-but-unbuilt work, and research. Every file carries a status banner and none of it is a spec. |

## Development

```bash
pnpm install
pnpm --filter @ipp/shared build              # everything else needs its dist/
pnpm --filter @ipp/backend exec prisma generate   # client is generated, not committed

pnpm db:up                                   # Postgres+pgvector on :5439
pnpm db:push                                 # schema + raw SQL — NOT `prisma db push`
pnpm index                                   # index the corpus (--limit 5 to smoke it)
pnpm index:facets                            # load data/facets/ — free, seconds, no API
pnpm check:spotify                           # refresh which Spotify episodes still resolve

pnpm dev                                     # backend + frontend
pnpm test                                    # unit tests, no DB, no network
pnpm test:coverage                           # writes coverage-summary.json for the gate
pnpm typecheck
pnpm lint
pnpm eval                                    # golden query set vs the REAL db + API
pnpm quality-gate                            # metric ratchet vs quality-baseline.json

pnpm corpus:update                           # SoundCloud → data/ → facets → prod
pnpm corpus:update --review                  # same, stopping at each checkpoint
```

`pnpm eval` is the only thing that proves the search is any good; unit tests
prove the plumbing. Run it after any change to `hybrid_search()`, the embedding
model, chunking, or rerank — a recall@10 that quietly halves is invisible to
every other gate in this repo, and no unit test can see it.

## Traps worth knowing

Only the ones no single file can warn you about — you hit these *before* you
open the file that would have told you. Everything else lives in the docstring
at the point of the decision, which is where it stays true.

1. **`prisma db push` drops the `fts` column every run.** The generated tsvector
   is not in `schema.prisma`, so Prisma reads it as drift and removes it —
   taking the GIN index and `hybrid_search()` with it. Always
   `pnpm db:push` (`backend/scripts/db-push.sh`), which re-applies the raw SQL.

2. **`@prisma/client` is CommonJS.** `import { PrismaClient } from "@prisma/client"`
   resolves under the dev loader and throws in the compiled ESM build, where
   named-export detection misses it — so typecheck and tests are both green.
   Use a default import and destructure:
   `import pkg from "@prisma/client"; const { PrismaClient } = pkg;`

3. **Prisma sends JS numbers as bigint.** SQL function arguments need an explicit
   cast — `${candidateCount}::int` — or Postgres cannot resolve the overload.

4. **Migrations are committed SQL applied by a `postgres:16-alpine` sidecar,
   deliberately not the Prisma CLI.** The CLI is a devDependency that `--prod`
   strips, and pulling it back drags `@prisma/engines` into the runtime image.
   New SQL must be idempotent by hand: `migrate diff` emits unguarded
   `CREATE`/`ADD CONSTRAINT`, and the sidecar re-applies every file on
   every deploy.

5. **Spotify links can die while their ids stay valid** — an episode drops out
   of the 500-item RSS feed and gets delisted. `spotify_alive` on `sermons` is
   the only thing the app may read for this; `pnpm check:spotify` refreshes it.
   SoundCloud covers the whole corpus and is never suppressed. Why, and what
   the church can do about it: `backend/src/lib/podcast-feed.ts` and
   `docs/spotify-feed-window.md`.

## Critical files

Two machine-readable lists hold this line, and they are the only authority: the
`ask` tier in `.claude/settings.json` (stops the edit) and the critical-paths
list in `scripts/security-review.mjs` (stops the push). Read them there. A third
copy in prose would only drift out of sync with both — as this one had.

Editing any of them needs the owner's `Ratified-by` trailer on the commit. If a
task appears to require one, stop and ask.

## Testing discipline (TDD — mandatory)

Red-Green-Refactor: failing test first, then implement, then refactor. The
reviewer can see that a test *exists*; only you can honour the order.

Unit tests touch neither DB nor network — `createApp()` takes its dependencies
so the real routes run against stubs. A retrieval change is the one thing they
cannot cover; that is what `pnpm eval` and the golden set are for.

## Multi-agent dispatch

Sub-agents never run in the parent worktree. `pnpm dispatch <slug>` gives each
one its own worktree, branch, ports and Postgres database, so nothing they do
is visible to each other until a merge. Running several agents in the *same*
working tree is the anti-pattern this exists to prevent: one agent's
half-finished change turns everyone else's pre-commit red, and nobody can commit.

The leader writes `.claude/plans/<slug>.md` **before** dispatching — the script
hard-fails without it, and that plan is the sub-agent's whole contract. Write it
as one, not as a hint. `pnpm dispatch:cleanup --slug <slug>` tears one down;
`scripts/cleanup-worktrees.sh` prints its own flags.

## Gates

The hooks in `.husky/` say what they run and why. Two things they cannot say
for themselves: pre-push ends in an LLM reviewer that costs a real API call and
fails closed, so a push is slow and can be *rejected on judgement* rather than
on a failing command; and commit type matters — the reviewer keys off
`fix:`/`bug:`/`hotfix:` to demand a regression test in the same commit.

Never `--no-verify`. A failing hook means fixing the root cause, never editing
the gate to agree with the code.

## Deployment

Image `ghcr.io/eusoubrasileiro/ipp-sermons` → Hostinger VPS at
`/opt/amiticia/ipp-sermons/`, a git checkout of this repo that runs
`deploy/docker-compose.yaml` with `.env` beside it in `deploy/`. A release pulls
the checkout to the image's commit (`stage_release`); never compose from the
checkout root, which is the dev file. Traefik v3 on the external
`network_public` terminates TLS and routes `ipp-sermons.amiticia.cc`.

Five services, in dependency order: `db`, `migrate` (one-shot, applies the
committed SQL), `index` then `facets` (one-shot, and that order is load-bearing
— `index-facets` filters its rows to the sermon ids already in the database),
`app`. Memory limits are not decorative — the box has ~2 GB free of 7.8 GB,
plus 4 GB of swap added for this deployment.

Rollback: pin `IMAGE_TAG` in `.env` to the previous digest and
`docker compose up -d`.

## Constraints

- **UI text is Portuguese.** Code, comments and commit messages are English.
- **OpenRouter is the single LLM credential** — embeddings and reranking both.
- **`PUBLIC_BASE_URL`** sets the origin in canonical and Open Graph URLs. It
  defaults to the production origin, so nothing has to be set to deploy; set it
  when serving the site under any other name.
- Embeddings are **1536-d, not 3072**: pgvector caps HNSW on `vector` at 2000
  dimensions. Changing dimension means re-indexing the whole corpus (paid).
- **`loadSermons()` in `backend/src/lib/corpus.ts` is the only definition of
  "the corpus".** It applies every cutoff and every dedup rule, and each one is
  justified where it lives. Do not filter `data/metadata.csv` anywhere else —
  a second opinion about which rows count is how the site and the facets
  disagree.
- `data/metadata.csv` column names are inherited from `sermons_ai/doc_preproc.py`
  (now in `archive/`). Quirks there are historical, not chosen — don't "clean
  them up".

## What we won't build

- **No LangChain / LlamaIndex for retrieval.** The reason hybrid search is in SQL
  is that the framework abstraction cannot express it (see Architecture).
- **No self-hosted models.** The whole point of the rewrite was to retire the GPU
  box. Embeddings and reranking go over an API or not at all.
- **No user accounts, no auth.** Search over a public archive. The one write a
  visitor can make is `POST /api/suggestion`, which is unauthenticated and
  currently unthrottled — do not add a second one, and do not model this as
  read-only when reasoning about the VPS.
- **No audio hosting.** SoundCloud and Spotify own the 77 GB; we link to it.
- **No admin UI for the corpus.** Corpus updates are a batch pipeline
  (`tools/corpus-update`), reviewed by a human, committed to git.
