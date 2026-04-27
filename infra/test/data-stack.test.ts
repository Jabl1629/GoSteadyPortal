import * as cdk from 'aws-cdk-lib/core';
import { Template } from 'aws-cdk-lib/assertions';
import { DataStack } from '../lib/stacks/data-stack.js';

describe('DataStack', () => {
  const app = new cdk.App();
  const stack = new DataStack(app, 'TestData', {
    config: {
      envName: 'Test',
      prefix: 'test',
      account: '123456789012',
      region: 'us-east-1',
      pitrEnabled: false,
      dynamoBillingMode: 'PAY_PER_REQUEST',
      alarmsEnabled: false,
      kmsCmkEnabled: false,
      cloudTrailEnabled: false,
      cloudTrailObjectLockEnabled: false,
      costAlarmThresholdUsd: 100,
      customerTokenIdleMinutes: 15,
      customerRefreshDays: 30,
      internalTokenIdleMinutes: 30,
      internalTokenAbsoluteMinutes: 240,
    },
  });
  const template = Template.fromStack(stack);

  test('creates Device Registry table', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-devices',
    });
  });

  test('creates Activity time-series table', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-activity',
      KeySchema: [
        { AttributeName: 'serialNumber', KeyType: 'HASH' },
        { AttributeName: 'timestamp', KeyType: 'RANGE' },
      ],
    });
  });

  test('creates Alert History table', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-alerts',
    });
  });

  test('creates User Profile table', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-user-profiles',
    });
  });

  test('creates 4 DynamoDB tables total', () => {
    template.resourceCountIs('AWS::DynamoDB::Table', 4);
  });
});
