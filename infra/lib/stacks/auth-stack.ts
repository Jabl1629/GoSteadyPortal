import * as cdk from 'aws-cdk-lib/core';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';
import * as path from 'path';
import { GoSteadyEnvConfig } from '../config.js';
import { SecurityStack } from './security-stack.js';

export interface AuthStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  /** Security stack provides the IdentityKey CMK referenced by RoleAssignments. */
  readonly securityStack: SecurityStack;
}

/**
 * Authentication & User Management — Phase 0A + Phase 0A Revision
 *
 * Spec: docs/specs/phase-0a-revision.md
 *
 * Multi-tenant Cognito setup with RBAC + MFA enforcement:
 *
 *   • User Pool with custom attributes for multi-tenancy:
 *       - custom:role          (single-value enum, expanded per Architecture A3)
 *       - custom:clientId      (tenancy boundary; one per user)
 *       - custom:facilities    (comma-separated facility IDs)
 *       - custom:censuses      (comma-separated census IDs)
 *
 *   • Two App Clients:
 *       - Portal-Customer (15-min idle / 30-day refresh)  — existing client repurposed
 *       - Portal-Internal (30-min idle / 4-hr absolute)   — new, with secret
 *
 *   • Pre-Token Generation Lambda (V2):
 *       - Validates role + tenancy invariants on every auth
 *       - Enforces MFA for facility_admin / client_admin / internal_*
 *       - Injects custom claims into ID + Access tokens from RoleAssignments DDB
 *
 *   • Cognito Groups:
 *       - 7 customer roles + 2 internal roles, plus deprecated `walker` cruft
 *
 *   • RoleAssignments table:
 *       - PK: userId (Cognito sub); one row per user
 *       - GSI: by-client-role
 *       - CMK-encrypted with IdentityKey from Phase 1.5 Security stack
 *       - Replaces deprecated Relationships table (deleted by this revision)
 *
 *   • MFA: pool-level OPTIONAL with TOTP enabled; Pre-Token enforces per-role.
 *     SMS MFA disabled (D6).
 */
export class AuthStack extends cdk.Stack {
  /** Cognito User Pool — import in other stacks for JWT authorizer. */
  public readonly userPool: cognito.UserPool;
  /** Customer-tier App Client (15-min idle); existing ID preserved. */
  public readonly portalCustomerClient: cognito.UserPoolClient;
  /** Internal-tier App Client (30-min idle / 4-hr absolute); new. */
  public readonly portalInternalClient: cognito.UserPoolClient;
  /** RoleAssignments table — replaces Relationships. */
  public readonly roleAssignmentsTable: dynamodb.Table;
  /** Pre-Token Generation Lambda — exposes for ops/testing. */
  public readonly preTokenLambda: lambda.Function;

  constructor(scope: Construct, id: string, props: AuthStackProps) {
    super(scope, id, props);

    const { config, securityStack } = props;
    const p = config.prefix;
    const isProd = p === 'prod';
    const removal = isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY;

    // ── RoleAssignments Table ─────────────────────────────────────────
    // PK: userId (Cognito sub); one row per user.
    // CMK-encrypted with IdentityKey from Security stack.
    // GSI by-client-role: "list all caregivers in client X" pattern.
    this.roleAssignmentsTable = new dynamodb.Table(this, 'RoleAssignments', {
      tableName: `gosteady-${p}-role-assignments`,
      partitionKey: {
        name: 'userId',
        type: dynamodb.AttributeType.STRING,
      },
      billingMode:
        config.dynamoBillingMode === 'PAY_PER_REQUEST'
          ? dynamodb.BillingMode.PAY_PER_REQUEST
          : dynamodb.BillingMode.PROVISIONED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: config.pitrEnabled },
      encryption: dynamodb.TableEncryption.CUSTOMER_MANAGED,
      encryptionKey: securityStack.identityKey,
      removalPolicy: removal,
    });

