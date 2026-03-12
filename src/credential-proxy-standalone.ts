/**
 * Standalone entry point for the credential proxy sidecar container.
 * Adapts the environment so the existing credential-proxy.ts works
 * when running inside a Docker container with .env mounted at /config/.env.
 */
import { startCredentialProxy } from './credential-proxy.js';

// The sidecar mounts the host .env at /config/.env.
// readEnvFile() reads from process.cwd()/.env, so chdir to /config.
process.chdir('/config');

const port = parseInt(process.env.CREDENTIAL_PROXY_PORT || '3001', 10);

const server = await startCredentialProxy(port, '0.0.0.0');

const shutdown = () => {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000);
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
