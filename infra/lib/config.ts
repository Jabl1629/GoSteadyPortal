/**
 * GoSteady environment configuration.
 *
 * Usage:
 *   const env = ENVIRONMENTS[app.node.tryGetContext('env') ?? 'dev'];
 *
 * Deploy:
 *   cdk deploy --context env=dev
 *   cdk deploy --context env=prod
 */

export interface GoSteadyEnvConfig {
  /** Friendly name shown in stack descriptions. */
  readonly envName: string;
  /** Short prefix for resource naming (e.g. 'dev', 'prod'). */
  readonly prefix: string;
  /** AWS account ID. */
  readonly account: string;
  /** AWS region. */
  readonly region: string;
  /** Whether to enable DynamoDB point-in-time recovery. */
  readonly pitrEnabled: boolean;
  /** DynamoDB billing mode — PAY_PER_REQUEST for dev, PROVISIONED for prod. */
  readonly dynamoBillingMode: 'PAY_PER_REQUEST' | 'PROVISIONED';
  /** CloudFront custom domain (null = use default CF domain). */
  readonly portalDomain?: string;
  /** Whether to enable detailed CloudWatch alarms. */
  readonly alarmsEnabled: boolean;
  /**
   * Whether to enable KMS Customer-Managed Keys (Phase 1.5).
   * When true: identity-bearing tables and S3 OTA bucket use CMKs.
   * When false: all resources use AWS-managed keys (local testing only).
   */
  readonly kmsCmkEnabled: boolean;
  /**
   * Whether to enable CloudTrail (Phase 1.5).
   * When false: no CloudTrail created (local testing only — always true in real envs).
   */
  readonly cloudTrailEnabled: boolean;
  /**
   * Whether to enable S3 Object Lock on the CloudTrail log bucket.
   * Prod only — compliance mode makes the bucket non-destroyable.
   */
  readonly cloudTrailObjectLockEnabled: boolean;
  /**
   * Monthly AWS estimated-charges threshold that triggers the billing alarm (USD).
   * Requires "Receive Billing Alerts" enabled account-wide in Billing Console.
   */
  readonly costAlarmThresholdUsd: number;
  /**
   * Email address subscribed to the cost-alarm SNS topic.
   * If not set, the topic is created but no subscription is attached (attach manually).
   */
  readonly costAlarmEmail?: string;
  /**
   * Customer-tier (Portal-Customer App Client) idle access-token validity in minutes.
   * Phase 0A revision L7 / Phase 1.5 L7 — 15 min for healthcare-norm session timeout.
   */
  readonly customerTokenIdleMinutes: number;
  /**
   * Customer-tier refresh-token validity in days.
   * Phase 0A revision — 30 days, matches original Phase 0A.
   */
  readonly customerRefreshDays: number;
  /**
   * Internal-tier (Portal-Internal App Client) idle access-token validity in minutes.
   * Phase 0A revision L8 / Phase 1.5 L8 — 30 min for tighter blast-radius cap.
   */
  readonly internalTokenIdleMinutes: number;
  /**
   * Internal-tier absolute session lifetime in minutes (refresh-token validity).
   * Phase 0A revision L8 — 4 hr (240 min).
   */
  readonly internalTokenAbsoluteMinutes: number;
  /**
   * Optional callback URL for the Portal-Internal App Client (internal admin tool).
   * Defaults to localhost:8090 in dev when unset.
   */
  readonly internalCallbackUrl?: string;
  /**
   * Snippet bucket Standard → Glacier transition (Phase 1A revision L4).
   */
  readonly snippetGlacierTransitionDays: number;
  /**
   * Snippet bucket total retention before delete (~13 months, aligned with
   * v1.5 algorithm-retrain horizon — Phase 1A revision L4).
   */
  readonly snippetTotalRetentionDays: number;
  /**
   * SnippetParser Lambda memory (Phase 1A revision §Configuration).
   */
  readonly snippetParserMemoryMb: number;
  /**
   * SnippetParser Lambda timeout (Phase 1A revision §Configuration).
   */
  readonly snippetParserTimeoutSeconds: number;
  /**
   * Activity / threshold-detector / alert-handler memory (Phase 1B revision §Configuration).
   */
  readonly processingLambdaMemoryMb: number;
  /**
   * Heartbeat-processor memory — slimmed handler, less memory needed (Phase 1B revision).
   */
  readonly processingHeartbeatMemoryMb: number;
  /**
   * Common timeout for processing handlers (Phase 1B revision).
   */
  readonly processingLambdaTimeoutSeconds: number;
  /**
   * Activation-ack `last_cmd_id` matching window in hours (DL14a / firmware coord §F.2).
   */
  readonly activationAckWindowHours: number;
  /**
   * Pre-activation audit log sampling cadence in hours per serial (Phase 1B revision L8).
   */
  readonly preActivationAuditSampleHours: number;
  /**
   * AWS-managed Powertools for AWS Lambda (Python) V3 layer ARN (Phase 1.6).
   * Pinned per env so version drift is explicit. ARM64 / Python 3.12.
   * Cross-account-readable (AWS-managed); same ARN works in prod when the
   * separate prod account exists.
   */
  readonly powertoolsLayerArn: string;
  /**
   * Whether to deploy AWS Cost Anomaly Detection (Phase 1.6 §Architecture).
   * **Requires Cost Explorer to be enabled at the account level FIRST** —
   * one-time click in the AWS Console (Billing & Cost Management → Cost
   * Explorer → Enable). The CFN `AWS::CE::AnomalyMonitor` resource cannot
   * enable it programmatically; deploying without it returns
   * `User not enabled for cost explorer access` and rolls back the stack.
   *
   * Default false in dev (manual opt-in pending). When ready: enable Cost
   * Explorer in console, flip this to true, redeploy Observability stack.
   */
  readonly costAnomalyEnabled: boolean;
  /**
   * Whether to enable S3 Object Lock (compliance mode) on the audit-logs
   * bucket (Phase 1.7 L5). Prod-only; dev gets normal SSE-KMS so test
   * data churn is cleanable. Object Lock must be set at bucket-create
   * time and is irreversible.
   */
  readonly auditBucketObjectLockEnabled: boolean;
  /**
   * S3 Object Lock retention in years for audit objects (Phase 1.7 L3).
   * Only applied when `auditBucketObjectLockEnabled` is true.
   */
  readonly auditBucketObjectLockYears: number;
  /**
   * Audit CloudWatch Log Group hot-path retention in days (Phase 1.7 L4 hot side;
   * ARCHITECTURE.md §11 retention table). S3 is the cold path; this is the
   * window Logs Insights queries cover for compliance/ops triage.
   */
  readonly auditHotRetentionDays: number;
  /**
   * API Gateway HTTP API throttling — burst requests per second (Phase 2A-0).
   */
  readonly apiThrottleBurst: number;
  /**
   * API Gateway HTTP API throttling — sustained requests per second (Phase 2A-0).
   */
  readonly apiThrottleRate: number;
  /**
   * WAF rate-limit rule: requests per 5 min window per source IP (Phase 2A-0).
   */
  readonly apiWafRateLimitPerIp: number;
  /**
   * API Gateway p99 latency alarm threshold (ms) — Phase 2A-0.
   */
  readonly apiLatencyP99AlarmMs: number;
  /**
   * patient-api Lambda memory (Phase 2A-RD).
   * Higher than device-api in prod due to BatchGetItem fan-out latency
   * sensitivity (Organizations name resolution).
   */
  readonly patientApiMemoryMb: number;
  /**
   * patient-api Lambda timeout (Phase 2A-RD). Same in dev/prod;
   * pagination keeps per-call work bounded.
   */
  readonly patientApiTimeoutSeconds: number;
  /**
   * alert-actions Lambda memory (Phase 2A-AA). Single-row UpdateItem
   * paths; 256 MB sufficient.
   */
  readonly alertActionsMemoryMb: number;
  /**
   * alert-actions Lambda timeout (Phase 2A-AA).
   */
  readonly alertActionsTimeoutSeconds: number;
}

