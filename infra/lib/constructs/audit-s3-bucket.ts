import * as cdk from 'aws-cdk-lib/core';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import { Construct } from 'constructs';

export interface AuditS3BucketProps {
  readonly env: string;
  /** AuditKey CMK from the Security stack — encrypts both data and the bucket key. */
  readonly auditKey: kms.IKey;
  /** Phase 1.7 L5: prod gets Object Lock compliance; dev gets neither (cleanable). */
  readonly objectLockEnabled: boolean;
  /** Retention window for Object Lock (years). Only honored when `objectLockEnabled`. */
  readonly objectLockYears: number;
  /** Standard → Glacier IR transition (days). */
  readonly glacierTransitionDays?: number;
}

/**
 * AuditS3Bucket — Phase 1.7.
 *
 * Audit cold path. Firehose delivers GZIP NDJSON into this bucket via the
 * subscription-filter-driven pipeline (handler log group → audit-forwarder →
 * dedicated audit log group → Firehose → this bucket).
 *
 * Env asymmetry per Phase 1.7 L5 (mirrors Phase 1.5 CloudTrail precedent):
 *   - dev: SSE-KMS with AuditKey, no Object Lock, RemovalPolicy.DESTROY (cleanable)
 *   - prod: SSE-KMS with AuditKey + Object Lock compliance mode (6yr default),
 *           explicit deny-delete bucket policy, RemovalPolicy.RETAIN
 *
 * The Object Lock setting is bucket-creation-time and irreversible. Don't
 * change the value of `objectLockEnabled` on an existing prod bucket.
 */
export class AuditS3Bucket extends Construct {
  public readonly bucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: AuditS3BucketProps) {
    super(scope, id);

    const isProdLike = props.objectLockEnabled;
    const glacierAfter = props.glacierTransitionDays ?? 90;

    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: `gosteady-${props.env}-audit-logs`,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: props.auditKey,
      bucketKeyEnabled: true,
      enforceSSL: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      // Versioning is required for Object Lock; harmless to enable in dev too
      // and means the dev bucket behaves more like prod for any test that
      // exercises versioning semantics.
      versioned: true,
      // Object Lock must be set at bucket creation. CDK exposes
      // `objectLockEnabled` (the bucket-level flag) + `objectLockDefaultRetention`
      // (the default mode + retention applied to every new object).
      objectLockEnabled: isProdLike,
      objectLockDefaultRetention: isProdLike
        ? s3.ObjectLockRetention.compliance(cdk.Duration.days(props.objectLockYears * 365))
        : undefined,
      removalPolicy: isProdLike ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: !isProdLike, // dev only — prod has Object Lock making this impossible anyway
      lifecycleRules: [
        {
          id: 'standard-to-glacier-ir',
          enabled: true,
          transitions: [
            {
              storageClass: s3.StorageClass.GLACIER_INSTANT_RETRIEVAL,
              transitionAfter: cdk.Duration.days(glacierAfter),
            },
          ],
        },
      ],
    });

    // Defense in depth on top of Object Lock — explicit deny on
    // DeleteObject for everyone in prod. Compliance mode already
    // prevents deletion until retention expires, but the explicit deny
    // makes the intent obvious at a `aws s3api get-bucket-policy` glance
    // and also covers the post-retention-expiry window.
    if (isProdLike) {
      this.bucket.addToResourcePolicy(
        new iam.PolicyStatement({
          sid: 'DenyAllObjectDeletes',
          effect: iam.Effect.DENY,
          principals: [new iam.StarPrincipal()],
          actions: ['s3:DeleteObject', 's3:DeleteObjectVersion'],
          resources: [this.bucket.arnForObjects('*')],
        }),
      );
    }
  }
}
