import * as cdk from 'aws-cdk-lib/core';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { SecurityStack } from './security-stack.js';
import { IdentityTable } from '../constructs/identity-table.js';
import { TelemetryTable } from '../constructs/telemetry-table.js';

export interface DataStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  /** Security stack provides IdentityKey CMK for identity-bearing tables. */
  readonly securityStack: SecurityStack;
}

/**
 * Data Layer — Phase 0B + Phase 0B Revision
 *
 * Spec: docs/specs/phase-0b-revision.md
 *
 * Seven DynamoDB tables in two encryption tiers:
 *
 *   Identity-bearing (CMK-encrypted with IdentityKey from Phase 1.5):
 *     - Organizations         — single-table for Client/Facility/Census hierarchy
 *     - Patients              — patientId PK; DDB Streams for discharge cascade
 *     - Users                 — replaces user-profiles
 *     - DeviceAssignments     — assignment history (PK serial, SK assignedAt)
 *
 *   Telemetry (AWS-managed encryption — high volume; crypto-shred via
 *                                       IdentityKey FK orphaning):
 *     - Device Registry       — device inventory + lifecycle metadata
 *     - Activity Series       — patient-centric, 13-mo TTL
 *     - Alert History         — patient-centric, 24-mo TTL
 *
 * **Destructive change in dev** — PK migrations (Activity, Alerts) cannot
 * be done in place; the existing tables are dropped and recreated. The
 * legacy `user-profiles` table is removed entirely (replaced by `users`).
 *
 * Phase 0B revision spec covers full schema details and decision rationale.
 */
export class DataStack extends cdk.Stack {
  // ── Identity-bearing tables ───────────────────────────────────────
  /** Organizations — single-table for Client/Facility/Census hierarchy. */
  public readonly organizationsTable: dynamodb.Table;
  /** Patients — DDB Streams emit on status flips for Phase 2A discharge cascade. */
  public readonly patientsTable: dynamodb.Table;
  /** Users — replaces the deprecated `user-profiles` table. */
  public readonly usersTable: dynamodb.Table;
  /** DeviceAssignments — assignment history; active = (validUntil == null). */
  public readonly deviceAssignmentsTable: dynamodb.Table;

  // ── Telemetry tables ──────────────────────────────────────────────
  /** Device Registry — inventory + lifecycle (NEW: activated_at, ownership fields). */
  public readonly deviceTable: dynamodb.Table;
  /** Activity Series — PK migrated serialNumber → patientId; 13-mo TTL on expiresAt. */
  public readonly activityTable: dynamodb.Table;
  /** Alert History — PK migrated serialNumber → patientId; 24-mo TTL on expiresAt. */
  public readonly alertTable: dynamodb.Table;