    this.roleAssignmentsTable.addGlobalSecondaryIndex({
      indexName: 'by-client-role',
      partitionKey: {
        name: 'clientId',
        type: dynamodb.AttributeType.STRING,
      },
      sortKey: {
        // SK = role#userId so we can range-scan for all users of a given role
        name: 'role_userId',
        type: dynamodb.AttributeType.STRING,
      },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ── Pre-Token Generation Lambda ───────────────────────────────────
    // Reads RoleAssignments by userId, validates tenancy + MFA, injects
    // custom claims into ID + Access tokens.
    // Python 3.12 ARM64 (matches G6/G7).
    this.preTokenLambda = new lambda.Function(this, 'CognitoPreToken', {
      functionName: `gosteady-${p}-cognito-pre-token`,
      runtime: lambda.Runtime.PYTHON_3_12,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(
        path.join(__dirname, '..', '..', 'lambda', 'cognito-pre-token'),
      ),
      memorySize: 256,
      timeout: cdk.Duration.seconds(5), // Cognito Lambda triggers must respond fast
      // Phase 1.6: enable X-Ray Active Tracing for sign-in/refresh latency
      // visibility. CDK auto-grants AWSXRayDaemonWriteAccess.
      tracing: lambda.Tracing.ACTIVE,
      environment: {
        ROLE_ASSIGNMENTS_TABLE: this.roleAssignmentsTable.tableName,
        ENVIRONMENT: p,
      },
      logRetention: isProd ? logs.RetentionDays.THREE_MONTHS : logs.RetentionDays.ONE_MONTH,
      description: 'Cognito Pre-Token Generation V2 — claims injection + MFA enforcement',
    });

    // Grant the Lambda read access to RoleAssignments + KMS Decrypt on IdentityKey.
    this.roleAssignmentsTable.grantReadData(this.preTokenLambda);
    securityStack.identityKey.grantDecrypt(this.preTokenLambda);

    // ── Cognito User Pool ─────────────────────────────────────────────
    // Existing pool (gosteady-{env}-users) — additive updates only.
    // Custom attributes: clientId, facilities, censuses (new); role,
    // linked_devices (existing — linked_devices is deprecated cruft per L5
    // of phase-0a-revision.md but Cognito doesn't allow removing custom
    // attributes once defined).
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
        // Existing — kept identically (cannot modify constraints after creation in Cognito).
        // 16 chars accommodates the longest role name `internal_support`.
        role: new cognito.StringAttribute({ mutable: true, minLen: 4, maxLen: 16 }),
        // Existing — DEPRECATED but cannot be removed (Cognito limitation per D1)
        linked_devices: new cognito.StringAttribute({ mutable: true, minLen: 0, maxLen: 2048 }),
        // NEW (0A revision)
        clientId: new cognito.StringAttribute({ mutable: true, minLen: 0, maxLen: 64 }),
        facilities: new cognito.StringAttribute({ mutable: true, minLen: 0, maxLen: 2048 }),
        censuses: new cognito.StringAttribute({ mutable: true, minLen: 0, maxLen: 2048 }),
        // MFA-enrollment marker — set by app code post-MFA-setup, read by Pre-Token Lambda.
        // Phase 2B will own the MFA setup UX; this attribute is the bridge.
        mfa_enrolled: new cognito.StringAttribute({ mutable: true, minLen: 0, maxLen: 8 }),
      },
      passwordPolicy: {
        minLength: 14, // Phase 1.5 D12 — 14 chars min
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: true, // tightened from original 0A (was false)
      },
      // MFA: OPTIONAL pool-level with TOTP only. Enforcement per role
      // happens in Pre-Token Lambda. SMS disabled per D6 of phase-0a-revision.md.
      mfa: cognito.Mfa.OPTIONAL,
      mfaSecondFactor: {
        sms: false,
        otp: true,
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
      removalPolicy: removal,
    });

    // Pre-Token V2 trigger: must be wired via addTrigger(...) since the
    // L2 `lambdaTriggers.preTokenGenerationV2` shorthand isn't exposed
    // in CDK 2.250.0 (only V1 `preTokenGeneration` is). Without this,
    // the LambdaConfig.PreTokenGenerationConfig stays empty and the
    // Lambda never fires on auth.
    this.userPool.addTrigger(
      cognito.UserPoolOperation.PRE_TOKEN_GENERATION_CONFIG,
      this.preTokenLambda,
      cognito.LambdaVersion.V2_0,
    );

    // ── Cognito Groups ────────────────────────────────────────────────
    // New group set per Architecture A3 + phase-0a-revision.md scope.
    // `walker` group from original 0A is left as deprecated cruft (Cognito
    // can't delete groups once members were assigned, even if empty).
    // `caregiver` precedence moved from 1 → 6 to fit the new ordering.

