#!/usr/bin/env bash
# The whole corpus update, from the SoundCloud channel to the site being live.
#
#   pnpm corpus:update              # everything, no stops
#   pnpm corpus:update --review     # stop at each human checkpoint instead
#   pnpm corpus:update <stage>      # resume from one stage
#   pnpm corpus:update smoke "<phrase from a new sermon>"
#
# Stages, in order. Money and idempotency are noted because they are the two
# things that decide whether a stage can be re-run without thinking:
#
#   corpus    SoundCloud -> data/            GPU, days, free, resumable
#   facets    derive:facets, extract:scripture   paid but cached; ONE stage,
#             because derive rewrites sermon_scriptures.csv from title rows only
#             and would drop every cached LLM row if run on its own
#   topics    label:topics                   paid per new sermon, resumable
#   spotify   check:spotify                  free, one HTTP request, idempotent;
#             expires on its own because the podcast feed's 500-item window
#             rolls, so it is worth running without a corpus update behind it
#   verify    the abort criteria below       free
#   canonicalize  series.csv rewrite         only when verify found a new series;
#             refuses to retire a committed slug, so it is safe unattended
#   commit    commit data/ and push          the reviewer runs on push
#   index     index, index:facets            paid on new chunks only; the order
#             is load-bearing, index-facets filters to ids already in the DB
#   eval      pnpm eval                      blocks the release if recall drops
#   release   build -> ghcr -> VPS -> up -d  refuses a dirty tree
#   smoke     production verification        rolls back on a mismatch
#
#
# Default mode runs unattended, so the checks in `stage_verify` are the only
# thing between a bad derivation and the live site. Adding a stage means asking
# what would catch it going wrong at 3am with nobody watching.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="${IPP_WORK_DIR:-/mnt/Data/ipp-sermons-work}"
VENV="${IPP_VENV_DIR:-/mnt/Data/venv/ipp-sermons}"
REMOTE=hostinger
REMOTE_DIR=/opt/amiticia/ipp-sermons
# The VPS runs a checkout of this repo from deploy/, with .env beside the compose
# file (standards/deployment.md). Never compose from the checkout root: that is
# the DEV docker-compose.yml, with no .env.
DEPLOY_DIR="$REMOTE_DIR/deploy"
IMAGE=ghcr.io/eusoubrasileiro/ipp-sermons
SITE=https://ipp-sermons.amiticia.cc
PREV_TAG_FILE="$WORK/.previous-image-tag"

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
say() { printf '\n=== %s ===\n' "$*"; }

REVIEW=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --review) REVIEW=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
STAGE="${ARGS[0]:-all}"
PHRASE="${ARGS[1]:-}"

# A checkpoint is not a failure. In --review mode it prints what a human should
# look at and how to carry on; in the default mode it is a no-op.
checkpoint() {
  [ "$REVIEW" -eq 1 ] || return 0
  printf '\n--- %s\n\n  %s\n\n' "$1" "$2"
  exit 0
}

# One run at a time, across the GPU, the paid LLM passes, git and the VPS.
# Deliberately NOT $WORK/.lock: tools/corpus-update/run.sh holds that one, and a
# child taking `flock -n` on the same file would fail on every single run.
mkdir -p "$WORK"
exec 9>"$WORK/.orchestrator.lock"
flock -n 9 || die "another corpus-update already holds $WORK/.orchestrator.lock"

stage_corpus() {
  say "pipeline self-check"
  # Cheap, no GPU, no network. It guards the resume key that decides whether a
  # re-run is a no-op or a rewrite of every transcript in the corpus.
  "$VENV/bin/python" -m pytest tools/corpus-update -q

  say "corpus  (SoundCloud -> data/)"
  tools/corpus-update/run.sh all

  say "verify:corpus"
  pnpm verify:corpus

  if [ -z "$(git status --porcelain data/)" ]; then
    printf '\ndata/ unchanged -- nothing new upstream.\n'
    printf 'To publish work already committed:  pnpm corpus:update release\n\n'
    exit 0
  fi
}

stage_facets() {
  say "derive:facets"
  pnpm derive:facets
  # Same stage on purpose: derive:facets just rewrote sermon_scriptures.csv with
  # the title rows alone, and extract:scripture is what puts the cached LLM rows
  # back. Between the two the file is incomplete.
  say "extract:scripture"
  pnpm extract:scripture
}

stage_topics() {
  say "label:topics"
  # Labels only sermons absent from sermon_topics.csv, against the taxonomy that
  # is already committed. propose:taxonomy is not run here and has no root
  # passthrough -- it rewrites taxonomy.csv from scratch and orphans every row.
  pnpm label:topics
}

# Which Spotify episodes still resolve. Runs after every other data/facets/
# writer and before the commit, so its file lands in the same reviewed diff.
#
# Also useful on its own -- `pnpm corpus:update spotify`. The podcast feed holds
# 500 items and the window rolls, so this answer expires whether or not new
# sermons were published, and stage_corpus exits early when data/ is unchanged.
stage_spotify() {
  say "check:spotify"
  pnpm check:spotify
}

