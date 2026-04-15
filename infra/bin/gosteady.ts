#!/usr/bin/env node
/**
 * GoSteady CDK App — entry point.
 *
 * Wires all stacks together with their dependency chain:
 *
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

const auth = new AuthStack(app, `${prefix}-Auth`, {
  env,
  config,
  description: `GoSteady Auth — ${config.envName}`,
});

const data = new DataStack(app, `${prefix}-Data`, {
  env,
  config,
  description: `GoSteady Data Layer — ${config.envName}`,
});

const ingestion = new IngestionStack(app, `${prefix}-Ingestion`, {
  env,
  config,
  description: `GoSteady IoT Ingestion — ${config.envName}`,
});

const processing = new ProcessingStack(app, `${prefix}-Processing`, {
  env,
  config,
  dataStack: data,
  description: `GoSteady Processing — ${config.envName}`,
});
processing.addDependency(data);
processing.addDependency(ingestion);

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
