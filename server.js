// Minimal HTTP server for Cloud Run that proxies request body to gcloud-mcp CLI bundle
const http = require('http');
const { spawn } = require('child_process');

const PORT = process.env.PORT || 8080;

const handler = async (req, res) => {
  // Normalize path (strip query, fragment, or accidental semicolon suffixes)
  const rawUrl = req.url || '/';
  const path = rawUrl.split(/[?#;]/)[0];

  // Health endpoint
  if (req.method === 'GET' && path === '/health') {
    res.statusCode = 200;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ status: 'ok', time: new Date().toISOString() }));
    return;
  }

  // Diagnostic endpoint: run `gcloud --version` to check runtime availability
  if (req.method === 'GET' && path === '/diag') {
    const child = spawn('gcloud', ['--version'], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c) => { stdout += c.toString(); });
    child.stderr.on('data', (c) => { stderr += c.toString(); });
    child.on('error', (err) => {
      res.statusCode = 500;
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ error: err.message, stderr }));
    });
    child.on('close', (code) => {
      if (code !== 0) {
        res.statusCode = 500;
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify({ code, stderr: stderr.trim(), stdout: stdout.trim() }));
        return;
      }
      res.statusCode = 200;
      res.setHeader('Content-Type', 'text/plain');
      res.end(stdout || '');
    });
    return;
  }

  let body = [];
  req.on('data', (chunk) => body.push(chunk));
  req.on('end', () => {
    body = Buffer.concat(body).toString() || '';

    console.log(`${new Date().toISOString()} ${req.method} ${rawUrl} - received body length=${body.length}`);

    // Try to interpret a simple JSON shape that directly maps to the run_gcloud_command
    // tool: { "tool": "run_gcloud_command", "input": { "args": ["compute", "instances", "list"] } }
    // If present, run `gcloud` directly with those args and return the result. This avoids
    // having to implement the full MCP stdio protocol in HTTP wrapper.
    let parsed = null;
    try {
      if (body) parsed = JSON.parse(body);
    } catch (e) {
      // Not JSON — fall back to MCP/stdio behavior below
      parsed = null;
    }

    if (parsed && parsed.tool === 'run_gcloud_command' && parsed.input && Array.isArray(parsed.input.args)) {
      console.log('[info] Detected direct run_gcloud_command request — executing gcloud directly');
      const gcloudArgs = parsed.input.args;

      const child = spawn('gcloud', gcloudArgs, { stdio: ['ignore', 'pipe', 'pipe'] });
      let stdout = '';
      let stderr = '';

      child.stdout.on('data', (c) => { stdout += c.toString(); });
      child.stderr.on('data', (c) => { stderr += c.toString(); });

      child.on('error', (err) => {
        console.error('gcloud child error', err);
        if (!res.headersSent) {
          res.statusCode = 500;
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify({ error: err.message, stderr }));
        }
      });

      child.on('close', (code) => {
        console.log(`gcloud exited code=${code}`);
        console.log('[gcloud captured stdout]', stdout ? stdout.replace(/\n+$/,'') : '<empty>');
        console.error('[gcloud captured stderr]', stderr ? stderr.replace(/\n+$/,'') : '<empty>');

        if (!res.headersSent) {
          if (code !== 0) {
            res.statusCode = 500;
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({ code, stderr: stderr.trim(), stdout: stdout.trim() }));
            return;
          }

          // If stdout is empty, return a helpful JSON diagnostic so callers can see stderr
          if (!stdout || stdout.trim().length === 0) {
            res.statusCode = 200;
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({ message: 'gcloud ran successfully but produced no stdout', stderr: stderr.trim() }));
            return;
          }

          // Try to parse stdout as JSON, else return plain text
          try {
            const parsedOut = JSON.parse(stdout);
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify(parsedOut));
          } catch (e) {
            res.setHeader('Content-Type', 'text/plain');
            res.end(stdout);
          }
        }
      });

      return;
    }

    // Default behaviour: spawn the gcloud-mcp CLI (via npx) and pipe the raw request body to it.
    console.log('[info] Spawning gcloud-mcp via npx');
    const child = spawn('npx', ['-y', '@google-cloud/gcloud-mcp'], { stdio: ['pipe', 'pipe', 'pipe'] });

    // Safety timeout for child
    const childTimeoutMs = parseInt(process.env.CHILD_TIMEOUT_MS || '25000', 10);
    const killer = setTimeout(() => {
      console.error(`Child exceeded timeout (${childTimeoutMs}ms). Killing.`);
      try { child.kill('SIGKILL'); } catch (e) {}
    }, childTimeoutMs);

    child.stdin.write(body);
    child.stdin.end();

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (c) => {
      const s = c.toString();
      stdout += s;
      // also mirror to container logs for debugging
      console.log('[child stdout]', s.replace(/\n+$/,''));
    });
    child.stderr.on('data', (c) => {
      const s = c.toString();
      stderr += s;
      console.error('[child stderr]', s.replace(/\n+$/,''));
    });

    child.on('error', (err) => {
      clearTimeout(killer);
      console.error('Child process error', err);
      if (!res.headersSent) {
        res.statusCode = 500;
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify({ error: err.message, stderr }));
      }
    });

    child.on('close', (code) => {
      clearTimeout(killer);
      console.log(`Child process exited with code=${code}`);
      console.log('[child captured stdout]', stdout);
      console.error('[child captured stderr]', stderr);

      if (!res.headersSent) {
        if (code !== 0) {
          res.statusCode = 500;
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify({ code, stderr: stderr.trim(), stdout: stdout.trim() }));
          return;
        }

        // Try to parse stdout as JSON
        try {
          const parsed = JSON.parse(stdout);
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify(parsed));
        } catch (e) {
          res.setHeader('Content-Type', 'text/plain');
          res.end(stdout);
        }
      }
    });
  });
};

const server = http.createServer(handler);
server.listen(PORT, () => {
  console.log(`Server listening on port ${PORT}`);
});