    new cognito.CfnUserPoolGroup(this, 'InternalAdminGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'internal_admin',
      description: 'GoSteady internal — full read/write across all clients (MFA required)',
      precedence: 1,
    });

    new cognito.CfnUserPoolGroup(this, 'InternalSupportGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'internal_support',
      description: 'GoSteady internal — read-only across all clients (MFA required)',
      precedence: 2,
    });

    new cognito.CfnUserPoolGroup(this, 'ClientAdminGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'client_admin',
      description: 'Customer — full read/write within their client (MFA required)',
      precedence: 3,
    });

    new cognito.CfnUserPoolGroup(this, 'FacilityAdminGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'facility_admin',
      description: 'Customer — full read/write within their facility (MFA required)',
      precedence: 4,
    });

    new cognito.CfnUserPoolGroup(this, 'HouseholdOwnerGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'household_owner',
      description: 'D2C — primary signer for one synthetic household client',
      precedence: 5,
    });

    new cognito.CfnUserPoolGroup(this, 'CaregiverGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'caregiver',
      description: 'Customer — view + ack alerts within assigned censuses',
      precedence: 6,
    });

    new cognito.CfnUserPoolGroup(this, 'FamilyViewerGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'family_viewer',
      description: 'D2C — read-only access to specific linked patients',
      precedence: 7,
    });

    new cognito.CfnUserPoolGroup(this, 'PatientGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'patient',
      description: 'Walker user with portal account (rare; D2C-only)',
      precedence: 8,
    });

    // Deprecated `walker` group — left as cruft per D1 of phase-0a-revision.md.
    // Cognito can't delete groups; leaving it inert avoids breaking any test
    // users still in it. New users go into `patient` group instead.
    // Construct ID kept as `WalkerGroup` to match the existing deployed
    // resource (CFN updates description/precedence in place rather than
    // create+destroy, which would fail because group names can't collide).
    new cognito.CfnUserPoolGroup(this, 'WalkerGroup', {
      userPoolId: this.userPool.userPoolId,
      groupName: 'walker',
      description: 'DEPRECATED — replaced by patient group; do not assign new users',
      precedence: 99,
    });

    // ── Portal-Customer App Client ────────────────────────────────────
    // Existing client (1q9l9ujtsomf3ugq2tnqvdg6d7) — repurposed.
    // Token validity tightened from 1 hr → 15 min idle per L7 of phase-0a-revision.md.
    this.portalCustomerClient = this.userPool.addClient('PortalClient', {
      userPoolClientName: `gosteady-${p}-portal-customer`,
      authFlows: {
        userPassword: true, // legacy; SRP preferred
        userSrp: true,
      },
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: [
          'http://localhost:8080/callback',
          ...(config.portalDomain ? [`https://${config.portalDomain}/callback`] : []),
        ],
        logoutUrls: [
          'http://localhost:8080/',
          ...(config.portalDomain ? [`https://${config.portalDomain}/`] : []),
        ],
      },
      idTokenValidity: cdk.Duration.minutes(config.customerTokenIdleMinutes),
      accessTokenValidity: cdk.Duration.minutes(config.customerTokenIdleMinutes),
      refreshTokenValidity: cdk.Duration.days(config.customerRefreshDays),
      preventUserExistenceErrors: true,
      // No client secret on customer client — public OAuth flow from Flutter web.
    });

    // ── Portal-Internal App Client ────────────────────────────────────
    // NEW — for GoSteady internal admin tool.
    // Tighter token lifetimes; client secret enabled (server-side tool can hold it).
    // No USER_PASSWORD_AUTH (SRP only) for tighter security.
    this.portalInternalClient = this.userPool.addClient('PortalInternalClient', {
      userPoolClientName: `gosteady-${p}-portal-internal`,
      generateSecret: true,
      authFlows: {
        userSrp: true,
        // No userPassword — internal tool uses SRP only
      },
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: [
          ...(config.internalCallbackUrl ? [config.internalCallbackUrl] : ['http://localhost:8090/callback']),
        ],
        logoutUrls: [
          ...(config.internalCallbackUrl ? [config.internalCallbackUrl.replace(/\/callback$/, '/')] : ['http://localhost:8090/']),
        ],
      },
      idTokenValidity: cdk.Duration.minutes(config.internalTokenIdleMinutes),
      accessTokenValidity: cdk.Duration.minutes(config.internalTokenIdleMinutes),
      // Refresh token validity = absolute session lifetime (4 hr).
      refreshTokenValidity: cdk.Duration.minutes(config.internalTokenAbsoluteMinutes),
      preventUserExistenceErrors: true,
    });

    // ── Outputs ──────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'UserPoolId', {
      value: this.userPool.userPoolId,
      exportName: `${p}-UserPoolId`,
    });
    new cdk.CfnOutput(this, 'UserPoolClientId', {
      value: this.portalCustomerClient.userPoolClientId,
      exportName: `${p}-PortalClientId`,
      description: 'Portal-Customer App Client ID (existing ID preserved across 0A revision)',
    });
    new cdk.CfnOutput(this, 'PortalInternalClientId', {
      value: this.portalInternalClient.userPoolClientId,
      exportName: `${p}-PortalInternalClientId`,
      description: 'Portal-Internal App Client ID (new in 0A revision)',
    });
    new cdk.CfnOutput(this, 'RoleAssignmentsTableName', {
      value: this.roleAssignmentsTable.tableName,
      exportName: `${p}-RoleAssignmentsTable`,
    });
    new cdk.CfnOutput(this, 'PreTokenLambdaName', {
      value: this.preTokenLambda.functionName,
      exportName: `${p}-PreTokenLambdaName`,
    });
  }
}