# The abort criteria that stand in for the human who is not watching.
stage_verify() {
  say "verify:facets"
  local rc=0
  pnpm verify:facets || rc=$?
  case $rc in
    0) ;;
    2) NEW_SERIES=1 ;;   # loadable; reported at the end, never auto-canonicalised
    *) die "verify:facets found blocking problems (above)" ;;
  esac

  say "diff sanity"
  # A corpus update only ever adds. New transcripts are untracked, so anything
  # `git diff` has to say about data/transcripts/ is an existing, already
  # reviewed file being rewritten -- the signature of the postprocess resume key
  # breaking again. Unattended, that would be committed and published.
  local rewritten
  rewritten=$(git diff --numstat -- data/transcripts/ | wc -l)
  [ "$rewritten" -eq 0 ] ||
    die "$rewritten existing transcript(s) were rewritten; stop and look before committing"

  git --no-pager diff --stat -- data/ | tail -20
  checkpoint "Review the diff above." "pnpm corpus:update commit"
}

stage_commit() {
  if [ -z "$(git status --porcelain data/)" ]; then
    say "commit  (nothing staged in data/, skipping)"
    return 0
  fi

  say "commit"
  local added
  added=$(git status --porcelain data/transcripts/ | grep -c '^??' || true)

  # Both halves are load-bearing, and each fixes something the other caused.
  #
  # `git add` first, because the new transcripts are untracked and `--only` on
  # its own commits tracked changes only: it produced a metadata.csv naming 47
  # files that were not in the tree, and `verify:corpus` fails on that checkout.
  #
  # `--only` second, because a rejected commit used to leave the corpus staged,
  # and the next commit anyone made swept all of it in -- under a message about
  # something else, without the Ratified-by trailer that data/** requires. The
  # reset on failure is what actually restores the index.
  #
  # The trailer is its own final paragraph. git only parses trailers from a last
  # block of trailer-shaped lines; appended to prose it is written and invisible.
  # Wrapped by hand: commitlint caps a body line at 100 characters, and git
  # never re-wraps a -m. An over-long line here means the stage cannot commit
  # at all, which is a failure at the end of a run that took days.
  git add -A data/
  git commit -q --only data/ \
    -m "feat(data): +$added sermons from the SoundCloud archive" \
    -m "Transcribed offline by tools/corpus-update, then classified by the facet
passes. Derived ground truth, regenerated and committed by
scripts/corpus-update.sh." \
    -m "Ratified-by: André <eusoubrasileiro@gmail.com>" ||
    { git reset -q -- data/; die "the corpus commit was rejected (above)"; }

  say "push  (typecheck, lint, coverage, quality gate, reviewer)"
  git push
}

stage_index() {
  say "database"
  docker compose up -d db
  local tries=0
  until docker compose exec -T db pg_isready -U ipp -d ipp_sermons >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || die "the dev database never became ready"
    sleep 1
  done

  say "index  (embeddings; content-hash keyed, only new chunks cost)"
  pnpm index
  # Always after index: index-facets filters scripture and topic rows to the
  # sermon ids already in the database, so a new sermon indexed the other way
  # round loses its facets in silence.
  say "index:facets"
  pnpm index:facets
}

stage_eval() {
  say "eval  (the only check that proves the search is still any good)"
  pnpm eval || die "recall dropped -- release blocked"
}

