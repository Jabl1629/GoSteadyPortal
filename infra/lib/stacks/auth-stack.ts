import * as cdk from 'aws-cdk-lib/core';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface AuthStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
}

/**
 * Authentication & User Management
 *
 * - Cognito User Pool (email + password sign-in)
 * - Custom attribute `role` (walker | caregiver)
 * - Cognito Groups for API permission scoping
 * - DynamoDB Relationships table (caregiver ↔ walker links)
 */
export class AuthStack extends cdk.Stack {
  /** Cognito User Pool — import in other stacks for JWT authorizer. */
  public readonly userPool: cognito.UserPool;
  /** User Pool client for the portal web app. */
  public readonly portalClient: cognito.UserPoolClient;
  /** Caregiver ↔ Walker relationship table. */
  public readonly relationshipsTable: dynamodb.Table;

  constructor(scope: Construct, id: string, props: AuthStackProps) {
    super(scope, id, props);

    const { config } = props;
    const p = config.prefix;

    // ── Cognito User Pool ────────────────────────────────────────
    this.userPool = new cognito.UserPool(this, 'UserPool', {
      userPoolName: `gosteady-${p}-users`,
      selfSignUpEnabled: true,
      signInAliases: { email: true },
      autoVerify: { email: true },
      standardAttributes: {
        fullname: { required: true, mutable: true },
        email: { required: true, mutable: false },
      },
      customAttributes: {
        role: new cognito.StringAttribute({
          mutable: true,
          minLen: 4,
          maxLen: 16,
        }),
        linked_devices: new cognito.StringAttribute({
          mutable: true,
          minLen: 0,
          maxLen: 2048, // JSON array of serial numbers
        }),
      },
      passwordPolicy: {
        minLength: 8,
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: false,
      },
      userVerification: {
        emailSubject: 'GoSteady — Verify your email',
        emailBody:
          'Welcome to GoSteady!\n\n' +
          'Your verification code is: {####}\n\n' +
          'Enter this code in the GoSteady Portal to complete your account setup.\n\n' +
          'If you did not create a GoSteady account, you can safely ignore this email.\n\n' +
          '— The GoSteady Team',
        emailStyle: cognito.VerificationEmailStyle.CODE,
      },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      removalPolicy:
        p === 'prod' ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });

    // ── Cognito Groups ───────────────────────────────────────────
    new cognito.CfnUserPoolGroup(this, 'WalkerGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'walker',
      description: 'Walker users — view own device data',
      precedence: 2,
    });

    new cognito.CfnUserPoolGroup(this, 'CaregiverGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'caregiver',
      description: 'Caregivers — view linked walkers\' data + receive alerts',
      precedence: 1,
    });

    // ── Portal Web Client ────────────────────────────────────────
    this.portalClient = this.userPool.addClient('PortalClient', {
      userPoolClientName: `gosteady-${p}-portal`,
      authFlows: {
        userPassword: true,
        userSrp: true,
      },
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: [
          'http://localhost:8080/callback',  // local dev
          ...(config.portalDomain
            ? [`https://${config.portalDomain}/callback`]
            : []),
        ],
        logoutUrls: [
          'http://localhost:8080/',
          ...(config.portalDomain
            ? [`https://${config.portalDomain}/`]
            : []),
        ],
      },
      idTokenValidity: cdk.Duration.hours(1),
      accessTokenValidity: cdk.Duration.hours(1),
      refreshTokenValidity: cdk.Duration.days(30),
      preventUserExistenceErrors: true,
    });

    // ── Relationships Table (caregiver ↔ walker) ────────────────
    this.relationshipsTable = new dynamodb.Table(this, 'Relationships', {
      tableName: `gosteady-${p}-relationships`,
      partitionKey: {
        name: 'caregiverId',
        type: dynamodb.AttributeType.STRING,
      },
      sortKey: {
        name: 'walkerId',
        type: dynamodb.AttributeType.STRING,
      },
      billingMode:
        config.dynamoBillingMode === 'PAY_PER_REQUEST'
          ? dynamodb.BillingMode.PAY_PER_REQUEST
          : dynamodb.BillingMode.PROVISIONED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: config.pitrEnabled },
      removalPolicy:
        p === 'prod' ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });

    // GSI: look up all caregivers for a given walker
    this.relationshipsTable.addGlobalSecondaryIndex({
      indexName: 'walker-caregivers',
      partitionKey: {
        name: 'walkerId',
        type: dynamodb.AttributeType.STRING,
      },
      sortKey: {
        name: 'caregiverId',
        type: dynamodb.AttributeType.STRING,
      },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ── Outputs ──────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'UserPoolId', {
      value: this.userPool.userPoolId,
      exportName: `${p}-UserPoolId`,
    });
    new cdk.CfnOutput(this, 'UserPoolClientId', {
      value: this.portalClient.userPoolClientId,
      exportName: `${p}-PortalClientId`,
    });
    new cdk.CfnOutput(this, 'RelationshipsTableName', {
      value: this.relationshipsTable.tableName,
      exportName: `${p}-RelationshipsTable`,
    });
  }
}
