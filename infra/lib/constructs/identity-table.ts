import * as cdk from 'aws-cdk-lib/core';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as kms from 'aws-cdk-lib/aws-kms';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface IdentityTableProps {
  readonly config: GoSteadyEnvConfig;
  /** Bare table name without env prefix (e.g. 'patients' → 'gosteady-dev-patients'). */
  readonly tableSuffix: string;
  /** PK attribute. */
  readonly partitionKey: dynamodb.Attribute;
  /** Optional SK attribute. */
  readonly sortKey?: dynamodb.Attribute;
  /** IdentityKey CMK from Phase 1.5 Security stack. */
  readonly identityKey: kms.IKey;
  /** Enable DDB Streams; required for Patients per Phase 0B revision L17. */
  readonly stream?: dynamodb.StreamViewType;
}

/**
 * Identity-bearing DynamoDB table — encrypted with the IdentityKey CMK
 * from Phase 1.5 Security stack.
 *
 * Phase 0B revision §Architecture / §Decisions D8: identity-bearing tables
 * (Organizations, Patients, Users, DeviceAssignments) get CMK encryption;
 * telemetry tables (Activity, Alerts, Devices) stay AWS-managed.
 *
 * Crypto-shred path: schedule-deleting the IdentityKey makes all
 * identity rows undecryptable in one operation.
 */
export class IdentityTable extends Construct {
  public readonly table: dynamodb.Table;

  constructor(scope: Construct, id: string, props: IdentityTableProps) {
    super(scope, id);

    const { config, tableSuffix, partitionKey, sortKey, identityKey, stream } = props;
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
      encryption: dynamodb.TableEncryption.CUSTOMER_MANAGED,
      encryptionKey: identityKey,
      stream,
      removalPolicy: isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });
  }
}