stage_release() {
  # docker build's context is the worktree, not HEAD, so a dirty tree would ship
  # code that is in no commit at all.
  [ -z "$(git status --porcelain)" ] || die "worktree is dirty; commit before publishing"
  [ "$(git rev-parse HEAD)" = "$(git rev-parse '@{upstream}' 2>/dev/null || echo none)" ] ||
    die "HEAD is not pushed; an image tag should name a commit others can read"

  local sha prev
  sha=$(git rev-parse --short HEAD)

  say "build $IMAGE:$sha"
  docker build -t "$IMAGE:$sha" -t "$IMAGE:latest" .
  docker push "$IMAGE:$sha"
  docker push "$IMAGE:latest"

  # The VPS is a checkout, so the compose file and the migrations the `migrate`
  # sidecar mounts (../backend/prisma/sql) arrive by pulling the commit this
  # image was built from. --ff-only, and only on a clean tree: an edit made on
  # the box is refused here rather than merged into a release unseen.
  say "pull -> $REMOTE:$REMOTE_DIR"
  prev=$(ssh "$REMOTE" "grep '^IMAGE_TAG=' $DEPLOY_DIR/.env | cut -d= -f2" || true)
  printf '%s\n' "${prev:-latest}" > "$PREV_TAG_FILE"
  ssh "$REMOTE" "set -e
    [ -z \"\$(git -C $REMOTE_DIR status --porcelain --untracked-files=no)\" ] ||
      { echo 'the VPS checkout has local edits; refusing to pull' >&2; exit 1; }
    git -C $REMOTE_DIR pull --ff-only -q
    [ \"\$(git -C $REMOTE_DIR rev-parse HEAD)\" = $(git rev-parse HEAD) ] ||
      { echo 'the VPS checkout is not at $sha after pulling' >&2; exit 1; }" ||
    die "could not bring $REMOTE:$REMOTE_DIR to $sha"

  say "deploy $sha  (migrate -> index -> facets -> app)"
  deploy_tag "$sha"
  wait_for_site
}

# `docker compose up -d` returns when the container is started, not when Traefik
# has re-registered it. Asserting straight afterwards read the gap as a failure
# and would have rolled a perfectly good deploy back.
wait_for_site() {
  local tries=0
  until curl -fsS -o /dev/null "$SITE/api/health"; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || die "$SITE never came back after the deploy"
    sleep 2
  done
}

deploy_tag() {
  ssh "$REMOTE" "set -e; cd $DEPLOY_DIR
    cp -n .env .env.bak-\$(grep '^IMAGE_TAG=' .env | cut -d= -f2) 2>/dev/null || true
    if grep -q '^IMAGE_TAG=' .env
      then sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=$1|' .env
      else echo 'IMAGE_TAG=$1' >> .env
    fi
    # The one-shots are ordinary containers to compose; without this a redeploy
    # of the same tag considers them up to date and skips migrate and index.
    docker compose rm -sf migrate index facets >/dev/null 2>&1 || true
    docker compose up -d"
}

stage_smoke() {
  say "smoke"
  local want got
  # Also here, not only in release: `smoke` is meant to be runnable on its own
  # after a hand deploy, and would hit the same window.
  wait_for_site
  want=$(pnpm verify:corpus | sed -n 's/^indexable sermons: \([0-9]*\).*/\1/p')
  got=$(curl -fsS "$SITE/api/health" | jq -r .sermons)
  printf 'corpus %s / production %s\n' "$want" "$got"

  # The real end-to-end assertion. It fails for exactly the silent case the
  # `index` service exists to prevent: a site that renders, passes its health
  # check, and cannot find the sermons that were just added.
  if [ "$want" != "$got" ]; then
    local prev
    prev=$(cat "$PREV_TAG_FILE" 2>/dev/null || true)
    if [ -n "$prev" ]; then
      say "rolling back to $prev"
      deploy_tag "$prev"
    fi
    die "production has $got sermons, the corpus has $want -- the index did not run"
  fi

  curl -fsS "$SITE/api/facets" |
    jq -r 'to_entries|map("\(.key)=\(.value|length)")|join("  ")'

  if [ -n "$PHRASE" ]; then
    curl -fsS -X POST "$SITE/api/search" -H 'content-type: application/json' \
      -d "$(jq -nc --arg q "$PHRASE" '{query:$q}')" |
      jq -r '"search: \(.results|length) results, top: \(.results[0].title // "none")"'
  fi

  printf '\n%s is live and matches the corpus.\n' "$SITE"
}

# Runs automatically, but only when `verify` found a series canonicalisation has
# never seen. It is a full, non-deterministic rewrite of series.csv, so what
# makes it safe to leave unattended is the guard inside the script: it refuses to
# write if the answer would retire a slug that is already committed, because
# those are live /series URLs. Growing the taxonomy is the only outcome it will
# accept on its own; anything else stops here with the diff on screen.
stage_canonicalize() {
  say "canonicalize:series  (new series found; rewrites series.csv in full)"
  # Exit 1 covers both the guard rejecting a merge and the call failing outright,
  # so point at the output rather than asserting which one happened.
  pnpm canonicalize:series || die "canonicalize:series did not write series.csv (reason above)"

  git --no-pager diff --stat -- data/facets/series.csv

  # The taxonomy changed under sermon_facets.csv, so the mapping has to be
  # rebuilt against it before anything downstream reads either.
  say "derive:facets  (re-mapping sermons onto the new series)"
  pnpm derive:facets
  pnpm extract:scripture

  local rc=0
  pnpm verify:facets || rc=$?
  [ "$rc" -eq 0 ] || die "verify:facets still unhappy after canonicalisation (rc=$rc)"
  NEW_SERIES=0
}

NEW_SERIES=0

case "$STAGE" in
  corpus | facets | topics | spotify | verify | commit | index | eval | release | smoke | canonicalize)
    "stage_$STAGE"
    ;;
  all)
    stage_corpus
    stage_facets
    stage_topics
    stage_spotify
    stage_verify
    # `[ ... ] && stage_...` would return 1 on the common path and set -e would
    # take the whole run down with it.
    if [ "$NEW_SERIES" -eq 1 ]; then stage_canonicalize; fi
    stage_commit
    stage_index
    stage_eval
    checkpoint "Local checks passed. Production is next." "pnpm corpus:update release"
    stage_release
    stage_smoke
    ;;
  *) die "unknown stage: $STAGE" ;;
esac

if [ "$NEW_SERIES" -eq 1 ]; then
  cat <<'EOF'

--- A series name canonicalisation has never seen turned up (see the AVISO
    lines above). Those sermons browse without a series until you run:

      pnpm corpus:update canonicalize

    Not automatic: it rewrites series.csv in full and can rename series that
    already exist, which changes their /series URLs.
EOF
fi
