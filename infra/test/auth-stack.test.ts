import * as cdk from 'aws-cdk-lib/core';
import { Template } from 'aws-cdk-lib/assertions';
import { AuthStack } from '../lib/stacks/auth-stack.js';
import { SecurityStack } from '../lib/stacks/security-stack.js';

/**
 * AuthStack tests — Phase 0A revision shape.
 *
 * Updated 2026-04-26 for the multi-tenant Auth stack: RoleAssignments table,
 * Pre-Token Generation Lambda, dual App Clients (Customer + Internal),
 * 7+1 group set (plus deprecated `walker` cruft).
 */
describe('AuthStack', () => {
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
  };

  const security = new SecurityStack(app, 'TestSecurity', { config });
  const stack = new AuthStack(app, 'TestAuth', {
    config,
    securityStack: security,
  });
  const template = Template.fromStack(stack);

  test('creates Cognito User Pool with multi-tenant custom attributes', () => {
    template.hasResourceProperties('AWS::Cognito::UserPool', {
      UserPoolName: 'gosteady-test-users',
    });
  });

  test('creates the new role groups', () => {
    for (const groupName of [
      'internal_admin',
      'internal_support',
      'client_admin',
      'facility_admin',
      'household_owner',
      'caregiver',
      'family_viewer',
      'patient',
    ]) {
      template.hasResourceProperties('AWS::Cognito::UserPoolGroup', { GroupName: groupName });
    }
  });

  test('keeps the deprecated walker group as cruft', () => {
    // Cognito doesn't allow group deletion; left as inert per phase-0a-revision.md D1.
    template.hasResourceProperties('AWS::Cognito::UserPoolGroup', { GroupName: 'walker' });
  });

  test('creates Portal-Customer App Client', () => {
    template.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      ClientName: 'gosteady-test-portal-customer',
    });
  });

  test('creates Portal-Internal App Client with secret', () => {
    template.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      ClientName: 'gosteady-test-portal-internal',
      GenerateSecret: true,
    });
  });

  test('creates RoleAssignments DynamoDB table (replaces Relationships) with KMS CMK + GSI', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-role-assignments',
      KeySchema: [{ AttributeName: 'userId', KeyType: 'HASH' }],
      SSESpecification: {
        SSEEnabled: true,
        SSEType: 'KMS',
      },
    });
  });

  test('Pre-Token Generation Lambda is created and wired to User Pool', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'gosteady-test-cognito-pre-token',
      Runtime: 'python3.12',
      Architectures: ['arm64'],
    });

    template.hasResourceProperties('AWS::Cognito::UserPool', {
      LambdaConfig: {
        // PreTokenGenerationConfig.LambdaArn for V2 trigger
        PreTokenGenerationConfig: {
          LambdaVersion: 'V2_0',
        },
      },
    });
  });
});
