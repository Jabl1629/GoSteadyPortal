import * as cdk from 'aws-cdk-lib/core';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
import * as path from 'path';
import { GoSteadyEnvConfig } from '../config.js';
import { AuthStack } from './auth-stack.js';

export interface D2CAuthStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  /** Facility AuthStack — we reuse its RoleAssignments table (shared; tenancy
   *  boundary is clientId, not pool). The D2C pre-token reads it. */
  readonly authStack: AuthStack;
}

/**
 * D2C Authentication — GoSteady D2C Phase 1.
 *
 * Spec: docs/specs/d2c-phase1-walker-activation.md §3.1
 *
 * A SEPARATE Cognito User Pool for the direct-to-consumer household
 * product. Decided in d2c.md L5: not HIPAA-required (Cognito is HIPAA-
 * eligible under a BAA), but a clean scoping boundary — D2C is not a HIPAA
 * Covered-Entity relationship; the facility tier eventually is. Separate
 * pools let D2C use SMS-OTP + softer rules without touching facility-staff
 * auth, and keep "where PHI lives" structural. Easy to start separate,
 * catastrophic to split later.
 *
 *   • User Pool with SMS-OTP custom auth (passwordless):
 *       - email sign-in alias; phone_number required (the OTP channel)
 *       - custom:clientId / role / isWalkerUser / facilities / censuses
 *   • One public App Client (D2C-Portal) — CUSTOM_AUTH flow only.
 *   • Custom-auth trigger Lambda (Define / Create / Verify) — SMS-OTP.
 *   • Pre-Token Generation V2 Lambda — injects dtc_* claims with the
 *     bootstrap default for pre-claim signups.
 *
 * Shared with facility tier: the RoleAssignments table (read by the D2C
 * pre-token). Cognito `sub`s from two pools never collide.
 */
export class D2CAuthStack extends cdk.Stack {
  /** D2C User Pool — imported by ApiStack for the second JWT authorizer. */
  public readonly userPool: cognito.UserPool;
  /** D2C-Portal public App Client. */
  public readonly portalClient: cognito.UserPoolClient;

