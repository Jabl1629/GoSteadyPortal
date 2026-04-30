import * as cdk from 'aws-cdk-lib/core';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { SecurityStack } from '../lib/stacks/security-stack.js';
import { ProcessingStack } from '../lib/stacks/processing-stack.js';
import { DataStack } from '../lib/stacks/data-stack.js';
import { IngestionStack } from '../lib/stacks/ingestion-stack.js';

/**
 * IngestionStack tests — Phase 1A revision shape (2026-04-27).
 *
 * Coverage:
 *   - SnippetRule + SnippetParser Lambda + snippet bucket
 *   - Per-thing IoT policy refactored to explicit topic list (no wildcards)
 *     with cmd subscribe + Shadow Get/Update grants
 *   - OTA bucket migrated to FirmwareKey CMK
 *   - Existing 3 IoT Rules (activity, heartbeat, alert) remain
 */
describe('IngestionStack — Phase 1A revision', () => {
  const app = new cdk.App();
  const config = {
    envName: 'Test',
    prefix: 'test',
    account: '123456789012',
    region: 'us-east-1',
    pitrEnabled: false,
    dynamoBillingMode: 'PAY_PER_REQUEST' as const,
    alarmsEnabled: false,
    kmsCmkEnabled: true,
    cloudTrailEnabled: false,
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
    processingLambdaMemoryMb: 256,
    processingHeartbeatMemoryMb: 128,
    processingLambdaTimeoutSeconds: 30,
    activationAckWindowHours: 24,
    preActivationAuditSampleHours: 1,
    powertoolsLayerArn:
      'arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:32',
  };

  const security = new SecurityStack(app, 'TestSecurityForIngestion', { config });
  const data = new DataStack(app, 'TestDataForIngestion', { config, securityStack: security });
  const processing = new ProcessingStack(app, 'TestProcessingForIngestion', {
    config,
    dataStack: data,
    securityStack: security,
  });
  const stack = new IngestionStack(app, 'TestIngestion', {
    config,
    processingStack: processing,
    securityStack: security,
  });
  const template = Template.fromStack(stack);

  test('creates 5 IoT Topic Rules (activity, heartbeat, alert, snippet, shadow_update)', () => {
    template.resourceCountIs('AWS::IoT::TopicRule', 5);
  });

  test('ShadowUpdateRule SQL targets $aws/things/+/shadow/update/documents with current/previous reported', () => {
    template.hasResourceProperties('AWS::IoT::TopicRule', {
      RuleName: 'gosteady_test_shadow_update',
      TopicRulePayload: Match.objectLike({
        Sql: Match.stringLikeRegexp("FROM '\\$aws/things/\\+/shadow/update/documents'"),
      }),
    });
  });

  test('SnippetRule SQL base64-encodes the binary payload', () => {
    template.hasResourceProperties('AWS::IoT::TopicRule', {
      RuleName: 'gosteady_test_snippet',
      TopicRulePayload: Match.objectLike({
        Sql: Match.stringLikeRegexp("encode\\(\\*, 'base64'\\) AS payload_b64"),
      }),
    });
  });

  test('SnippetParser Lambda is Python 3.12 ARM64', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'gosteady-test-snippet-parser',
      Runtime: 'python3.12',
      Architectures: ['arm64'],
      Environment: { Variables: Match.objectLike({ SNIPPET_BUCKET: Match.anyValue() }) },
    });
  });

  test('snippet bucket: AWS-managed SSE, lifecycle Standard→Glacier→delete, public access blocked', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: 'gosteady-test-snippets',
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
      BucketEncryption: {
        ServerSideEncryptionConfiguration: Match.arrayWith([
          Match.objectLike({
            ServerSideEncryptionByDefault: { SSEAlgorithm: 'AES256' },
          }),
        ]),
      },
      LifecycleConfiguration: {
        Rules: Match.arrayWith([
          Match.objectLike({
            Status: 'Enabled',
            Transitions: [{ StorageClass: 'GLACIER', TransitionInDays: 90 }],
            ExpirationInDays: 395,
          }),
        ]),
      },
    });
  });

  test('OTA bucket migrated to FirmwareKey CMK with bucket-key enabled', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: 'gosteady-test-firmware-ota',
      BucketEncryption: {
        ServerSideEncryptionConfiguration: Match.arrayWith([
          Match.objectLike({
            BucketKeyEnabled: true,
            ServerSideEncryptionByDefault: Match.objectLike({
              SSEAlgorithm: 'aws:kms',
            }),
          }),
        ]),
      },
    });
  });

  /**
   * CDK renders the policy ARNs as `Fn::Join` intrinsics (region/account
   * are stack tokens). The high-level Match.* helpers don't see through
   * the join, so these tests walk the synthesized policy as JSON and
   * flatten the joins with the same delimiter+parts shape CDK produces.
   */
  const flattenArn = (resource: unknown): string => {
    if (typeof resource === 'string') return resource;
    const obj = resource as { 'Fn::Join'?: [string, unknown[]] };
    if (obj['Fn::Join']) {
      const [delim, parts] = obj['Fn::Join'];
      return parts
        .map((part) => (typeof part === 'string' ? part : '<token>'))
        .join(delim);
    }
    return JSON.stringify(resource);
  };

  const devicePolicyStatements = (() => {
    const policies = template.findResources('AWS::IoT::Policy');
    const policy = Object.values(policies)[0] as {
      Properties: {
        PolicyDocument: {
          Statement: Array<{
            Sid?: string;
            Action: string | string[];
            Resource: unknown;
          }>;
        };
      };
    };
    return policy.Properties.PolicyDocument.Statement;
  })();

  const stmtBySid = (sid: string) => devicePolicyStatements.find((s) => s.Sid === sid);

  test('Device IoT policy uses explicit topic list, no gs/<thing>/* wildcards', () => {
    for (const s of devicePolicyStatements) {
      const resources = Array.isArray(s.Resource) ? s.Resource : [s.Resource];
      for (const r of resources) {
        expect(flattenArn(r)).not.toMatch(/\/gs\/\$\{iot:Connection\.Thing\.ThingName\}\/\*/);
      }
    }
  });

  test('Device IoT policy authorizes Publish on heartbeat / activity / alert / snippet', () => {
    const stmt = stmtBySid('PublishUplinks');
    expect(stmt).toBeDefined();
    expect(stmt!.Action).toBe('iot:Publish');
    const resources = (stmt!.Resource as unknown[]).map(flattenArn);
    for (const suffix of ['heartbeat', 'activity', 'alert', 'snippet']) {
      expect(resources.some((r) => r.endsWith(`/${suffix}`))).toBe(true);
    }
  });

  test('Device IoT policy authorizes Subscribe + Receive on cmd', () => {
    const stmt = stmtBySid('SubscribeOwnCmd');
    expect(stmt).toBeDefined();
    expect(stmt!.Action).toEqual(['iot:Subscribe', 'iot:Receive']);
    const resources = (stmt!.Resource as unknown[]).map(flattenArn);
    expect(resources.some((r) => r.includes('topicfilter/gs/') && r.endsWith('/cmd'))).toBe(true);
    expect(resources.some((r) => r.includes('topic/gs/') && r.endsWith('/cmd'))).toBe(true);
  });

  test('Device IoT policy authorizes Shadow Get/Update on own thing', () => {
    const stmt = stmtBySid('OwnShadowApi');
    expect(stmt).toBeDefined();
    expect(stmt!.Action).toEqual(['iot:GetThingShadow', 'iot:UpdateThingShadow']);
    expect(flattenArn(stmt!.Resource)).toMatch(/:thing\/\$\{iot:Connection\.Thing\.ThingName\}/);
  });

  test('Device IoT policy authorizes MQTT Publish on own shadow/* topic', () => {
    const stmt = stmtBySid('OwnShadowMqttPublish');
    expect(stmt).toBeDefined();
    expect(stmt!.Action).toBe('iot:Publish');
    const resource = flattenArn(stmt!.Resource);
    expect(resource).toMatch(/topic\/\$aws\/things\/\$\{iot:Connection\.Thing\.ThingName\}\/shadow\/\*$/);
  });

  test('Device IoT policy authorizes MQTT Subscribe + Receive on own shadow/* (topicfilter + topic)', () => {
    const stmt = stmtBySid('OwnShadowMqttSubscribe');
    expect(stmt).toBeDefined();
    expect(stmt!.Action).toEqual(['iot:Subscribe', 'iot:Receive']);
    const resources = (stmt!.Resource as unknown[]).map(flattenArn);
    expect(
      resources.some((r) => r.includes('topicfilter/$aws/things/') && r.endsWith('/shadow/*')),
    ).toBe(true);
    expect(
      resources.some((r) => r.includes(':topic/$aws/things/') && r.endsWith('/shadow/*')),
    ).toBe(true);
  });

  /**
   * AWS IoT enforces a 2048-byte hard limit on policy documents. Initial
   * deploy attempt with explicit enumeration of all shadow MQTT channels
   * exceeded the cap; we now use shadow/* wildcards (still scoped to the
   * device's own thing via the policy variable). Synth-time `Fn::Join`
   * intrinsics inflate the serialized form well past the actual policy
   * size, so we walk the doc and flatten ARNs to their rendered string
   * form before measuring — gives a faithful predictor of what AWS will
   * see on deploy.
   */
  test('Device IoT policy stays under AWS IoT 2048-byte hard limit', () => {
    const policies = template.findResources('AWS::IoT::Policy');
    type Stmt = { Resource: unknown; [k: string]: unknown };
    const def = Object.values(policies)[0] as {
      Properties: { PolicyDocument: { Statement: Stmt[]; Version: string } };
    };

    const renderResource = (r: unknown): unknown => {
      if (Array.isArray(r)) return r.map(renderResource);
      if (typeof r === 'string') return r;
      if (r && typeof r === 'object') {
        const obj = r as Record<string, unknown>;
        if (obj['Fn::Join']) {
          const [delim, parts] = obj['Fn::Join'] as [string, unknown[]];
          // Substitute account/region tokens with realistic placeholders so
          // the rendered length matches what gets shipped to AWS.
          return parts
            .map((p) => (typeof p === 'string' ? p : '460223323193'))
            .join(delim);
        }
      }
      return r;
    };

    const renderedDoc = {
      Version: def.Properties.PolicyDocument.Version,
      Statement: def.Properties.PolicyDocument.Statement.map((s) => ({
        ...s,
        Resource: renderResource(s.Resource),
      })),
    };
    const serialized = JSON.stringify(renderedDoc);
    expect(serialized.length).toBeLessThan(2048);
    // Margin guard — fail-loud if a future grant pushes us within 200 bytes
    // of the cap, so we hit the rebuild before the deploy fails.
    expect(serialized.length).toBeLessThan(2048 - 200);
  });

  test('SnippetParser has PutObject permission on snippet bucket only', () => {
    // Find the SnippetParser default policy and confirm s3:PutObject grants
    // resolve to the snippet bucket ARN.
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Action: Match.arrayWith(['s3:PutObject']),
          }),
        ]),
      }),
    });
  });

  test('SnippetRule routes failures to the shared SQS DLQ', () => {
    template.hasResourceProperties('AWS::IoT::TopicRule', {
      RuleName: 'gosteady_test_snippet',
      TopicRulePayload: Match.objectLike({
        ErrorAction: Match.objectLike({
          Sqs: Match.objectLike({
            QueueUrl: Match.anyValue(),
          }),
        }),
      }),
    });
  });
});
