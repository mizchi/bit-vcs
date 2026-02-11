# bit workspace workflow DSL (Starlark trial)
#
# This file is intentionally data-oriented:
# - no filesystem or network I/O
# - no loops required for the common case
# - compile target is a workspace execution IR

workflow(
    name = "ci",
    version = 1,
    max_parallel = 4,
    fail_policy = "fail_fast",
    cache = {
        "enabled": True,
        "namespace": "workspace-ci-v1",
    },
)

node(
    id = "root",
    path = ".",
    required = True,
)

node(
    id = "dep",
    path = "dep",
    required = True,
    depends_on = ["root"],
)

node(
    id = "leaf",
    path = "leaf",
    required = True,
    depends_on = ["dep"],
)

task(
    id = "root:build",
    node = "root",
    kind = "shell",
    cmd = ["pnpm", "build"],
    needs = [],
    inputs = [
        "package.json",
        "pnpm-lock.yaml",
        "src/**",
    ],
    outputs = ["dist/**"],
    timeout = "20m",
    retries = 1,
    retry_backoff = "linear",
    artifacts = ["dist/**"],
)

task(
    id = "dep:test",
    node = "dep",
    kind = "playwright",
    cmd = ["pnpm", "playwright", "test"],
    needs = ["root:build"],
    timeout = "30m",
    retries = 2,
    retry_backoff = "exponential",
    playwright = {
        "workers": 4,
        "project": "chromium",
        "trace": "retain-on-failure",
    },
    artifacts = [
        "playwright-report/**",
        "test-results/**",
    ],
)

task(
    id = "leaf:deploy",
    node = "leaf",
    kind = "cloudflare_workflows",
    cmd = ["pnpm", "wrangler", "workflows", "trigger", "deploy"],
    needs = ["dep:test"],
    timeout = "15m",
    retries = 3,
    retry_backoff = "exponential",
    artifacts = ["deploy-manifest.json"],
    cloudflare = {
        "workflow_name": "deploy-pipeline",
        "wait_for_completion": True,
    },
)

entrypoint(
    name = "default",
    targets = ["leaf:deploy"],
)
