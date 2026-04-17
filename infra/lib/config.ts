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
  },
};
