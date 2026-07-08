import * as cdk from 'aws-cdk-lib/core';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as wafv2 from 'aws-cdk-lib/aws-wafv2';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface HostingStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  /**
   * Logical site id used in physical resource names + CFN exports
   * (`gosteady-<prefix>-<siteKey>-*`). Defaults to 'portal' (facility
   * portal). The DT-4 live D2C consumer app uses 'd2c-app'.
   */
  readonly siteKey?: string;
  /**
   * Custom domain for this site. Defaults to `config.portalDomain` (facility
   * portal) for back-compat; the D2C app passes `config.d2cAppDomain`.
   */
  readonly domain?: string;
}

/**
 * Hosting & Deployment — S3 + CloudFront for the Flutter web portal.
 *
 * Phase 2B-0 (2026-05-24): populated with the minimum-viable hosting
 * tier (this stack). Phase 3A adds production polish — tightened WAF
 * (IP reputation list, prod-rate-limit tuning), CSP / security-headers
 * policy, CloudFront access logging + observability dashboards,
 * multi-region considerations.
 *
 * Resources created when `config.portalDomain` is set (currently:
 * dev + prod):
 *
 *   - S3 bucket: private, OAC-only, versioned, SSE-S3
 *   - CloudFront distribution:
 *       - Origin Access Control (OAC) for S3 (not OAI)
 *       - Default root object: index.html
 *       - SPA 404/403 → index.html rewrite (200) — deep-link survives reload
 *       - HTTPS only (redirect HTTP)
 *       - PriceClass_100 (US/CA/EU only)
 *   - ACM certificate (us-east-1, DNS-validated against Squarespace DNS)
 *   - WAF v2 web ACL: AWSManagedRulesCommonRuleSet + per-IP rate limit
 *       (AWSManagedRulesAmazonIpReputationList deferred to 3A — see
 *       phase-2b-0-foundation.md D14)
 *
 * DNS records (CNAMEs at Squarespace) are added MANUALLY by the
 * operator after the stack deploys — `DistributionDomainName` output
 * is the CNAME target. ACM cert validation also goes through a manual
 * Squarespace DNS step (operator monitors `aws acm describe-certificate`
 * to grab the validation records while the cert resource is in
 * PENDING_VALIDATION).
 *
 * See phase-2b-0-foundation.md §Scope > Hosting + §Deployment.
 */
export class HostingStack extends cdk.Stack {
  public readonly siteBucket?: s3.Bucket;
  public readonly distribution?: cloudfront.Distribution;

  constructor(scope: Construct, id: string, props: HostingStackProps) {
    super(scope, id, props);

    const { config } = props;
    const siteKey = props.siteKey ?? 'portal';
    const domain = props.domain ?? config.portalDomain;

    // No domain means no hosting — emit a scaffold marker and exit.
    if (!domain) {
      new cdk.CfnOutput(this, 'Status', {
        value: 'SCAFFOLD — set the site domain in config to enable',
      });
      return;
    }

    const prefix = config.prefix;

    // ── S3 bucket (private, OAC-only) ─────────────────────────────
    this.siteBucket = new s3.Bucket(this, 'SiteBucket', {
      bucketName: `gosteady-${prefix}-${siteKey}-hosting`,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      versioned: true,
      removalPolicy:
        prefix === 'prod' ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: prefix !== 'prod',
      enforceSSL: true,
      lifecycleRules: [
        {
          id: 'expire-old-versions',
          noncurrentVersionExpiration: cdk.Duration.days(30),
        },
      ],
    });

    // ── ACM certificate (us-east-1, DNS-validated) ────────────────
    // Per phase-2b-0-foundation.md A9/A10 — validation CNAMEs are added
    // manually at Squarespace DNS. CDK deploy hangs on this resource
    // until the cert validates; operator monitors via
    //   aws acm describe-certificate --certificate-arn <arn>
    // to grab the validation records when the resource is
    // PENDING_VALIDATION.
    const certificate = new acm.Certificate(this, 'Certificate', {
      domainName: domain,
      validation: acm.CertificateValidation.fromDns(),
    });

    // ── WAF v2 web ACL ────────────────────────────────────────────
    // Baseline: AWSManagedRulesCommonRuleSet + per-IP rate limit.
    // IP-reputation list deferred to Phase 3A per D14.
    const webAcl = new wafv2.CfnWebACL(this, 'WebAcl', {
      name: `gosteady-${prefix}-${siteKey}-hosting-waf`,
      scope: 'CLOUDFRONT',
      defaultAction: { allow: {} },
      visibilityConfig: {
        sampledRequestsEnabled: true,
        cloudWatchMetricsEnabled: true,
        metricName: `gosteady-${prefix}-${siteKey}-hosting-waf`,
      },
      rules: [
        {
          name: 'AWSManagedRulesCommonRuleSet',
          priority: 0,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: {
              vendorName: 'AWS',
              name: 'AWSManagedRulesCommonRuleSet',
            },
          },
          visibilityConfig: {
            sampledRequestsEnabled: true,
            cloudWatchMetricsEnabled: true,
            metricName: 'AWSManagedRulesCommonRuleSet',
          },
        },
        {
          name: 'RateLimitPerIp',
          priority: 1,
          action: { block: {} },
          statement: {
            rateBasedStatement: {
              limit: config.apiWafRateLimitPerIp,
              aggregateKeyType: 'IP',
            },
          },
          visibilityConfig: {
            sampledRequestsEnabled: true,
            cloudWatchMetricsEnabled: true,
            metricName: 'RateLimitPerIp',
          },
        },
      ],
    });

