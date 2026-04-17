import * as cdk from 'aws-cdk-lib/core';
import { Template } from 'aws-cdk-lib/assertions';
import { AuthStack } from '../lib/stacks/auth-stack.js';

describe('AuthStack', () => {
  const app = new cdk.App();
  const stack = new AuthStack(app, 'TestAuth', {
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
    },
  });
  const template = Template.fromStack(stack);

  test('creates Cognito User Pool', () => {
    template.hasResourceProperties('AWS::Cognito::UserPool', {
      UserPoolName: 'gosteady-test-users',
    });
  });

  test('creates walker and caregiver groups', () => {
    template.hasResourceProperties('AWS::Cognito::UserPoolGroup', {
      GroupName: 'walker',
    });
    template.hasResourceProperties('AWS::Cognito::UserPoolGroup', {
      GroupName: 'caregiver',
    });
  });

  test('creates User Pool client', () => {
    template.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      ClientName: 'gosteady-test-portal',
    });
  });

  test('creates Relationships DynamoDB table with GSI', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'gosteady-test-relationships',
      KeySchema: [
        { AttributeName: 'caregiverId', KeyType: 'HASH' },
        { AttributeName: 'walkerId', KeyType: 'RANGE' },
      ],
    });
  });
});