/**
 * Fill in your AWS account IDs before first deploy.
 * Region us-east-1 is required for IoT Core + CloudFront certs.
 */
export const ENVIRONMENTS: Record<string, GoSteadyEnvConfig> = {
  dev: {
    envName: 'Development',
    prefix: 'dev',
    account: '460223323193',
    region: 'us-east-1',
    pitrEnabled: false,
    dynamoBillingMode: 'PAY_PER_REQUEST',
    alarmsEnabled: false,
    kmsCmkEnabled: true,
    cloudTrailEnabled: true,
    cloudTrailObjectLockEnabled: false, // compliance-mode lock makes bucket non-destroyable; prod only
    costAlarmThresholdUsd: 100,
    costAlarmEmail: process.env.GOSTEADY_COST_ALARM_EMAIL,
    customerTokenIdleMinutes: 15,
    customerRefreshDays: 30,
    internalTokenIdleMinutes: 30,
    internalTokenAbsoluteMinutes: 240,
    internalCallbackUrl: 'http://localhost:8090/callback',
    snippetGlacierTransitionDays: 90,
    snippetTotalRetentionDays: 395,
    snippetParserMemoryMb: 256,
    snippetParserTimeoutSeconds: 30,
    processingLambdaMemoryMb: 256,
    processingHeartbeatMemoryMb: 128,
    processingLambdaTimeoutSeconds: 30,
    activationAckWindowHours: 24,
    preActivationAuditSampleHours: 1,
    // Powertools 3.28.0 published 2026-04-14 (latest as of 2026-04-29 spec deploy).
    // Bump the version number when upgrading; AWS publishes monthly.
    powertoolsLayerArn:
      'arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:32',
    // Cost Explorer not enabled in this dev account at deploy time
    // (2026-04-29). Flip to true after the one-time console opt-in.
    costAnomalyEnabled: false,
    // Phase 1.7 L5: Object Lock prod-only — irreversible bucket-level
    // setting; dev must remain cleanable for test data churn.
    auditBucketObjectLockEnabled: false,
    auditBucketObjectLockYears: 6,
    auditHotRetentionDays: 90,
    // Phase 2A-0 (2026-05-17) — API foundation throttling + WAF tuning.
    apiThrottleBurst: 50,
    apiThrottleRate: 25,
    apiWafRateLimitPerIp: 2000,
    apiLatencyP99AlarmMs: 2000,
    // Phase 2A-RD (2026-05-23) — patient-api defaults.
    patientApiMemoryMb: 256,
    patientApiTimeoutSeconds: 10,
    // Phase 2A-AA (2026-05-23) — alert-actions defaults.
    alertActionsMemoryMb: 256,
    alertActionsTimeoutSeconds: 10,
  },
  prod: {
    envName: 'Production',
    prefix: 'prod',
    account: '460223323193',
    region: 'us-east-1',
    pitrEnabled: true,
    dynamoBillingMode: 'PAY_PER_REQUEST', // switch to PROVISIONED when usage patterns are clear
    portalDomain: 'portal.gosteady.co',
    alarmsEnabled: true,
    kmsCmkEnabled: true,
    cloudTrailEnabled: true,
    cloudTrailObjectLockEnabled: true,
    costAlarmThresholdUsd: 500,
    costAlarmEmail: process.env.GOSTEADY_COST_ALARM_EMAIL,
    customerTokenIdleMinutes: 15,
    customerRefreshDays: 30,
    internalTokenIdleMinutes: 30,
    internalTokenAbsoluteMinutes: 240,
    // internalCallbackUrl: 'https://internal.gosteady.co/callback',  // set when internal tool is hosted
    snippetGlacierTransitionDays: 90,
    snippetTotalRetentionDays: 395,
    snippetParserMemoryMb: 256,
    snippetParserTimeoutSeconds: 30,
    processingLambdaMemoryMb: 256,
    processingHeartbeatMemoryMb: 128,
    processingLambdaTimeoutSeconds: 30,
    activationAckWindowHours: 24,
    preActivationAuditSampleHours: 1,
    // Same AWS-managed layer is cross-account-readable; pin matches dev for now.
    // When prod migrates to its own AWS account, verify cross-account access on
    // first deploy (Phase 1.6 Open Question Q1).
    powertoolsLayerArn:
      'arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:32',
    // Cost Explorer not enabled in this dev account at deploy time
    // (2026-04-29). Flip to true after the one-time console opt-in.
    costAnomalyEnabled: false,
    // Phase 1.7 L5: prod gets Object Lock compliance mode, 6yr retention.
    // Bucket becomes non-destroyable until all object retention windows
    // expire. Tamper-evident audit storage is the entire point.
    auditBucketObjectLockEnabled: true,
    auditBucketObjectLockYears: 6,
    auditHotRetentionDays: 90,
    // Phase 2A-0 (2026-05-17) — prod gets higher throttling ceiling +
    // tighter latency alarm; rate-limit unchanged at MVP.
    apiThrottleBurst: 200,
    apiThrottleRate: 100,
    apiWafRateLimitPerIp: 2000,
    apiLatencyP99AlarmMs: 1000,
    // Phase 2A-RD (2026-05-23) — patient-api memory higher in prod for
    // Organizations BatchGetItem fan-out latency.
    patientApiMemoryMb: 512,
    patientApiTimeoutSeconds: 10,
    // Phase 2A-AA (2026-05-23) — same in dev + prod (single-row paths).
    alertActionsMemoryMb: 256,
    alertActionsTimeoutSeconds: 10,
  },
};
