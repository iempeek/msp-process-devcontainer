#!/usr/bin/env node
// .devcontainer/frontend/tcp-relay.mjs
//
// Minimal TCP forwarder (no dependencies) used on both sides of the
// frontend<->backend gap: the frontend/vite dev servers and the backend
// dotnet hosts are baked to talk to each other over http://localhost:<port>,
// but they run in different containers (frontend sidecar vs devcontainer).
// This relay makes "localhost:<port>" resolve to the real upstream wherever
// it's run - see infra-up.sh (the only caller left: soketi -> localhost:6001)
// (frontend-ward direction) for the two invocations.
//
// Usage: node tcp-relay.mjs <listenPort>:<upstreamHost>:<upstreamPort> ...
//
// Each arg opens one listener on 0.0.0.0:<listenPort> that pipes bytes to
// <upstreamHost>:<upstreamPort>. A refused/dropped upstream connection only
// tears down that one client socket - the listener itself never stops.

import net from 'node:net';

const specs = process.argv.slice(2).map((arg) => {
  const match = /^(\d+):([^:]+):(\d+)$/.exec(arg);
  if (!match) {
    throw new Error(`tcp-relay: bad spec "${arg}", expected <listenPort>:<upstreamHost>:<upstreamPort>`);
  }
  const [, listenPort, upstreamHost, upstreamPort] = match;
  return { listenPort: Number(listenPort), upstreamHost, upstreamPort: Number(upstreamPort) };
});

if (specs.length === 0) {
  console.error('tcp-relay: no forwarding specs given, nothing to do.');
  process.exit(1);
}

for (const { listenPort, upstreamHost, upstreamPort } of specs) {
  const server = net.createServer((client) => {
    const upstream = net.connect(upstreamPort, upstreamHost);
    client.pipe(upstream);
    upstream.pipe(client);
    // Either side erroring/closing should only tear down this one pair of
    // sockets, never the listener - a refused upstream must not kill the relay.
    const cleanup = () => {
      client.destroy();
      upstream.destroy();
    };
    client.on('error', cleanup);
    upstream.on('error', cleanup);
  });

  server.on('error', (err) => {
    console.error(`tcp-relay: listener :${listenPort} -> ${upstreamHost}:${upstreamPort} failed: ${err.message}`);
  });

  server.listen(listenPort, '0.0.0.0', () => {
    console.log(`tcp-relay: :${listenPort} -> ${upstreamHost}:${upstreamPort}`);
  });
}
