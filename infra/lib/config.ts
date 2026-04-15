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
  },
};
