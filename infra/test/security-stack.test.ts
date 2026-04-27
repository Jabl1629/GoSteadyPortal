import * as cdk from 'aws-cdk-lib/core';
import { Template } from 'aws-cdk-lib/assertions';
import { SecurityStack } from '../lib/stacks/security-stack.js';

describe('SecurityStack (dev profile)', () => {
  const app = new cdk.App();
  const stack = new SecurityStack(app, 'TestSecurity', {
    env: { account: '123456789012', region: 'us-east-1' },
    config: {
      envName: 'Test',
      prefix: 'test',
      account: '123456789012',
      region: 'us-east-1',
      pitrEnabled: false,
      dynamoBillingMode: 'PAY_PER_REQUEST',
      alarmsEnabled: false,
      kmsCmkEnabled: true,
      cloudTrailEnabled: true,
      cloudTrailObjectLockEnabled: false,
      costAlarmThresholdUsd: 100,
      customerTokenIdleMinutes: 15,
      customerRefreshDays: 30,
      internalTokenIdleMinutes: 30,
      internalTokenAbsoluteMinutes: 240,
      snippetGlacierTransitionDays: 90,
      snippetTotalRetentionDays: 395,
      snippetParserMemoryMb: 256,
      snippetParserTimeoutSeconds: 30,
    },
  });
  const template = Template.fromStack(stack);

  test('creates three KMS CMKs with rotation enabled', () => {
    template.resourceCountIs('AWS::KMS::Key', 3);
    template.allResourcesProperties('AWS::KMS::Key', {
      EnableKeyRotation: true,
    });
  });

  test('creates three KMS aliases (identity, firmware, audit)', () => {
    template.resourceCountIs('AWS::KMS::Alias', 3);
    template.hasResourceProperties('AWS::KMS::Alias', {
      AliasName: 'alias/gosteady/test/identity',
    });
    template.hasResourceProperties('AWS::KMS::Alias', {
      AliasName: 'alias/gosteady/test/firmware',
    });
    template.hasResourceProperties('AWS::KMS::Alias', {
      AliasName: 'alias/gosteady/test/audit',
    });
  });

  test('creates CloudTrail multi-region management-events trail', () => {
    template.hasResourceProperties('AWS::CloudTrail::Trail', {
      TrailName: 'gosteady-test-cloudtrail',
      IsMultiRegionTrail: true,
      IncludeGlobalServiceEvents: true,
      EnableLogFileValidation: true,
    });
  });

  test('CloudTrail bucket blocks public access', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: 'gosteady-test-cloudtrail-logs-123456789012',
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
    });
  });

  test('creates cost alarm SNS topic', () => {
    template.hasResourceProperties('AWS::SNS::Topic', {
      TopicName: 'gosteady-test-cost-alarms',
    });
  });

  test('creates billing alarm at configured threshold', () => {
    template.hasResourceProperties('AWS::CloudWatch::Alarm', {
      AlarmName: 'gosteady-test-billing-over-100',
      Threshold: 100,
      MetricName: 'EstimatedCharges',
      Namespace: 'AWS/Billing',
    });
  });

  test('exports CMK ARNs for cross-stack reference', () => {
    template.hasOutput('IdentityKeyArn', {
      Export: { Name: 'test-IdentityKeyArn' },
    });
    template.hasOutput('FirmwareKeyArn', {
      Export: { Name: 'test-FirmwareKeyArn' },
    });
    template.hasOutput('AuditKeyArn', {
      Export: { Name: 'test-AuditKeyArn' },
    });
  });
});

describe('SecurityStack (prod profile — Object Lock enabled)', () => {
  const app = new cdk.App();
  const stack = new SecurityStack(app, 'TestSecurityProd', {
    env: { account: '123456789012', region: 'us-east-1' },
    config: {
      envName: 'Test',
      prefix: 'prod',
      account: '123456789012',
      region: 'us-east-1',
      pitrEnabled: true,
      dynamoBillingMode: 'PAY_PER_REQUEST',
      alarmsEnabled: true,
      kmsCmkEnabled: true,
      cloudTrailEnabled: true,
      cloudTrailObjectLockEnabled: true,
      costAlarmThresholdUsd: 500,
      customerTokenIdleMinutes: 15,
      customerRefreshDays: 30,
      internalTokenIdleMinutes: 30,
      internalTokenAbsoluteMinutes: 240,
      snippetGlacierTransitionDays: 90,
      snippetTotalRetentionDays: 395,
      snippetParserMemoryMb: 256,
      snippetParserTimeoutSeconds: 30,
    },
  });
  const template = Template.fromStack(stack);

  test('enables Object Lock in compliance mode with 6-year retention', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      ObjectLockEnabled: true,
      ObjectLockConfiguration: {
        ObjectLockEnabled: 'Enabled',
        Rule: {
          DefaultRetention: {
            Mode: 'COMPLIANCE',
            Days: 365 * 6,
          },
        },
      },
    });
  });
});
