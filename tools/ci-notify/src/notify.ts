#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

type CliArgs = {
  summary: string;
  repo: string;
  runId: string;
  runAttempt: string;
  runUrl: string;
  workflow: string;
  matrix: string;
  issueTitle: string;
  labels: string[];
  dedupe: boolean;
  dryRun: boolean;
  requireToken: boolean;
  token?: string;
};

type Summary = {
  runCount: number;
  failures: number;
  raw: string;
};

const args = parseArgs(process.argv.slice(2));

if (args.help) {
  printUsage();
  process.exit(0);
}

const config = buildConfig(args);
let summary = parseSummarySafe(config.summary, {
  runId: config.runId,
  runUrl: config.runUrl,
  repo: config.repo,
});

if (summary.failures <= 0) {
  console.log("[ci-notify] no failures in summary, skip.");
  process.exit(0);
}

if (!config.token) {
  const message = "[ci-notify] GITHUB_TOKEN not found and no --token specified";
  if (config.requireToken) {
    console.error(message);
    process.exit(1);
  }
  console.warn(`${message}; dry output only`);
}

const [owner, repo] = config.repo.split("/");
if (!owner || !repo) {
  throw new Error("--repo format must be owner/repo");
}

const titleBase = config.issueTitle;
const issueBody = generateBody({
  workflow: config.workflow,
  matrix: config.matrix,
  summary: summary.raw,
  runId: config.runId,
  runAttempt: config.runAttempt,
  runUrl: config.runUrl,
  repo: config.repo,
});

if (config.dryRun || !config.token) {
  console.log("[ci-notify] dry-run: issue will not be posted");
  console.log(`title=${titleBase}`);
  console.log("body:\n" + issueBody);
  process.exit(0);
}

await runNotify({
  owner,
  repo,
  token: config.token,
  titleBase,
  labels: config.labels,
  body: issueBody,
  dedupe: config.dedupe,
});

function parseArgs(argv: string[]) {
  const parsed: Record<string, string | boolean> = { dryRun: false, dedupe: true, requireToken: false, matrix: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      parsed.help = true;
      continue;
    }
    if (arg === "--") {
      continue;
    }
    if (arg === "--dry-run" || arg === "--dedupe" || arg === "--no-dedupe" || arg === "--require-token") {
      if (arg === "--dry-run") parsed.dryRun = true;
      if (arg === "--require-token") parsed.requireToken = true;
      if (arg === "--dedupe") parsed.dedupe = true;
      if (arg === "--no-dedupe") parsed.dedupe = false;
      continue;
    }
    if (arg.startsWith("--")) {
      const key = arg.slice(2);
      const value = argv[i + 1];
      if (value === undefined || value.startsWith("--")) {
        throw new Error(`option ${arg} needs a value`);
      }
      parsed[toCamelKey(key)] = value;
      i += 1;
      continue;
    }
    throw new Error(`unknown arg: ${arg}`);
  }
  return parsed;
}

function toCamelKey(raw: string): string {
  return raw
    .split("-")
    .filter((part) => part.length > 0)
    .map((part, index) => {
      if (index === 0) return part;
      return `${part[0]?.toUpperCase()}${part.slice(1)}`;
    })
    .join("");
}

function buildConfig(args: Record<string, string | boolean>) {
  const repo = String(args.repo || process.env.GITHUB_REPOSITORY || "");
  if (!repo) {
    throw new Error("--repo is required");
  }
  const summary = resolveSummaryPath(
    String(args.summary || "compat-random-summary.md")
  );
  if (!args.summary) {
    console.warn(`[ci-notify] --summary missing, using default ${summary}`);
  }
  const server = process.env.GITHUB_SERVER_URL || "https://github.com";
  const workflow = String(args.workflow || process.env.GITHUB_WORKFLOW || "workflow");
  const runId = String(args.runId || process.env.GITHUB_RUN_ID || "local");
  const runAttempt = String(args.runAttempt || process.env.GITHUB_RUN_ATTEMPT || "1");
  const runUrl = String(
    args.runUrl || `${server}/${repo}/actions/runs/${runId}`
  );
  const matrix = String(args.matrix || "");
  const issueTitle = String(
    args.issueTitle || `${workflow} randomized compatibility failures`
  );
  const labelsRaw = String(args.labels || "");
  const labels = labelsRaw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const dedupe = Boolean(args.dedupe !== false);
  const dryRun = Boolean(args.dryRun);
  const requireToken = Boolean(args.requireToken);
  const token = typeof args.token === "string"
    ? String(args.token)
    : String(process.env.GITHUB_TOKEN || process.env.GH_TOKEN || "");

  return {
    summary,
    repo,
    runId,
    runAttempt,
    runUrl,
    workflow,
    matrix,
    issueTitle,
    labels,
    dedupe,
    dryRun,
    requireToken,
    token,
  } as CliArgs;
}

function resolveSummaryPath(raw: string): string {
  const normalized = raw || "compat-random-summary.md";
  const candidates: string[] = [path.resolve(process.cwd(), normalized)];
  const workspace = process.env.GITHUB_WORKSPACE;
  if (workspace) {
    candidates.unshift(path.resolve(workspace, normalized));
  }

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return candidates[0];
}