  constructor(scope: Construct, id: string, props: D2CAuthStackProps) {
    super(scope, id, props);

    const { config, authStack } = props;
    const p = config.prefix;
    const isProd = p === 'prod';
    const removal = isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY;
    const logRetention = isProd ? logs.RetentionDays.THREE_MONTHS : logs.RetentionDays.ONE_MONTH;

    // ── Twilio credentials secret (SMS OTP sender) ────────────────────
    // The dev AWS account has no SNS SMS origination identity ("No
    // origination entities available to send"), and US A2P SMS needs 10DLC
    // registration regardless — so D2C uses Twilio (the production path;
    // pulled forward from Phase 2). This secret is created EMPTY: the value
    // (account_sid / auth_token / from) is populated out-of-band by an
    // operator (AWS console or CLI) so the Twilio auth token never lands in
    // source control, CloudFormation, or chat. See
    // docs/playbooks/d2c-twilio-setup.md. The custom-auth Lambda reads it at
    // runtime; until populated, the OTP flow fails closed.
    const twilioSecret = new secretsmanager.Secret(this, 'D2CTwilioSecret', {
      secretName: `gosteady/${p}/twilio`,
      description:
        'Twilio creds for D2C SMS OTP — JSON {account_sid, auth_token, from}. ' +
        'Populate out-of-band; see docs/playbooks/d2c-twilio-setup.md.',
      removalPolicy: removal,
    });

    // ── Custom-auth trigger Lambda (SMS-OTP via Twilio) ───────────────
    const customAuthLambda = new lambda.Function(this, 'D2CCustomAuth', {
      functionName: `gosteady-${p}-d2c-custom-auth`,
      runtime: lambda.Runtime.PYTHON_3_12,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(
        path.join(__dirname, '..', '..', 'lambda', 'd2c-custom-auth'),
      ),
      memorySize: 128,
      timeout: cdk.Duration.seconds(5), // auth-path: respond fast
      tracing: lambda.Tracing.ACTIVE,
      environment: {
        ENVIRONMENT: p,
        TWILIO_SECRET_ARN: twilioSecret.secretArn,
      },
      logRetention,
      description: 'D2C SMS-OTP custom-auth (Define/Create/Verify) via Twilio — Phase 1',
    });

    // Lambda reads the Twilio creds at runtime (cached per cold start).
    twilioSecret.grantRead(customAuthLambda);

    // ── Pre-Token Generation V2 Lambda ────────────────────────────────
    const preTokenLambda = new lambda.Function(this, 'D2CPreToken', {
      functionName: `gosteady-${p}-d2c-pre-token`,
      runtime: lambda.Runtime.PYTHON_3_12,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(
        path.join(__dirname, '..', '..', 'lambda', 'd2c-pre-token'),
      ),
      memorySize: 256,
      timeout: cdk.Duration.seconds(5),
      tracing: lambda.Tracing.ACTIVE,
      environment: {
        ROLE_ASSIGNMENTS_TABLE: authStack.roleAssignmentsTable.tableName,
        ENVIRONMENT: p,
      },
      logRetention,
      description: 'D2C Pre-Token V2 — dtc_* claims injection (bootstrap default pre-claim)',
    });
    authStack.roleAssignmentsTable.grantReadData(preTokenLambda);

    // ── D2C User Pool ─────────────────────────────────────────────────
    this.userPool = new cognito.UserPool(this, 'D2CUserPool', {
      userPoolName: `gosteady-${p}-d2c`,
      selfSignUpEnabled: true,
      signInAliases: { email: true },
      autoVerify: { email: true },
      standardAttributes: {
        fullname: { required: true, mutable: true },
        email: { required: true, mutable: false },
        // phone_number is the OTP channel — required at signup.
        phoneNumber: { required: true, mutable: true },
      },
      customAttributes: {
        role: new cognito.StringAttribute({ mutable: true, minLen: 4, maxLen: 16 }),
        clientId: new cognito.StringAttribute({ mutable: true, minLen: 0, maxLen: 64 }),
        isWalkerUser: new cognito.StringAttribute({ mutable: true, minLen: 0, maxLen: 8 }),
        facilities: new cognito.StringAttribute({ mutable: true, minLen: 0, maxLen: 2048 }),
        censuses: new cognito.StringAttribute({ mutable: true, minLen: 0, maxLen: 2048 }),
      },
      // Passwordless: SMS-OTP via custom auth is the only factor. A password
      // is still required at the Cognito API level for self-signup, so we
      // set a strong policy; the app generates a random throwaway password
      // at signup (the user never sees or uses it — they always SMS-OTP in).
      passwordPolicy: {
        minLength: 14,
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: true,
      },
      mfa: cognito.Mfa.OFF, // SMS-OTP custom auth IS the factor; no separate MFA
      lambdaTriggers: {
        defineAuthChallenge: customAuthLambda,
        createAuthChallenge: customAuthLambda,
        verifyAuthChallengeResponse: customAuthLambda,
      },
      userVerification: {
        emailSubject: 'GoSteady — Verify your email',
        emailBody:
          'Welcome to GoSteady!\n\n' +
          'Your verification code is: {####}\n\n' +
          '— The GoSteady Team',
        emailStyle: cognito.VerificationEmailStyle.CODE,
      },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      removalPolicy: removal,
    });

    // Pre-Token V2 via addTrigger (the lambdaTriggers shorthand only wires
    // V1; see auth-stack.ts note). V2 is required for access-token claim
    // overrides.
    this.userPool.addTrigger(
      cognito.UserPoolOperation.PRE_TOKEN_GENERATION_CONFIG,
      preTokenLambda,
      cognito.LambdaVersion.V2_0,
    );

    // ── D2C-Portal App Client ─────────────────────────────────────────
    this.portalClient = this.userPool.addClient('D2CPortalClient', {
      userPoolClientName: `gosteady-${p}-d2c-portal`,
      authFlows: {
        custom: true, // CUSTOM_AUTH (SMS-OTP) is the only flow
      },
      idTokenValidity: cdk.Duration.minutes(config.customerTokenIdleMinutes),
      accessTokenValidity: cdk.Duration.minutes(config.customerTokenIdleMinutes),
      refreshTokenValidity: cdk.Duration.days(config.customerRefreshDays),
      preventUserExistenceErrors: true,
      // Public client — no secret (Flutter web).
    });

    // ── Outputs ──────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'D2CUserPoolId', {
      value: this.userPool.userPoolId,
      exportName: `${p}-D2CUserPoolId`,
    });
    new cdk.CfnOutput(this, 'D2CPortalClientId', {
      value: this.portalClient.userPoolClientId,
      exportName: `${p}-D2CPortalClientId`,
      description: 'D2C-Portal public App Client ID',
    });
    new cdk.CfnOutput(this, 'D2CUserPoolProviderUrl', {
      value: this.userPool.userPoolProviderUrl,
      exportName: `${p}-D2CUserPoolProviderUrl`,
      description: 'D2C pool issuer URL (for the API multi-issuer authorizer)',
    });
    new cdk.CfnOutput(this, 'D2CTwilioSecretArn', {
      value: twilioSecret.secretArn,
      exportName: `${p}-D2CTwilioSecretArn`,
      description: 'Secrets Manager ARN — populate with Twilio creds (see d2c-twilio-setup.md)',
    });
  }
}
