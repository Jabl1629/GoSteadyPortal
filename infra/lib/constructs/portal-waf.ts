import * as cdk from 'aws-cdk-lib/core';
import * as wafv2 from 'aws-cdk-lib/aws-wafv2';
import { Construct } from 'constructs';

export interface PortalWafProps {
  /** Env prefix (`dev` / `prod`). */
  readonly env: string;
  /** Resource ARN to associate the Web ACL to (API Gateway stage ARN). */
  readonly resourceArn: string;
  /** Rate-limit per 5min per source IP. */
  readonly rateLimitPerIp: number;
}

/**
 * PortalWaf — Phase 2A-0.
 *
 * Regional WAFv2 Web ACL fronting the API Gateway HTTP API. Three rules:
 *   1. AWS Managed Rules Common Rule Set (CRS) — broad bad-input protection
 *   2. AWS Managed Rules Amazon IP Reputation List — drop known-bad IPs
 *   3. Rate-limit rule — N requests / 5 min / source IP
 *
 * Bot Control is deliberately omitted (~$10/mo + per-request; overkill at
 * MVP). Per Phase 2A-0 D6 — revisit when real bot traffic appears.
 *
 * Visibility metrics enabled for each rule so the WAF console shows per-rule
 * hit counts; CloudWatch metric `BlockedRequests` is alarmed in the API stack.
 */
export class PortalWaf extends Construct {
  public readonly webAcl: wafv2.CfnWebACL;

  constructor(scope: Construct, id: string, props: PortalWafProps) {
    super(scope, id);

    this.webAcl = new wafv2.CfnWebACL(this, 'WebACL', {
      name: `gosteady-${props.env}-portal-waf`,
      scope: 'REGIONAL', // API Gateway HTTP API is regional, not CloudFront
      defaultAction: { allow: {} },
      visibilityConfig: {
        cloudWatchMetricsEnabled: true,
        metricName: `gosteady-${props.env}-portal-waf`,
        sampledRequestsEnabled: true,
      },
      rules: [
        {
          name: 'AWSManagedCommonRuleSet',
          priority: 0,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: {
              vendorName: 'AWS',
              name: 'AWSManagedRulesCommonRuleSet',
            },
          },
          visibilityConfig: {
            cloudWatchMetricsEnabled: true,
            metricName: 'AWSManagedCommonRuleSet',
            sampledRequestsEnabled: true,
          },
        },
        {
          name: 'AWSManagedIpReputationList',
          priority: 1,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: {
              vendorName: 'AWS',
              name: 'AWSManagedRulesAmazonIpReputationList',
            },
          },
          visibilityConfig: {
            cloudWatchMetricsEnabled: true,
            metricName: 'AWSManagedIpReputationList',
            sampledRequestsEnabled: true,
          },
        },
        {
          name: 'RateLimitPerIp',
          priority: 10,
          action: { block: {} },
          statement: {
            rateBasedStatement: {
              limit: props.rateLimitPerIp,
              aggregateKeyType: 'IP',
              // 300 s = 5 min window per AWS WAF rate-based defaults
              evaluationWindowSec: 300,
            },
          },
          visibilityConfig: {
            cloudWatchMetricsEnabled: true,
            metricName: 'RateLimitPerIp',
            sampledRequestsEnabled: true,
          },
        },
      ],
    });

    new wafv2.CfnWebACLAssociation(this, 'WebACLAssociation', {
      resourceArn: props.resourceArn,
      webAclArn: this.webAcl.attrArn,
    });
  }
}
