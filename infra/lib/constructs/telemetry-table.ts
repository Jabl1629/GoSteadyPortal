import * as cdk from 'aws-cdk-lib/core';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface TelemetryTableProps {
  readonly config: GoSteadyEnvConfig;
  /** Bare table name without env prefix (e.g. 'activity' → 'gosteady-dev-activity'). */
  readonly tableSuffix: string;
  /** PK attribute. */
  readonly partitionKey: dynamodb.Attribute;
  /** Optional SK attribute. */
  readonly sortKey?: dynamodb.Attribute;
  /**
   * Optional TTL attribute name; per Phase 0B revision D2/D16, set to
   * `expiresAt` (epoch seconds) on Activity (13 mo) and Alert (24 mo).
   * The writer Lambda computes the value at ingest time.
   */
  readonly ttlAttribute?: string;
}

/**
 * Telemetry-volume DynamoDB table — AWS-managed encryption (per Phase 0B
 * revision D8 cost-vs-value rationale).
 *
 * Telemetry tables (Activity, Alerts, Device Registry) stay AWS-managed
 * because:
 *   - Higher KMS API call volume than identity tables; per-call KMS cost
 *     would meaningfully add up at scale.
 *   - Crypto-shred works through the foreign-key route: deleting the
 *     IdentityKey orphans patientId / clientId references on telemetry
 *     rows, making them effectively unjoinable.
 */
export class TelemetryTable extends Construct {
  public readonly table: dynamodb.Table;

  constructor(scope: Construct, id: string, props: TelemetryTableProps) {
    super(scope, id);

    const { config, tableSuffix, partitionKey, sortKey, ttlAttribute } = props;
    const p = config.prefix;
    const isProd = p === 'prod';

    this.table = new dynamodb.Table(this, 'Table', {
      tableName: `gosteady-${p}-${tableSuffix}`,
      partitionKey,
      sortKey,
      billingMode:
        config.dynamoBillingMode === 'PAY_PER_REQUEST'
          ? dynamodb.BillingMode.PAY_PER_REQUEST
          : dynamodb.BillingMode.PROVISIONED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: config.pitrEnabled },
      encryption: dynamodb.TableEncryption.AWS_MANAGED,
      timeToLiveAttribute: ttlAttribute,
      removalPolicy: isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });
  }
}
