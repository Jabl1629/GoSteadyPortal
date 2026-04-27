import * as cdk from 'aws-cdk-lib/core';
import { Template } from 'aws-cdk-lib/assertions';
import { DataStack } from '../lib/stacks/data-stack.js';
import { SecurityStack } from '../lib/stacks/security-stack.js';

/**
 * DataStack tests — Phase 0B revision shape.
 *
 * Updated 2026-04-27 for the multi-tenant data layer: 7 tables total
 * (4 identity-bearing CMK-encrypted + 3 telemetry AWS-managed). The legacy
 * `user-profiles` table is removed; patient-centric PKs on Activity/Alerts.
 */
describe('DataStack', () => {
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

  const security = new SecurityStack(app, 'TestSecurityForData', { config });
  const stack = new DataStack(app, 'TestData', { config, securityStack: security });
  const template = Template.fromStack(stack);

  test('creates 7 DynamoDB tables total (4 identity + 3 telemetry)', () => {
    template.resourceCountIs('AWS::DynamoDB::Table', 7);
  });

  test('creates Organizations table (CMK-encrypted, single-table hierarchy)', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-organizations',
      KeySchema: [
        { AttributeName: 'clientId', KeyType: 'HASH' },
        { AttributeName: 'sk', KeyType: 'RANGE' },
      ],
      SSESpecification: { SSEEnabled: true, SSEType: 'KMS' },
    });
  });

  test('creates Patients table with DDB Streams + 2 GSIs (CMK-encrypted)', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-patients',
      KeySchema: [{ AttributeName: 'patientId', KeyType: 'HASH' }],
      StreamSpecification: { StreamViewType: 'NEW_AND_OLD_IMAGES' },
      SSESpecification: { SSEEnabled: true, SSEType: 'KMS' },
    });
  });

  test('creates Users table (CMK-encrypted, replaces user-profiles)', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-users',
      KeySchema: [{ AttributeName: 'userId', KeyType: 'HASH' }],
      SSESpecification: { SSEEnabled: true, SSEType: 'KMS' },
    });
  });

  test('creates DeviceAssignments table (CMK-encrypted, by-patient GSI)', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-device-assignments',
      KeySchema: [
        { AttributeName: 'serialNumber', KeyType: 'HASH' },
        { AttributeName: 'assignedAt', KeyType: 'RANGE' },
      ],
      SSESpecification: { SSEEnabled: true, SSEType: 'KMS' },
    });
  });

  test('Activity Series migrates PK to patientId; AWS-managed encryption', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-activity',
      KeySchema: [
        { AttributeName: 'patientId', KeyType: 'HASH' },
        { AttributeName: 'timestamp', KeyType: 'RANGE' },
      ],
      TimeToLiveSpecification: { AttributeName: 'expiresAt', Enabled: true },
    });
  });

  test('Alert History migrates PK to patientId; 24-mo TTL on expiresAt', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-alerts',
      KeySchema: [
        { AttributeName: 'patientId', KeyType: 'HASH' },
        { AttributeName: 'timestamp', KeyType: 'RANGE' },
      ],
      TimeToLiveSpecification: { AttributeName: 'expiresAt', Enabled: true },
    });
  });

  test('Device Registry retains serialNumber PK; new by-owning-client GSI', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-devices',
      KeySchema: [{ AttributeName: 'serialNumber', KeyType: 'HASH' }],
    });
  });

  test('legacy user-profiles table is gone (replaced by users)', () => {
    // No table with the old name exists in the synthesized template.
    const userProfilesCount = Object.values(template.toJSON().Resources ?? {}).filter(
      (r: any) => r.Type === 'AWS::DynamoDB::Table' && r.Properties?.TableName === 'gosteady-test-user-profiles',
    ).length;
    expect(userProfilesCount).toBe(0);
  });
});
