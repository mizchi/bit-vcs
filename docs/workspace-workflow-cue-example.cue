package workspace

// bit workspace workflow DSL (CUE trial)
// CUE side focuses on validation and normalized schema.

#Duration: string & =~"^[0-9]+(ms|s|m|h)$"
#Backoff: "none" | "linear" | "exponential"
#TaskKind: "shell" | "playwright" | "cloudflare_workflows"
#FailPolicy: "fail_fast" | "continue_on_optional_failure"

#Node: {
	id:       string & !=""
	path:     string & !=""
	required: bool | *true
	dependsOn?: [...string]
}

#Task: {
	id:      string & !=""
	node:    string & !=""
	kind:    #TaskKind
	cmd:     [...string] & [string, ...string]
	needs?:  [...string]
	inputs?: [...string]
	outputs?: [...string]

	timeout:      #Duration | *"10m"
	retries:      int & >=0 & <=10 | *0
	retryBackoff: #Backoff | *"none"

	artifacts?: [...string]

	playwright?: {
		workers?: int & >=1 | *1
		project?: string
		trace?:   "off" | "on" | "retain-on-failure" | "on-first-retry"
	}

	cloudflare?: {
		workflowName:      string & !=""
		waitForCompletion: bool | *true
	}
}

#Entrypoint: {
	name:    string & !=""
	targets: [...string] & [string, ...string]
}

workflow: {
	version: int & >=1 & <=1
	name:    string & !=""

	maxParallel: int & >=1 | *4
	failPolicy:  #FailPolicy | *"fail_fast"

	cache: {
		enabled:   bool | *true
		namespace: string & !=""
	}

	nodes:      [...#Node] & [#Node, ...#Node]
	tasks:      [...#Task] & [#Task, ...#Task]
	entrypoint: #Entrypoint
}

workflow: {
	version: 1
	name:    "ci"
	maxParallel: 4
	failPolicy:  "fail_fast"

	cache: {
		enabled:   true
		namespace: "workspace-ci-v1"
	}

	nodes: [
		{
			id:       "root"
			path:     "."
			required: true
		},
		{
			id:       "dep"
			path:     "dep"
			required: true
			dependsOn: ["root"]
		},
		{
			id:       "leaf"
			path:     "leaf"
			required: true
			dependsOn: ["dep"]
		},
	]

	tasks: [
		{
			id:    "root:build"
			node:  "root"
			kind:  "shell"
			cmd:   ["pnpm", "build"]
			needs: []
			inputs: [
				"package.json",
				"pnpm-lock.yaml",
				"src/**",
			]
			outputs: ["dist/**"]
			timeout:      "20m"
			retries:      1
			retryBackoff: "linear"
			artifacts:    ["dist/**"]
		},
		{
			id:    "dep:test"
			node:  "dep"
			kind:  "playwright"
			cmd:   ["pnpm", "playwright", "test"]
			needs: ["root:build"]
			timeout:      "30m"
			retries:      2
			retryBackoff: "exponential"
			artifacts: [
				"playwright-report/**",
				"test-results/**",
			]
			playwright: {
				workers: 4
				project: "chromium"
				trace:   "retain-on-failure"
			}
		},
		{
			id:    "leaf:deploy"
			node:  "leaf"
			kind:  "cloudflare_workflows"
			cmd:   ["pnpm", "wrangler", "workflows", "trigger", "deploy"]
			needs: ["dep:test"]
			timeout:      "15m"
			retries:      3
			retryBackoff: "exponential"
			artifacts:    ["deploy-manifest.json"]
			cloudflare: {
				workflowName:      "deploy-pipeline"
				waitForCompletion: true
			}
		},
	]

	entrypoint: {
		name:    "default"
		targets: ["leaf:deploy"]
	}
}
