#!/usr/bin/env node
// Simple Git Smart HTTP server for testing git-shim
// Usage: node http-test-server.js <repo-path> [port]

import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const repoPath = process.argv[2] || '.';
const port = parseInt(process.argv[3] || '8080', 10);

// Use git-shim if available
const gitShim = path.join(__dirname, 'git-shim', 'bin', 'git');
const gitCmd = process.env.USE_REAL_GIT ? 'git' : gitShim;

function runGitCommand(args, input, callback) {
  const absRepoPath = path.resolve(repoPath);
  const proc = spawn(gitCmd, args, {
    cwd: absRepoPath,
    env: {
      ...process.env,
      GIT_DIR: path.join(absRepoPath, '.git'),
      SHIM_CMDS: 'pack-objects index-pack upload-pack receive-pack',
      SHIM_STRICT: '1',
    },
  });

  let stdout = Buffer.alloc(0);
  let stderr = '';

  proc.stdout.on('data', (data) => {
    stdout = Buffer.concat([stdout, data]);
  });

  proc.stderr.on('data', (data) => {
    stderr += data.toString();
  });

  proc.on('close', (code) => {
    callback(code, stdout, stderr);
  });

  if (input) {
    proc.stdin.write(input);
    proc.stdin.end();
  } else {
    proc.stdin.end();
  }
}

function handleInfoRefs(req, res, service) {
  // Convert git-upload-pack -> upload-pack (subcommand form)
  const cmd = service.replace('git-', '');
  // Use absolute path for repository
  const absRepoPath = path.resolve(repoPath);
  const args = [cmd, '--advertise-refs', '--stateless-rpc', absRepoPath];

  runGitCommand(args, null, (code, stdout, stderr) => {
    if (code !== 0) {
      console.error(`[ERROR] ${service} --advertise-refs failed:`, stderr);
      res.writeHead(500);
      res.end('Internal Server Error');
      return;
    }

    // Build smart HTTP response
    const serviceLine = `# service=${service}\n`;
    const pktLen = (4 + serviceLine.length).toString(16).padStart(4, '0');
    const header = Buffer.from(pktLen + serviceLine + '0000');
    const body = Buffer.concat([header, stdout]);

    res.writeHead(200, {
      'Content-Type': `application/x-${service}-advertisement`,
      'Cache-Control': 'no-cache',
    });
    res.end(body);
    console.log(`[INFO] ${service} --advertise-refs OK (${body.length} bytes)`);
  });
}

function handleService(req, res, service) {
  const chunks = [];

  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const input = Buffer.concat(chunks);
    // service is already in subcommand form (upload-pack or receive-pack)
    const absRepoPath = path.resolve(repoPath);
    const args = [service, '--stateless-rpc', absRepoPath];

    console.log(`[INFO] ${service} request: ${input.length} bytes`);

    runGitCommand(args, input, (code, stdout, stderr) => {
      if (stderr) {
        console.error(`[STDERR] ${service}:`, stderr);
      }
      if (code !== 0) {
        console.error(`[ERROR] ${service} failed with code ${code}`);
      }

      res.writeHead(200, {
        'Content-Type': `application/x-${service}-result`,
        'Cache-Control': 'no-cache',
      });
      res.end(stdout);
      console.log(`[INFO] ${service} response: ${stdout.length} bytes`);
    });
  });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${port}`);
  console.log(`[REQ] ${req.method} ${req.url}`);

  // /info/refs?service=git-upload-pack or git-receive-pack
  if (url.pathname === '/info/refs') {
    const service = url.searchParams.get('service');
    if (service === 'git-upload-pack' || service === 'git-receive-pack') {
      return handleInfoRefs(req, res, service);
    }
  }

  // /git-upload-pack
  if (url.pathname === '/git-upload-pack' && req.method === 'POST') {
    return handleService(req, res, 'upload-pack');
  }

  // /git-receive-pack
  if (url.pathname === '/git-receive-pack' && req.method === 'POST') {
    return handleService(req, res, 'receive-pack');
  }

  res.writeHead(404);
  res.end('Not Found');
});

server.listen(port, () => {
  console.log(`Git HTTP server started on http://localhost:${port}`);
  console.log(`Repository: ${path.resolve(repoPath)}`);
  console.log(`Git command: ${gitCmd}`);
  console.log('');
  console.log('Test with:');
  console.log(`  git clone http://localhost:${port} /tmp/test-clone`);
  console.log(`  git -C /tmp/test-clone fetch`);
  console.log('');
  console.log('Press Ctrl+C to stop');
});
