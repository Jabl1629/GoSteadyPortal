import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { AuthStack } from './auth-stack.js';
import { DataStack } from './data-stack.js';

export interface ApiStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  readonly authStack: AuthStack;
  readonly dataStack: DataStack;
}

/**
 * API Layer — API Gateway + Lambda handlers.
 *
 * Phase 2A will implement:
 *   - HTTP API (API Gateway v2) with Cognito JWT authorizer
 *   - Lambda handlers for portal routes (/api/v1/*)
 *   - Lambda handlers for FHIR routes (/fhir/R4/*) — wired in integration stack
 *   - CORS configuration for portal domain
 *   - Rate limiting + request validation
 *
 * Portal Routes:
 *   GET  /api/v1/device/{serial}              → device health + status
 *   GET  /api/v1/activity/{serial}?range=...  → activity data (24h|7d|30d|6m)
 *   GET  /api/v1/alerts/{serial}              → alert history
 *   GET  /api/v1/me/walkers                   → caregiver's linked walkers
 *   POST /api/v1/device/activate              → link serial to user account
 *
 * Role Scoping:
 *   - Walker: can only access own device + activity data
 *   - Caregiver: can access all linked walkers' data (via relationships table)
 *   - Scoping enforced in Lambda handler, not API Gateway
 */
export class ApiStack extends cdk.Stack {
  // Public properties will be added:
  // public readonly httpApi: apigatewayv2.HttpApi;

  constructor(scope: Construct, id: string, props: ApiStackProps) {
    super(scope, id, props);

    const { config, authStack, dataStack } = props;
    const p = config.prefix;

    // ── Phase 2A: API Gateway + Handlers ─────────────────────────
    // TODO: HTTP API with Cognito JWT authorizer (authStack.userPool)
    // TODO: API handler Lambda (Python, lambda/api-handlers/)
    //       - dataStack.deviceTable read
    //       - dataStack.activityTable read
    //       - dataStack.alertTable read
    //       - authStack.relationshipsTable read
    //       - dataStack.userProfileTable read
    // TODO: Route definitions (/api/v1/*)
    // TODO: CORS (localhost:8080 + portal domain)
    // TODO: Throttling (100 rps burst, 50 rps sustained)

    new cdk.CfnOutput(this, 'Status', {
      value: 'SCAFFOLD — Phase 2A pending',
    });
  }
}
