import * as cdk from 'aws-cdk-lib/core';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface SnippetBucketProps {
  readonly config: GoSteadyEnvConfig;
}

/**
 * Snippet bucket — Phase 1A revision (L4 + D2).
 *
 * Holds opportunistic raw-IMU uploads from devices. Snippets are non-PHI
 * sensor data per ARCHITECTURE.md §9 encryption-tier table → AWS-managed
 * SSE is appropriate. CMK is reserved for identity-bearing or
 * compliance-evidence resources.
 *
 * Object key shape: {serial}/{date}/{snippet_id}.bin (full payload,
 * preamble + binary body — self-describing for offline analytics).
 *
 * Lifecycle:
 *   day 0..N1   → Standard
 *   day N1..N2  → Glacier Flexible Retrieval
 *   day N2+     → delete
 * (N1 = config.snippetGlacierTransitionDays; N2 = snippetTotalRetentionDays)
 */
export class SnippetBucket extends Construct {
  public readonly bucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: SnippetBucketProps) {
    super(scope, id);

    const { config } = props;
    const p = config.prefix;
    const isProd = p === 'prod';

    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: `gosteady-${p}-snippets`,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      removalPolicy: isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: !isProd,
      lifecycleRules: [
        {
          id: 'TransitionToGlacier',
          enabled: true,
          transitions: [
            {
              storageClass: s3.StorageClass.GLACIER,
              transitionAfter: cdk.Duration.days(config.snippetGlacierTransitionDays),
            },
          ],
          expiration: cdk.Duration.days(config.snippetTotalRetentionDays),
        },
      ],
    });
  }
}
