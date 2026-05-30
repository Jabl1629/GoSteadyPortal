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
import * as logs from 'aws-cdk-lib/aws-logs';
import { ENVIRONMENTS, GoSteadyEnvConfig } from '../lib/config.js';
import { EnforceLogRetention } from '../lib/aspects/log-retention.js';
import { SecurityStack } from '../lib/stacks/security-stack.js';
import { AuthStack } from '../lib/stacks/auth-stack.js';
import { D2CAuthStack } from '../lib/stacks/d2c-auth-stack.js';
import { DataStack } from '../lib/stacks/data-stack.js';
import { IngestionStack } from '../lib/stacks/ingestion-stack.js';
import { ProcessingStack } from '../lib/stacks/processing-stack.js';
import { ApiStack } from '../lib/stacks/api-stack.js';
import { NotificationStack } from '../lib/stacks/notification-stack.js';
import { HostingStack } from '../lib/stacks/hosting-stack.js';
import { IntegrationStack } from '../lib/stacks/integration-stack.js';
import { ObservabilityStack } from '../lib/stacks/observability-stack.js';
import { AuditStack } from '../lib/stacks/audit-stack.js';

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

// D2C auth — separate Cognito pool for the consumer/household product
// (d2c.md L5). Reuses the facility AuthStack's RoleAssignments table
// (shared; tenancy boundary is clientId, not pool). Phase 1.
const d2cAuth = new D2CAuthStack(app, `${prefix}-D2C-Auth`, {
  env,
  config,
  authStack: auth,
  description: `GoSteady D2C Auth — ${config.envName}`,
});
d2cAuth.addDependency(auth); // reads the shared RoleAssignments table

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
  securityStack: security,
  description: `GoSteady Processing — ${config.envName}`,
});
processing.addDependency(security); // Phase 1B revision: handlers consume IdentityKey CMK
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
  securityStack: security,
  description: `GoSteady IoT Ingestion — ${config.envName}`,
});
ingestion.addDependency(processing);
ingestion.addDependency(security); // Phase 1A revision: OTA bucket consumes FirmwareKey CMK

const notification = new NotificationStack(app, `${prefix}-Notification`, {
  env,
  config,
  description: `GoSteady Notifications — ${config.envName}`,
});

const api = new ApiStack(app, `${prefix}-Api`, {
  env,
  config,
  authStack: auth,
  d2cAuthStack: d2cAuth,
  dataStack: data,
  securityStack: security,
  description: `GoSteady API — ${config.envName}`,
});
api.addDependency(auth);
api.addDependency(d2cAuth); // D2C Phase 1: second JWT authorizer on the D2C pool
api.addDependency(data);
api.addDependency(security); // Phase 2A-DL: device-api + discharge-cascade need IdentityKey + AuditKey CMK grants

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

// ── Log retention enforcement (Phase 1.6 Stage 4) ──────────────────
// Aspect-based defense in depth: every Logs::LogGroup that doesn't
// already have RetentionInDays set picks up the env-appropriate value.
// Existing explicit settings on Lambda log groups are left alone.
cdk.Aspects.of(app).add(
  new EnforceLogRetention({
    retention: config.prefix === 'prod' ? logs.RetentionDays.THREE_MONTHS : logs.RetentionDays.ONE_MONTH,
  }),
);

// ── Observability (Phase 1.6) ──────────────────────────────────────
// Wraps everything; no inbound CDK dependencies. Dashboards reference
// the upstream Lambda function names / IoT Rule names / DDB table names
// by string, so deploy order doesn't matter — Observability can deploy
// before, after, or in parallel with the other stacks.
new ObservabilityStack(app, `${prefix}-Observability`, {
  env,
  config,
  description: `GoSteady Observability — ${config.envName}`,
});

// ── Audit (Phase 1.7) ──────────────────────────────────────────────
// Routes audit-shape log entries from existing handler log groups into
// a dedicated CW log group, then onward via Firehose to an S3 bucket
// with Object Lock compliance retention (prod) or plain SSE-KMS (dev).
// Imports the AuditKey CMK from Security (Phase 1.5) by name; no other
// cross-stack imports. Subscription-filter sources are handler log
// groups referenced by name (mirrors the Observability decoupling).
const audit = new AuditStack(app, `${prefix}-Audit`, {
  env,
  config,
  description: `GoSteady Audit Logging — ${config.envName}`,
});
audit.addDependency(security); // depends on AuditKey CMK export
// Soft dep on Auth + Processing + Ingestion: the source handler log
// groups must exist before subscription filters can attach. CFN-level
// dependency isn't expressed (filters reference log groups by name),
// but ordering is enforced by deploy sequence: Auth + Processing +
// Ingestion are well-established before Audit ever deploys.

app.synth();
