import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { DataStack } from './data-stack.js';

export interface IntegrationStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  readonly dataStack: DataStack;
}

/**
 * Integration & Interoperability — FHIR R4, HL7, EMR connectivity.
 *
 * Phase 4 will implement:
 *
 *   4A — FHIR Projection Layer
 *       Lambda that transforms internal GoSteady data → FHIR R4 JSON.
 *       Resource mappings:
 *         Patient       → walker user demographics
 *         Observation   → steps (LOINC 55423-8), distance, active minutes
 *         Device        → walker cap (serial, firmware, battery)
 *         RelatedPerson → caregiver relationship
 *       Called by FHIR API handlers — no direct DB access by external systems.
 *       API routes added to API Gateway: /fhir/R4/Patient, /fhir/R4/Observation, etc.
 *
 *   4B — Outbound Integration
 *       SQS → Lambda pipeline for pushing data to external systems.
 *       Transforms events → HL7v2 ORU/ADT or FHIR Bundle.
 *       Targets: Rhapsody, Mirth Connect, EMR REST APIs.
 *       Per-partner config stored in DynamoDB (endpoint, format, credentials).
 *       Tip-over → ADT to EMR in real-time.
 *       Activity summary → ORU batch to integration engine.
 *
 *   4C — Bulk Data Export
 *       Nightly EventBridge cron → Export Lambda → FHIR NDJSON to S3.
 *       Conforms to FHIR Bulk Data Access (IG) spec.
 *       EMRs / analytics platforms pull via pre-signed URLs.
 *       Partitioned by date + org for multi-tenant.
 *       S3 lifecycle: archive to Glacier after 90 days.
 */
export class IntegrationStack extends cdk.Stack {
  // Public properties will be added:
  // public readonly fhirProjection: lambda.Function;
  // public readonly outboundIntegration: lambda.Function;
  // public readonly exportBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: IntegrationStackProps) {
    super(scope, id, props);

    const { config, dataStack } = props;
    const p = config.prefix;

    // ── Phase 4A: FHIR Projection ────────────────────────────────
    // TODO: FHIR Projection Lambda (Python, lambda/fhir-projection/)
    //       - dataStack.activityTable read
    //       - dataStack.deviceTable read
    //       - dataStack.userProfileTable read
    // TODO: /fhir/R4/* routes on API Gateway (wired from ApiStack)

    // ── Phase 4B: Outbound Integration ───────────────────────────
    // TODO: Outbound Integration Lambda (Python, lambda/outbound-integration/)
    //       - Reads from SQS integration queue (NotificationStack)
    //       - Partner config table (DynamoDB)
    //       - Secrets Manager for partner auth credentials

    // ── Phase 4C: Bulk Data Export ───────────────────────────────
    // TODO: S3 export bucket (lifecycle → Glacier after 90d)
    // TODO: Export Lambda (Python, lambda/bulk-export/)
    //       - dataStack.activityTable read
    //       - S3 write
    // TODO: EventBridge cron rule (nightly at 02:00 UTC)

    new cdk.CfnOutput(this, 'Status', {
      value: 'SCAFFOLD — Phase 4 pending',
    });
  }
}
