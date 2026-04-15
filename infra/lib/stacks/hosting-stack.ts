import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface HostingStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
}

/**
 * Hosting & Deployment — S3 + CloudFront for the Flutter web portal.
 *
 * Phase 3A will implement:
 *   - S3 bucket (private, no public access)
 *       Stores Flutter web build output (build/web/)
 *       Versioning enabled for rollback
 *
 *   - CloudFront distribution
 *       Origin: S3 via OAI (Origin Access Identity)
 *       Custom domain: portal.gosteady.co (prod) or CF default (dev)
 *       ACM certificate (us-east-1, required for CloudFront)
 *       SPA routing: custom error response → /index.html for 403/404
 *       Cache: 24h for static assets, 5m for index.html
 *
 *   - GitHub Actions CI/CD (in .github/workflows/)
 *       Trigger: push to main, path filter on lib/**
 *       Steps: flutter build web --release → aws s3 sync → CF invalidation
 */
export class HostingStack extends cdk.Stack {
  // Public properties will be added:
  // public readonly siteBucket: s3.Bucket;
  // public readonly distribution: cloudfront.Distribution;

  constructor(scope: Construct, id: string, props: HostingStackProps) {
    super(scope, id, props);

    const { config } = props;
    const p = config.prefix;

    // ── Phase 3A: S3 + CloudFront ────────────────────────────────
    // TODO: S3 bucket (private, versioned)
    // TODO: CloudFront OAI
    // TODO: CloudFront distribution (SPA error routing)
    // TODO: ACM certificate (if portalDomain configured)
    // TODO: Route53 alias record (if portalDomain configured)

    new cdk.CfnOutput(this, 'Status', {
      value: 'SCAFFOLD — Phase 3A pending',
    });
  }
}