function parseSummary(path: string): Summary {
  const raw = fs.readFileSync(path, "utf8");
  if (raw.trim() === "") {
    throw new Error("summary file is empty");
  }
  const failureMatch = raw.match(/^fail(?:ure|ures):\s*([0-9]+)/im);
  const runCountMatch = raw.match(/^runs:\s*([0-9]+)/im);
  if (!failureMatch || !runCountMatch) {
    throw new Error("summary format mismatch: missing runs/failure fields");
  }
  const failures = Number.parseInt(failureMatch[1], 10);
  const runCount = Number.parseInt(runCountMatch[1], 10);
  return {
    raw,
    failures: Number.isFinite(failures) ? failures : 0,
    runCount: Number.isFinite(runCount) ? runCount : 0,
  };
}

function parseSummarySafe(path: string, context: {
  runId: string;
  runUrl: string;
  repo: string;
}): Summary {
  try {
    return parseSummary(path);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return {
      raw: formatSummaryParseFailure(path, msg, context),
      failures: 1,
      runCount: 0,
    };
  }
}

function formatSummaryParseFailure(
  path: string,
  reason: string,
  context: {
    runId: string;
    runUrl: string;
    repo: string;
  }
) {
  return [
    "# git-compat random aggregate",
    `result_dir: failed to read summary`,
    "files: 0",
    "runs: 0",
    "success: 0",
    "failure: 1",
    "success_rate: 0.00%",
    "duration_sum_sec: 0",
    "duration_avg_sec: 0",
    "duration_min_sec: 0",
    "duration_max_sec: 0",
    "",
    "## failures",
    "- summary parse failed",
    `- repository: ${context.repo}`,
    `- run_id: ${context.runId}`,
    `- run_url: ${context.runUrl}`,
    `- summary_path: ${path}`,
    `- reason: ${reason}`,
  ].join("\n");
}

function generateBody(args: {
  workflow: string;
  matrix: string;
  summary: string;
  runId: string;
  runAttempt: string;
  runUrl: string;
  repo: string;
}) {
  const matrixText = args.matrix ? ` (${args.matrix})` : "";
  const header = [
    `## ${args.workflow}${matrixText} の互換テストで失敗を検知しました`,
    `- ワークフロー実行: ${args.runUrl}`,
    `- リポジトリ: ${args.repo}`,
    `- run_id: ${args.runId}`,
    `- run_attempt: ${args.runAttempt}`,
    "",
    "### 集計",
    "```text",
  ];
  const footer = [
    "```",
    "",
    "再現に必要なseed情報やログは artifacts を確認してください。",
  ];
  return [
    ...header,
    args.summary.trim(),
    ...footer,
  ].join("\n");
}

async function runNotify(input: {
  owner: string;
  repo: string;
  token: string;
  titleBase: string;
  labels: string[];
  body: string;
  dedupe: boolean;
}) {
  const headers = {
    "Authorization": `Bearer ${input.token}`,
    "Accept": "application/vnd.github+json",
    "User-Agent": "ci-notify",
  };
  const title = input.dedupe
    ? `${input.titleBase}`
    : `${input.titleBase} (run #${process.env.GITHUB_RUN_ID || "local"})`;

  const apiBase = "https://api.github.com";

  if (input.dedupe) {
    const searchUrl = buildIssueSearchUrl({
      owner: input.owner,
      repo: input.repo,
      title,
    });
    const found = await findOpenIssueWithTitle(title, searchUrl, headers);
    if (found) {
      await addComment(
        `${apiBase}/repos/${input.owner}/${input.repo}/issues/${found}`,
        input.body,
        headers
      );
      console.log(`[ci-notify] appended to issue #${found}`);
      return;
    }
  }

  const created = await createIssue(
    `${apiBase}/repos/${input.owner}/${input.repo}/issues`,
    title,
    input.body,
    input.labels,
    headers
  );
  console.log(`[ci-notify] created issue #${created}`);
}

async function findOpenIssueWithTitle(
  title: string,
  searchUrl: string,
  headers: Record<string, string>,
) {
  const response = await fetch(searchUrl, {
    headers,
    method: "GET",
  });
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`search issues failed: ${response.status} ${body}`);
  }
  const data = await response.json() as { items: Array<{ number: number; title: string }> };
  const exact = data.items.find((item) => item.title === title);
  if (!exact) return null;
  return exact.number;
}

function buildIssueSearchUrl(input: {
  owner: string;
  repo: string;
  title: string;
}) {
  const query = new URLSearchParams({
    q: `repo:${input.owner}/${input.repo} is:issue is:open in:title "${input.title}"`,
  });
  return `https://api.github.com/search/issues?${query.toString()}`;
}

async function addComment(url: string, body: string, headers: Record<string, string>) {
  const response = await fetch(`${url}/comments`, {
    method: "POST",
    headers: {
      ...headers,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ body }),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`comment issue failed: ${response.status} ${text}`);
  }
}

async function createIssue(
  url: string,
  title: string,
  body: string,
  labels: string[],
  headers: Record<string, string>,
) {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      ...headers,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      title,
      body,
      labels,
    }),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`create issue failed: ${response.status} ${text}`);
  }
  const issue = await response.json() as { number: number };
  return issue.number;
}

function printUsage() {
  console.log(`Usage: pnpm run notify -- \
  --summary <path> \
  --repo <owner/repo> \
  --run-id <id> \
  [--run-attempt <n>] \
  [--run-url <url>] \
  [--workflow <name>] \
  [--matrix <name>] \
  [--issue-title <title>] \
  [--labels <a,b,c>] \
  [--token <token>] \
  [--dedupe] [--no-dedupe] [--dry-run] [--require-token]`
  );
}