    // ── CloudFront distribution with OAC + SPA rewrite ────────────
    // Single-page-app routing: 403 (OAC for missing object) AND 404
    // both rewrite to /index.html with HTTP 200 so Flutter's GoRouter
    // can take over on deep-link refresh.
    const errorResponses: cloudfront.ErrorResponse[] = [
      {
        httpStatus: 403,
        responseHttpStatus: 200,
        responsePagePath: '/index.html',
        ttl: cdk.Duration.minutes(5),
      },
      {
        httpStatus: 404,
        responseHttpStatus: 200,
        responsePagePath: '/index.html',
        ttl: cdk.Duration.minutes(5),
      },
    ];

    this.distribution = new cloudfront.Distribution(this, 'Distribution', {
      domainNames: [domain],
      certificate,
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(
          this.siteBucket,
        ),
        viewerProtocolPolicy:
          cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD_OPTIONS,
        cachedMethods: cloudfront.CachedMethods.CACHE_GET_HEAD_OPTIONS,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        compress: true,
      },
      additionalBehaviors: {
        // index.html cached for 5 min max so a deploy is visible within
        // that window even without explicit invalidation. The deploy
        // script also runs `create-invalidation /*` for immediacy.
        'index.html': {
          origin: origins.S3BucketOrigin.withOriginAccessControl(
            this.siteBucket,
          ),
          viewerProtocolPolicy:
            cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          cachePolicy: new cloudfront.CachePolicy(this, 'IndexHtmlCache', {
            cachePolicyName: `gosteady-${prefix}-${siteKey}-index-html`,
            defaultTtl: cdk.Duration.minutes(5),
            maxTtl: cdk.Duration.minutes(5),
            minTtl: cdk.Duration.seconds(0),
            enableAcceptEncodingGzip: true,
            enableAcceptEncodingBrotli: true,
          }),
          compress: true,
        },
      },
      defaultRootObject: 'index.html',
      errorResponses,
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
      httpVersion: cloudfront.HttpVersion.HTTP2_AND_3,
      webAclId: webAcl.attrArn,
      enableLogging: false, // 3A flips for prod
      comment: `GoSteady ${config.envName} ${siteKey} hosting`,
    });

    // ── Outputs (consumed by tools/deploy-portal.sh) ──────────────
    new cdk.CfnOutput(this, 'BucketName', {
      value: this.siteBucket.bucketName,
      description: 'S3 bucket — sync portal build output here',
      exportName: `gosteady-${prefix}-${siteKey}-bucket`,
    });

    new cdk.CfnOutput(this, 'DistributionId', {
      value: this.distribution.distributionId,
      description: 'CloudFront distribution ID — create-invalidation target',
      exportName: `gosteady-${prefix}-${siteKey}-distribution-id`,
    });

    new cdk.CfnOutput(this, 'DistributionDomainName', {
      value: this.distribution.distributionDomainName,
      description:
        'CloudFront *.cloudfront.net domain — set as the CNAME data at Squarespace DNS',
      exportName: `gosteady-${prefix}-${siteKey}-distribution-domain`,
    });

    new cdk.CfnOutput(this, 'PortalUrl', {
      value: `https://${domain}/`,
      description: 'Public portal URL (after Squarespace CNAME is in place)',
    });

    new cdk.CfnOutput(this, 'CertificateArn', {
      value: certificate.certificateArn,
      description:
        'ACM cert ARN — use to fetch validation CNAMEs via aws acm describe-certificate',
    });
  }
}
