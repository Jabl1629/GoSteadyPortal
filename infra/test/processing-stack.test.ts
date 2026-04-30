import * as cdk from 'aws-cdk-lib/core';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { SecurityStack } from '../lib/stacks/security-stack.js';
import { DataStack } from '../lib/stacks/data-stack.js';
import { ProcessingStack } from '../lib/stacks/processing-stack.js';

/**
 * ProcessingStack tests — Phase 1B revision shape (2026-04-27).
 *
 * Asserts the four-handler post-revision shape:
 *   - all four Lambdas exist with expected names
 *   - all four are ARM64
 *   - threshold-detector is present (NEW)
 *   - patient-readers (activity / threshold-detector / alert) get
 *     IdentityKey CMK Decrypt grants
 *   - heartbeat-processor does NOT get IdentityKey grants (slim path)
 *   - heartbeat + threshold-detector hold IoT Shadow grants
 */
describe('ProcessingStack — Phase 1B revision', () => {
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
      costAnomalyEnabled: false,
  };

  const security = new SecurityStack(app, 'TestSecurityForProcessing', { config });
  const data = new DataStack(app, 'TestDataForProcessing', { config, securityStack: security });
  const stack = new ProcessingStack(app, 'TestProcessing', {
    config,
    dataStack: data,
    securityStack: security,
  });
  const template = Template.fromStack(stack);

  test('creates four handler Lambdas', () => {
    for (const name of [
      'gosteady-test-activity-processor',
      'gosteady-test-heartbeat-processor',
      'gosteady-test-threshold-detector',
      'gosteady-test-alert-handler',
    ]) {
      template.hasResourceProperties('AWS::Lambda::Function', {
        FunctionName: name,
      });
    }
  });

  test('all four handlers are ARM64 + Python 3.12', () => {
    for (const name of [
      'gosteady-test-activity-processor',
      'gosteady-test-heartbeat-processor',
      'gosteady-test-threshold-detector',
      'gosteady-test-alert-handler',
    ]) {
      template.hasResourceProperties('AWS::Lambda::Function', {
        FunctionName: name,
        Runtime: 'python3.12',
        Architectures: ['arm64'],
      });
    }
  });

  test('handler env carries Powertools service + table names + ack window', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'gosteady-test-heartbeat-processor',
      Environment: {
        Variables: Match.objectLike({
          POWERTOOLS_SERVICE_NAME: 'gosteady-test-heartbeat-processor',
          ACTIVATION_ACK_WINDOW_HOURS: '24',
          DEVICE_TABLE: 'gosteady-test-devices',
        }),
      },
    });

    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'gosteady-test-threshold-detector',
      Environment: {
        Variables: Match.objectLike({
          POWERTOOLS_SERVICE_NAME: 'gosteady-test-threshold-detector',
          PRE_ACTIVATION_AUDIT_SAMPLE_HOURS: '1',
          ALERT_TABLE: 'gosteady-test-alerts',
          PATIENTS_TABLE: 'gosteady-test-patients',
        }),
      },
    });
  });

  test('exports each handler ARN cross-stack', () => {
    template.hasOutput('ActivityProcessorArn', { Export: { Name: 'test-ActivityProcessorArn' } });
    template.hasOutput('HeartbeatProcessorArn', { Export: { Name: 'test-HeartbeatProcessorArn' } });
    template.hasOutput('ThresholdDetectorArn', { Export: { Name: 'test-ThresholdDetectorArn' } });
    template.hasOutput('AlertHandlerArn', { Export: { Name: 'test-AlertHandlerArn' } });
  });

  /**
   * Walk all IAM::Policy resources and find the policy for a given Lambda
   * service role. CDK names them like `<LambdaId>ServiceRoleDefaultPolicy<hash>`.
   */
  const flattenStringList = (raw: unknown): string[] => {
    if (typeof raw === 'string') return [raw];
    if (Array.isArray(raw)) return raw.flatMap(flattenStringList);
    if (raw && typeof raw === 'object') {
      const obj = raw as Record<string, unknown>;
      if (obj['Fn::Join']) {
        const join = obj['Fn::Join'] as [string, unknown[]];
        const [delim, parts] = join;
        return [parts.map((p) => (typeof p === 'string' ? p : JSON.stringify(p))).join(delim)];
      }
      if (obj['Fn::GetAtt']) {
        return [`<getatt:${(obj['Fn::GetAtt'] as unknown[]).join('.')}>`];
      }
      if (obj['Fn::ImportValue']) {
        return [`<importvalue:${obj['Fn::ImportValue']}>`];
      }
    }
    return [JSON.stringify(raw)];
  };

  type PolicyStmt = {
    Action?: string | string[];
    Resource?: unknown;
    Effect?: string;
  };

  const policiesAttachedTo = (lambdaIdSubstring: string): PolicyStmt[] => {
    const policies = template.findResources('AWS::IAM::Policy');
    const out: PolicyStmt[] = [];
    for (const [logicalId, def] of Object.entries(policies)) {
      if (!logicalId.includes(lambdaIdSubstring)) continue;
      const stmts = (def as { Properties: { PolicyDocument: { Statement: PolicyStmt[] } } })
        .Properties.PolicyDocument.Statement;
      out.push(...stmts);
    }
    return out;
  };

  const hasKmsDecrypt = (statements: PolicyStmt[]): boolean =>
    statements.some((s) => {
      const actions = Array.isArray(s.Action) ? s.Action : [s.Action];
      return actions.includes('kms:Decrypt');
    });

  test('activity-processor has IdentityKey kms:Decrypt grant', () => {
    expect(hasKmsDecrypt(policiesAttachedTo('ActivityProcessor'))).toBe(true);
  });

  test('threshold-detector has IdentityKey kms:Decrypt grant', () => {
    expect(hasKmsDecrypt(policiesAttachedTo('ThresholdDetector'))).toBe(true);
  });

  test('alert-handler has IdentityKey kms:Decrypt grant', () => {
    expect(hasKmsDecrypt(policiesAttachedTo('AlertHandler'))).toBe(true);
  });

  test('heartbeat-processor does NOT have IdentityKey kms:Decrypt grant (slim path)', () => {
    // heartbeat-processor only touches Device Registry (AWS-managed encryption)
    // and Shadow — no CMK-encrypted reads, so least-privilege excludes the grant.
    expect(hasKmsDecrypt(policiesAttachedTo('HeartbeatProcessor'))).toBe(false);
  });

  test('heartbeat-processor has iot:UpdateThingShadow grant', () => {
    const stmts = policiesAttachedTo('HeartbeatProcessor');
    const hasShadowUpdate = stmts.some((s) => {
      const actions = Array.isArray(s.Action) ? s.Action : [s.Action];
      return actions.includes('iot:UpdateThingShadow');
    });
    expect(hasShadowUpdate).toBe(true);
  });

  test('threshold-detector has iot:GetThingShadow + iot:UpdateThingShadow grants', () => {
    const stmts = policiesAttachedTo('ThresholdDetector');
    const all = new Set(
      stmts.flatMap((s) => (Array.isArray(s.Action) ? s.Action : [s.Action || ''])),
    );
    expect(all.has('iot:GetThingShadow')).toBe(true);
    expect(all.has('iot:UpdateThingShadow')).toBe(true);
  });

  // Sanity-check that flattenStringList exists in case someone else reuses it
  test('flattenStringList helper imports cleanly', () => {
    expect(flattenStringList(['a', 'b'])).toEqual(['a', 'b']);
  });
});
