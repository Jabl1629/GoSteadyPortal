#!/usr/bin/env node
/**
 * GoSteady CDK App — entry point.
 *
 * Wires all stacks together with their dependency chain:
 *
 *   Security ──→ (Auth, Data, Ingestion consume CMKs)
 *   Auth ──→ Data ──→ Ingestion ──→ Processing ──→ API ──→ Hosting
 *                                        ↓
 *                                  Notification ──→ Integration
 *
 * Deploy everything:       cdk deploy --all --context env=dev
 * Deploy a single stack:   cdk deploy GoSteady-Dev-Auth --context env=dev
 * Preview changes:         cdk diff --all --context env=dev
 */
import * as cdk from 'aws-cdk-lib/core';
import { ENVIRONMENTS, GoSteadyEnvConfig } from '../lib/config.js';
import { SecurityStack } from '../lib/stacks/security-stack.js';
import { AuthStack } from '../lib/stacks/auth-stack.js';
import { DataStack } from '../lib/stacks/data-stack.js';
import { IngestionStack } from '../lib/stacks/ingestion-stack.js';
import { ProcessingStack } from '../lib/stacks/processing-stack.js';
import { ApiStack } from '../lib/stacks/api-stack.js';
import { NotificationStack } from '../lib/stacks/notification-stack.js';
import { HostingStack } from '../lib/stacks/hosting-stack.js';
import { IntegrationStack } from '../lib/stacks/integration-stack.js';

const app = new cdk.App();

// ── Resolve environment ────────────────────────────────────────────
const envKey = app.node.tryGetContext('env') ?? 'dev';
const config: GoSteadyEnvConfig = ENVIRONMENTS[envKey];
if (!config) {
  throw new Error(
    `Unknown environment "${envKey}". Valid: ${Object.keys(ENVIRONMENTS).join(', ')}`,
  );
}

const env: cdk.Environment = {
  account: config.account,
  region: config.region,
};

const prefix = `GoSteady-${config.prefix.charAt(0).toUpperCase() + config.prefix.slice(1)}`;

// ── Stack instantiation (dependency order) ─────────────────────────

// Security stack deploys FIRST — creates CMKs referenced by Auth, Data, Ingestion.
const security = new SecurityStack(app, `${prefix}-Security`, {
  env,
  config,
  description: `GoSteady Security Foundation — ${config.envName}`,
});

const auth = new AuthStack(app, `${prefix}-Auth`, {
  env,
  config,
  securityStack: security,
  description: `GoSteady Auth — ${config.envName}`,
});
auth.addDependency(security);

const data = new DataStack(app, `${prefix}-Data`, {
  env,
  config,
  securityStack: security,
  description: `GoSteady Data Layer — ${config.envName}`,
});
data.addDependency(security);

const processing = new ProcessingStack(app, `${prefix}-Processing`, {
  env,
  config,
  dataStack: data,
  description: `GoSteady Processing — ${config.envName}`,
});
// Phase 0B revision (2026-04-27): Processing no longer cross-stack-imports
// Data tables (uses Table.fromTableName instead). Removing the explicit
// CDK dependency lets us deploy Processing without auto-deploying Data —
// important for breaking the import chain during PK-migration deploys.
// Runtime ordering still holds because Data tables exist in dev before
// Processing handlers ever fire (deployed sequence: Data → Processing →
// Ingestion).
// processing.addDependency(data);  // intentionally removed

const ingestion = new IngestionStack(app, `${prefix}-Ingestion`, {
  env,
  config,
  processingStack: processing,
  description: `GoSteady IoT Ingestion — ${config.envName}`,
});
ingestion.addDependency(processing);

const notification = new NotificationStack(app, `${prefix}-Notification`, {
  env,
  config,
  description: `GoSteady Notifications — ${config.envName}`,
});

const api = new ApiStack(app, `${prefix}-Api`, {
  env,
  config,
  authStack: auth,
  dataStack: data,
  description: `GoSteady API — ${config.envName}`,
});
api.addDependency(auth);
api.addDependency(data);

const hosting = new HostingStack(app, `${prefix}-Hosting`, {
  env,
  config,
  description: `GoSteady Hosting — ${config.envName}`,
});

const integration = new IntegrationStack(app, `${prefix}-Integration`, {
  env,
  config,
  dataStack: data,
  description: `GoSteady Integration — ${config.envName}`,
});
integration.addDependency(data);
integration.addDependency(notification);

app.synth();
