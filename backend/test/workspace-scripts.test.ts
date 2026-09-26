import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * The pnpm scripts are an interface, and nothing else checks them.
 *
 * A corpus update runs eight of them in an order where two of the steps
 * silently destroy the previous one's output if reversed. Once that order lives
 * in a script rather than in someone's memory, the names it calls and the
 * environment they load stop being cosmetic: a script that exists only inside
 * `backend/` is a stage the orchestrator cannot invoke, and a script that does
 * not load `.env` dies on a missing key halfway through a paid run.
 */
const ROOT = join(import.meta.dirname, "../..");

function scripts(pkg: string): Record<string, string> {
  return JSON.parse(readFileSync(join(ROOT, pkg, "package.json"), "utf8")).scripts;
}

/** The facet pipeline, in the order a corpus update runs it. */
const PIPELINE = [
  "verify:corpus",
  "derive:facets",
  "extract:scripture",
  "verify:facets",
  "label:topics",
  "index",
  "index:facets",
  "eval",
];

describe("workspace scripts", () => {
  it("reaches every pipeline stage from the workspace root", () => {
    const root = scripts(".");
    expect(PIPELINE.filter((name) => !(name in root))).toEqual([]);
  });

  it("resolves every pnpm script the orchestrator invokes", () => {
    // The orchestrator is the only place the pipeline order is written down, so
    // a renamed script turns into a stage that dies mid-run rather than a
    // command nobody happened to type.
    const sh = readFileSync(join(ROOT, "scripts/corpus-update.sh"), "utf8");
    const called = new Set(Array.from(sh.matchAll(/\bpnpm ([a-z][a-z0-9:-]*)/g), (m) => m[1]));
    const root = scripts(".");

    expect(called.size).toBeGreaterThan(5);
    expect([...called].filter((name) => !(name && name in root))).toEqual([]);
  });

  it("keeps propose:taxonomy out of reach of the root", () => {
    // It rewrites taxonomy.csv from scratch, which orphans every row
    // label-topics.ts ever wrote. Leaving it backend-only is a free structural
    // guard against it ever joining the routine loop.
    expect(scripts(".")).not.toHaveProperty("propose:taxonomy");
    expect(scripts("backend")).toHaveProperty("propose:taxonomy");
  });

  it("loads .env in every backend script that runs one of src/scripts", () => {
    // Half of them did and half did not, which is why `pnpm eval` died with
    // "OPENROUTER_API_KEY is not set" and why run.sh had to source .env itself
    // before it could reach the indexer.
    const missing = Object.entries(scripts("backend"))
      .filter(([, cmd]) => cmd.includes("src/scripts/"))
      .filter(([, cmd]) => !cmd.includes("--env-file-if-exists=../.env"))
      .map(([name]) => name);

    expect(missing).toEqual([]);
  });

  it("wraps the commit message the orchestrator writes", () => {
    // commitlint caps a body line at 100 characters and git never re-wraps a
    // `-m`, so an over-long line means the commit stage cannot commit at all --
    // discovered at the end of a run that took days to get there.
    const sh = readFileSync(join(ROOT, "scripts/corpus-update.sh"), "utf8");
    const body = sh.slice(sh.indexOf("git commit -q"), sh.indexOf("Ratified-by:"));

    expect(body).not.toBe("");
    expect(body.split("\n").filter((l) => l.length > 100)).toEqual([]);
  });

  it("releases into the VPS checkout, from deploy/", () => {
    // Since 2026-09-01 /opt/amiticia/ipp-sermons is a git checkout running
    // deploy/docker-compose.yaml with .env beside it. A release that still
    // rsyncs into the checkout root and runs compose there finds the DEV
    // compose file and no .env: it starts the wrong stack, or none at all.
    const sh = readFileSync(join(ROOT, "scripts/corpus-update.sh"), "utf8");
    const fn = (name: string) =>
      sh.slice(sh.indexOf(`${name}() {`), sh.indexOf("\n}\n", sh.indexOf(`${name}() {`)));
    const release = fn("stage_release");
    const deploy = fn("deploy_tag");

    expect(release).not.toBe("");
    expect(deploy).not.toBe("");
    expect(release).not.toMatch(/\brsync\b/);
    expect(release).toMatch(/git -C "?\$REMOTE_DIR"? pull --ff-only/);
    expect(release).toMatch(/\$DEPLOY_DIR\/\.env/);
    expect(deploy).toMatch(/cd "?\$DEPLOY_DIR"?/);
    expect(sh).toMatch(/^DEPLOY_DIR="?\$REMOTE_DIR\/deploy"?$/m);
  });

  it("names every migration NNN_*.sql", () => {
    // Both the production `migrate` sidecar (`for f in /sql/*.sql`) and
    // db-push.sh (`[0-9][0-9][0-9]_*.sql`) apply these in filename order. A file
    // that sorts wrong is a migration applied at the wrong time.
    const sql = readdirSync(join(ROOT, "backend/prisma/sql"));
    expect(sql.filter((f) => !/^\d{3}_[a-z0-9_-]+\.sql$/.test(f))).toEqual([]);
    expect(sql.length).toBeGreaterThan(0);
  });
});