  constructor(scope: Construct, id: string, props: DataStackProps) {
    super(scope, id, props);

    const { config, securityStack } = props;
    const p = config.prefix;
    const identityKey = securityStack.identityKey;

    // ──────────────────────────────────────────────────────────────
    // Identity-bearing tables (CMK-encrypted)
    // ──────────────────────────────────────────────────────────────

    // ── Organizations ─────────────────────────────────────────────
    // Single-table for Client/Facility/Census hierarchy. PK=clientId.
    // SK conventions:
    //   META#client                                    — client root
    //   facility#<facilityId>                          — facility row
    //   facility#<facilityId>#census#<censusId>        — census row
    // Access patterns are PK-key only; no GSIs in v1 (see 0B-rev D4).
    const organizations = new IdentityTable(this, 'Organizations', {
      config,
      tableSuffix: 'organizations',
      partitionKey: { name: 'clientId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'sk', type: dynamodb.AttributeType.STRING },
      identityKey,
    });
    this.organizationsTable = organizations.table;

    // ── Patients ──────────────────────────────────────────────────
    // PK=patientId (opaque UUID). DDB Streams enabled for discharge
    // cascade Lambda (Phase 2A) per L17.
    const patients = new IdentityTable(this, 'Patients', {
      config,
      tableSuffix: 'patients',
      partitionKey: { name: 'patientId', type: dynamodb.AttributeType.STRING },
      identityKey,
      stream: dynamodb.StreamViewType.NEW_AND_OLD_IMAGES,
    });
    this.patientsTable = patients.table;

    // GSI by-client-status: list active patients per client.
    this.patientsTable.addGlobalSecondaryIndex({
      indexName: 'by-client-status',
      partitionKey: { name: 'clientId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'status_patientId', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // GSI by-census-status: census roster.
    this.patientsTable.addGlobalSecondaryIndex({
      indexName: 'by-census-status',
      partitionKey: { name: 'censusId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'status_patientId', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ── Users ─────────────────────────────────────────────────────
    // PK=userId (Cognito sub). Replaces the deprecated user-profiles table.
    const users = new IdentityTable(this, 'Users', {
      config,
      tableSuffix: 'users',
      partitionKey: { name: 'userId', type: dynamodb.AttributeType.STRING },
      identityKey,
    });
    this.usersTable = users.table;

    // GSI by-client: list users per tenant.
    this.usersTable.addGlobalSecondaryIndex({
      indexName: 'by-client',
      partitionKey: { name: 'clientId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'userId', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ── DeviceAssignments ─────────────────────────────────────────
    // PK=serialNumber, SK=assignedAt. Active = (validUntil == null).
    // GSI by-patient: lookup current device for patient + history.
    const deviceAssignments = new IdentityTable(this, 'DeviceAssignments', {
      config,
      tableSuffix: 'device-assignments',
      partitionKey: { name: 'serialNumber', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'assignedAt', type: dynamodb.AttributeType.STRING },
      identityKey,
    });
    this.deviceAssignmentsTable = deviceAssignments.table;

    this.deviceAssignmentsTable.addGlobalSecondaryIndex({
      indexName: 'by-patient',
      partitionKey: { name: 'patientId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'assignedAt', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ──────────────────────────────────────────────────────────────
    // Telemetry tables (AWS-managed encryption)
    // ──────────────────────────────────────────────────────────────

    // ── Device Registry ───────────────────────────────────────────
    // PK=serialNumber. NEW attributes (DDB schemaless additions):
    //   activated_at, firstHeartbeatAt, decommissionReason,
    //   owningClientId, owningFacilityId, currentAssignmentSk
    // GSI by-owning-client replaces the deprecated by-walker GSI.
    const devices = new TelemetryTable(this, 'DeviceRegistry', {
      config,
      tableSuffix: 'devices',
      partitionKey: { name: 'serialNumber', type: dynamodb.AttributeType.STRING },
    });
    this.deviceTable = devices.table;

    this.deviceTable.addGlobalSecondaryIndex({
      indexName: 'by-owning-client',
      partitionKey: { name: 'owningClientId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'status_serial', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ── Activity Series ───────────────────────────────────────────
    // PK migrated: serialNumber → patientId.
    // SK: timestamp (sessionEnd UTC ISO 8601).
    // TTL: expiresAt (epoch seconds, sessionEnd + 13 months) — set by writer.
    const activity = new TelemetryTable(this, 'ActivitySeries', {
      config,
      tableSuffix: 'activity',
      partitionKey: { name: 'patientId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'timestamp', type: dynamodb.AttributeType.STRING },
      ttlAttribute: 'expiresAt',
    });
    this.activityTable = activity.table;

    // GSI by-date — keyed by patientId now (was serialNumber).
    this.activityTable.addGlobalSecondaryIndex({
      indexName: 'by-date',
      partitionKey: { name: 'patientId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'date', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // GSI by-census-date — unit-level reporting (NEW).
    this.activityTable.addGlobalSecondaryIndex({
      indexName: 'by-census-date',
      partitionKey: { name: 'censusId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'date_patientId', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // GSI by-client-time — client-wide feed (NEW).
    this.activityTable.addGlobalSecondaryIndex({
      indexName: 'by-client-time',
      partitionKey: { name: 'clientId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'timestamp', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ── Alert History ─────────────────────────────────────────────
    // PK migrated: serialNumber → patientId.
    // SK: compound `{eventTimestamp}#{alertType}` (preserved from 1B original).
    // TTL: expiresAt (epoch seconds, eventTimestamp + 24 months).
    const alerts = new TelemetryTable(this, 'AlertHistory', {
      config,
      tableSuffix: 'alerts',
      partitionKey: { name: 'patientId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'timestamp', type: dynamodb.AttributeType.STRING },
      ttlAttribute: 'expiresAt',
    });
    this.alertTable = alerts.table;

    // GSI by-census-time (NEW).
    this.alertTable.addGlobalSecondaryIndex({
      indexName: 'by-census-time',
      partitionKey: { name: 'censusId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'timestamp', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // GSI by-client-time (NEW).
    this.alertTable.addGlobalSecondaryIndex({
      indexName: 'by-client-time',
      partitionKey: { name: 'clientId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'timestamp', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ──────────────────────────────────────────────────────────────
    // Outputs
    // ──────────────────────────────────────────────────────────────

    new cdk.CfnOutput(this, 'OrganizationsTableName', {
      value: this.organizationsTable.tableName,
      exportName: `${p}-OrganizationsTable`,
    });
    new cdk.CfnOutput(this, 'PatientsTableName', {
      value: this.patientsTable.tableName,
      exportName: `${p}-PatientsTable`,
    });
    new cdk.CfnOutput(this, 'PatientsStreamArn', {
      value: this.patientsTable.tableStreamArn ?? 'N/A',
      exportName: `${p}-PatientsStreamArn`,
      description: 'Patients DDB Stream — consumed by Phase 2A discharge-cascade Lambda',
    });
    new cdk.CfnOutput(this, 'UsersTableName', {
      value: this.usersTable.tableName,
      exportName: `${p}-UsersTable`,
    });
    new cdk.CfnOutput(this, 'DeviceAssignmentsTableName', {
      value: this.deviceAssignmentsTable.tableName,
      exportName: `${p}-DeviceAssignmentsTable`,
    });
    new cdk.CfnOutput(this, 'DeviceTableName', {
      value: this.deviceTable.tableName,
      exportName: `${p}-DeviceTable`,
    });
    new cdk.CfnOutput(this, 'ActivityTableName', {
      value: this.activityTable.tableName,
      exportName: `${p}-ActivityTable`,
    });
    new cdk.CfnOutput(this, 'AlertTableName', {
      value: this.alertTable.tableName,
      exportName: `${p}-AlertTable`,
    });
  }
}
