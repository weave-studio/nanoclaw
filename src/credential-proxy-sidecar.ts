/**
 * Sidecar proxy lifecycle management.
 * Runs the credential proxy as a Docker container on a shared network
 * so agent containers can reach it by name — solving the rootless Docker
 * network namespace isolation problem.
 */
import { execSync } from 'child_process';
import path from 'path';

import { CREDENTIAL_PROXY_PORT } from './config.js';
import {
  CONTAINER_RUNTIME_BIN,
  PROXY_CONTAINER_NAME,
  PROXY_NETWORK,
} from './container-runtime.js';
import { logger } from './logger.js';

/** Create the shared Docker network if it doesn't exist. */
export function ensureProxyNetwork(): void {
  try {
    execSync(
      `${CONTAINER_RUNTIME_BIN} network inspect ${PROXY_NETWORK}`,
      { stdio: 'pipe', timeout: 10000 },
    );
    logger.debug({ network: PROXY_NETWORK }, 'Proxy network already exists');
  } catch {
    execSync(
      `${CONTAINER_RUNTIME_BIN} network create ${PROXY_NETWORK}`,
      { stdio: 'pipe', timeout: 10000 },
    );
    logger.info({ network: PROXY_NETWORK }, 'Created proxy network');
  }
}

/** Start the credential proxy as a sidecar container. */
export function startProxySidecar(port: number = CREDENTIAL_PROXY_PORT): void {
  // Stop any existing proxy container (idempotent)
  try {
    execSync(
      `${CONTAINER_RUNTIME_BIN} rm -f ${PROXY_CONTAINER_NAME}`,
      { stdio: 'pipe', timeout: 10000 },
    );
  } catch {
    /* didn't exist */
  }

  const projectRoot = process.cwd();
  const distDir = path.join(projectRoot, 'dist');
  const nodeModules = path.join(projectRoot, 'node_modules');
  const envFile = path.join(projectRoot, '.env');

  const args = [
    'run', '-d',
    '--name', PROXY_CONTAINER_NAME,
    '--network', PROXY_NETWORK,
    '--restart', 'unless-stopped',
    // Mount compiled JS and dependencies (read-only)
    '-v', `${distDir}:/app/dist:ro`,
    '-v', `${nodeModules}:/app/node_modules:ro`,
    // Mount .env into /config/ so the standalone entry point can read it
    '-v', `${envFile}:/config/.env:ro`,
    // Pass the port
    '-e', `CREDENTIAL_PROXY_PORT=${port}`,
    // Use the same Node.js image the agent container is based on
    'node:22-slim',
    'node', '/app/dist/credential-proxy-standalone.js',
  ];

  const cmd = `${CONTAINER_RUNTIME_BIN} ${args.map((a) => `'${a}'`).join(' ')}`;
  logger.debug({ cmd }, 'Starting proxy sidecar');

  execSync(`${CONTAINER_RUNTIME_BIN} ${args.join(' ')}`, {
    stdio: 'pipe',
    timeout: 30000,
  });

  // Wait for it to be running
  for (let i = 0; i < 10; i++) {
    try {
      const state = execSync(
        `${CONTAINER_RUNTIME_BIN} inspect -f '{{.State.Running}}' ${PROXY_CONTAINER_NAME}`,
        { stdio: ['pipe', 'pipe', 'pipe'], encoding: 'utf-8', timeout: 5000 },
      ).trim();
      if (state === 'true') {
        logger.info(
          { container: PROXY_CONTAINER_NAME, port, network: PROXY_NETWORK },
          'Proxy sidecar started',
        );
        return;
      }
    } catch {
      /* not ready yet */
    }
    execSync('sleep 0.5', { stdio: 'pipe' });
  }

  // Check logs for diagnostics
  try {
    const logs = execSync(
      `${CONTAINER_RUNTIME_BIN} logs ${PROXY_CONTAINER_NAME}`,
      { stdio: ['pipe', 'pipe', 'pipe'], encoding: 'utf-8', timeout: 5000 },
    );
    logger.error({ logs }, 'Proxy sidecar failed to start');
  } catch {
    /* ignore */
  }

  throw new Error('Proxy sidecar failed to start within timeout');
}

/** Stop and remove the sidecar proxy container and network. */
export function stopProxySidecar(): void {
  try {
    execSync(
      `${CONTAINER_RUNTIME_BIN} rm -f ${PROXY_CONTAINER_NAME}`,
      { stdio: 'pipe', timeout: 10000 },
    );
    logger.info('Proxy sidecar stopped');
  } catch {
    /* already gone */
  }

  try {
    execSync(
      `${CONTAINER_RUNTIME_BIN} network rm ${PROXY_NETWORK}`,
      { stdio: 'pipe', timeout: 10000 },
    );
    logger.debug('Proxy network removed');
  } catch {
    /* in use or already gone */
  }
}
