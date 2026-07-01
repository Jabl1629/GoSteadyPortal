import * as cdk from 'aws-cdk-lib/core';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as iot from 'aws-cdk-lib/aws-iot';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatch_actions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as events from 'aws-cdk-lib/aws-events';
import * as events_targets from 'aws-cdk-lib/aws-events-targets';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as path from 'path';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { DataStack } from './data-stack.js';
import { SecurityStack } from './security-stack.js';
import { ProcessingLambda } from '../constructs/processing-lambda.js';

export interface ProcessingStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  /**
   * DataStack is kept as a CDK-level dep (so CFN deploy ordering still
   * waits for Data tables before Processing handlers run), but actual
   * table refs go through `Table.fromTableName` so we don't generate
   * CFN cross-stack ImportValues. This avoids the "cannot delete
   * export in use" deadlock when DataStack does PK migrations.
   * Phase 0B revision §Implementation note.
   */
  readonly dataStack: DataStack;
  /**
   * SecurityStack provides the IdentityKey CMK ARN (via cross-stack output)
   * so handlers that read CMK-encrypted Patients / DeviceAssignments can
   * be granted `kms:Decrypt` + `kms:GenerateDataKey`. Phase 1B revision L15
   * narrowed to actual readers (heartbeat-processor doesn't read those tables).
   */
  readonly securityStack: SecurityStack;
}

/**
 * Processing — Lambda functions that validate, transform, and react
 * to incoming device data.
 *
 * Phase 1B revision (2026-04-27): patient-centric refactor.
 *   - activity-processor: ARM64 + Powertools + patient resolution + hierarchy snapshot
 *   - heartbeat-processor: slimmed to Shadow update + activation-ack only
 *   - threshold-detector: NEW Lambda triggered by Shadow update/accepted IoT Rule
 *     (replaces heartbeat-processor's threshold-checking role)
 *   - alert-handler: ARM64 + Powertools + patient resolution + hierarchy snapshot
 *
 * Deployed before Ingestion so IoT Rules can reference these Lambdas.
 */
export class ProcessingStack extends cdk.Stack {
  public readonly activityProcessor: lambda.Function;
  public readonly heartbeatProcessor: lambda.Function;
  public readonly thresholdDetector: lambda.Function;
  public readonly alertHandler: lambda.Function;
  public readonly connectionCoordinator: lambda.Function;
  public readonly behavioralDetector: lambda.Function;

  constructor(scope: Construct, id: string, props: ProcessingStackProps) {
    super(scope, id, props);

    const { config, securityStack } = props;
    const p = config.prefix;
    const account = cdk.Stack.of(this).account;
    const region = cdk.Stack.of(this).region;

    const lambdaDir = path.join(__dirname, '..', '..', 'lambda');

    // ── Table references via fromTableName ────────────────────────
    // Phase 0B revision: refs decoupled from DataStack at the CFN level.
    const deviceTable = dynamodb.Table.fromTableName(this, 'DeviceTableRef', `gosteady-${p}-devices`);
    const activityTable = dynamodb.Table.fromTableName(this, 'ActivityTableRef', `gosteady-${p}-activity`);
    const alertTable = dynamodb.Table.fromTableName(this, 'AlertTableRef', `gosteady-${p}-alerts`);
    const patientsTable = dynamodb.Table.fromTableName(this, 'PatientsTableRef', `gosteady-${p}-patients`);
    const deviceAssignmentsTable = dynamodb.Table.fromTableName(
      this,
      'DeviceAssignmentsTableRef',
      `gosteady-${p}-device-assignments`,
    );

    // ── IdentityKey CMK reference ─────────────────────────────────
    // Imported by ARN so handlers that read CMK-encrypted Patients /
    // DeviceAssignments tables can be granted Decrypt + GenerateDataKey.
    const identityKey = kms.Key.fromKeyArn(
      this,
      'IdentityKeyRef',
      securityStack.identityKey.keyArn,
    );

    // ── Shared Lambda environment ─────────────────────────────────
    const commonEnv = {
      DEVICE_TABLE: deviceTable.tableName,
      ACTIVITY_TABLE: activityTable.tableName,
      ALERT_TABLE: alertTable.tableName,
      PATIENTS_TABLE: patientsTable.tableName,
      DEVICE_ASSIGNMENTS_TABLE: deviceAssignmentsTable.tableName,
      ENVIRONMENT: p,
    };

    // ── Powertools Lambda layer (Phase 1.6) ──────────────────────
    // AWS-managed layer; pinned ARN per env in config.ts.
    const powertoolsLayer = lambda.LayerVersion.fromLayerVersionArn(
      this,
      'PowertoolsLayer',
      config.powertoolsLayerArn,
    );

    // ── Activity Processor (refactored) ──────────────────────────
    const activityProc = new ProcessingLambda(this, 'ActivityProcessor', {
      config,
      functionName: `gosteady-${p}-activity-processor`,
      handlerDir: path.join(lambdaDir, 'activity-processor'),
      description: 'Phase 1B revision: patient-centric activity ingest with hierarchy snapshot',
      memoryMb: config.processingLambdaMemoryMb,
      timeoutSeconds: config.processingLambdaTimeoutSeconds,
      environment: commonEnv,
      powertoolsLayer,
      tracingActive: true,
    });
    this.activityProcessor = activityProc.function;
    // Preserve pre-1B-revision CFN logical ID so CFN does an in-place
    // UPDATE rather than CREATE+DELETE (Lambda names are region-unique
    // and the CREATE-new-before-DELETE-old order would otherwise collide).
    (this.activityProcessor.node.defaultChild as cdk.CfnResource).overrideLogicalId(
      'ActivityProcessor38C14121',
    );

    activityTable.grantWriteData(this.activityProcessor);
    deviceAssignmentsTable.grantReadData(this.activityProcessor);
    // ReadWrite on Patients: 2A-UM-P L10 auto-resume REMOVEs
    // notificationsPaused on fresh activity. The write grant was missed
    // when that handler code landed (2026-05-24) — the best-effort catch
    // swallowed AccessDeniedException ever since; surfaced by the DT-0
    // smoke suite (T12) on 2026-07-01. Read side unchanged (resolution).
    patientsTable.grantReadWriteData(this.activityProcessor);
    identityKey.grantDecrypt(this.activityProcessor);
    identityKey.grant(this.activityProcessor, 'kms:GenerateDataKey');

    // ── Heartbeat Processor (slimmed) ────────────────────────────
    const heartbeatProc = new ProcessingLambda(this, 'HeartbeatProcessor', {
      config,
      functionName: `gosteady-${p}-heartbeat-processor`,
      handlerDir: path.join(lambdaDir, 'heartbeat-processor'),
      description: 'Phase 1B revision: Shadow update + activation-ack only (slim)',
      memoryMb: config.processingHeartbeatMemoryMb,
      timeoutSeconds: config.processingLambdaTimeoutSeconds,
      environment: {
        ...commonEnv,
        ACTIVATION_ACK_WINDOW_HOURS: String(config.activationAckWindowHours),
      },
      powertoolsLayer,
      tracingActive: true,
    });
    this.heartbeatProcessor = heartbeatProc.function;

    (this.heartbeatProcessor.node.defaultChild as cdk.CfnResource).overrideLogicalId(
      'HeartbeatProcessorCDD753A4',
    );

    deviceTable.grantReadWriteData(this.heartbeatProcessor);
    // Shadow get + update for Shadow.reported reads/writes. Get added
    // 2026-05-17 for the AA-recycle DL16 battery-swap detection path
    // (`_maybe_emit_battery_swapped` reads prior boot_count from
    // Shadow.reported before overwriting it). Wipe-ack path also clears
    // Shadow.desired.wipe_requested. Targets the device's own thing.
    this.heartbeatProcessor.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ShadowGetAndUpdateOnAnyThing',
        actions: ['iot:GetThingShadow', 'iot:UpdateThingShadow'],
        resources: [`arn:aws:iot:${region}:${account}:thing/*`],
      }),
    );

    // ── Threshold Detector (NEW) ─────────────────────────────────
    const thresholdDet = new ProcessingLambda(this, 'ThresholdDetector', {
      config,
      functionName: `gosteady-${p}-threshold-detector`,
      handlerDir: path.join(lambdaDir, 'threshold-detector'),
      description: 'Phase 1B revision: synthetic alerts from Shadow update/accepted',
      memoryMb: config.processingLambdaMemoryMb,
      timeoutSeconds: config.processingLambdaTimeoutSeconds,
      environment: {
        ...commonEnv,
        PRE_ACTIVATION_AUDIT_SAMPLE_HOURS: String(config.preActivationAuditSampleHours),
      },
      powertoolsLayer,
      tracingActive: true,
    });
    this.thresholdDetector = thresholdDet.function;

    deviceTable.grantReadData(this.thresholdDetector);
    alertTable.grantReadWriteData(this.thresholdDetector);
    deviceAssignmentsTable.grantReadData(this.thresholdDetector);
    // ReadWrite on Patients: alert recurrence policy (2026-05-26-alert-
    // recurrence-policy.md L3) maintains a Patient.openAlerts map via
    // conditional UpdateItem to gate continuous-condition alert writes.
    patientsTable.grantReadWriteData(this.thresholdDetector);
    identityKey.grantDecrypt(this.thresholdDetector);
    identityKey.grant(this.thresholdDetector, 'kms:GenerateDataKey');
    this.thresholdDetector.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ShadowGetAndUpdateOnAnyThing',
        actions: ['iot:GetThingShadow', 'iot:UpdateThingShadow'],
        resources: [`arn:aws:iot:${region}:${account}:thing/*`],
      }),
    );

    // ── Alert Handler (refactored) ───────────────────────────────
    const alertHand = new ProcessingLambda(this, 'AlertHandler', {
      config,
      functionName: `gosteady-${p}-alert-handler`,
      handlerDir: path.join(lambdaDir, 'alert-handler'),
      description: 'Phase 1B revision: patient-centric device alert ingest with hierarchy snapshot',
      memoryMb: config.processingLambdaMemoryMb,
      timeoutSeconds: config.processingLambdaTimeoutSeconds,
      environment: commonEnv,
      powertoolsLayer,
      tracingActive: true,
    });
    this.alertHandler = alertHand.function;
    (this.alertHandler.node.defaultChild as cdk.CfnResource).overrideLogicalId(
      'AlertHandler13C27ADA',
    );

    alertTable.grantWriteData(this.alertHandler);
    deviceAssignmentsTable.grantReadData(this.alertHandler);
    patientsTable.grantReadData(this.alertHandler);
    identityKey.grantDecrypt(this.alertHandler);
    identityKey.grant(this.alertHandler, 'kms:GenerateDataKey');

    // ── Connection Coordinator (coord §C23) ──────────────────────
    // Addresses §C22 Finding 2: AWS IoT MQTT 3.1.1 persistent_session
    // 1h timer expires before firmware's 1h heartbeat → broker drops
    // queued cmds every cycle. This Lambda subscribes to lifecycle
    // events ($aws/events/presence/connected/+) and re-publishes any
    // pending cmds for the connecting serial within milliseconds, so
    // the cmd lands in the active subscription window before firmware
    // disconnects.
    //
    // Also folds in §C22 Finding 7: opportunistic sweep of stale
    // outstandingActivationCmds / outstandingWipeCmds entries on the
    // same DDB GetItem (no separate sweeper Lambda needed).
    const coordinator = new ProcessingLambda(this, 'ConnectionCoordinator', {
      config,
      functionName: `gosteady-${p}-connection-coordinator`,
      handlerDir: path.join(lambdaDir, 'connection-coordinator'),
      description: 'Coord §C23: re-publish pending cmds on firmware connect (AWS IoT 1h persistent_session workaround)',
      memoryMb: config.processingHeartbeatMemoryMb,
      timeoutSeconds: config.processingLambdaTimeoutSeconds,
      environment: {
        DEVICE_TABLE: deviceTable.tableName,
        ENVIRONMENT: p,
        ACK_WINDOW_HOURS: String(config.activationAckWindowHours),
      },
      powertoolsLayer,
      tracingActive: true,
    });
    this.connectionCoordinator = coordinator.function;

    // IAM: read+sweep on Device Registry, publish to gs/*/cmd
    deviceTable.grantReadWriteData(this.connectionCoordinator);
    this.connectionCoordinator.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'PublishToAnyDeviceCmd',
        actions: ['iot:Publish'],
        resources: [`arn:aws:iot:${region}:${account}:topic/gs/*/cmd`],
      }),
    );

    // IoT Topic Rule: filter on `connected` lifecycle events.
    // Topic pattern $aws/events/presence/connected/+ — `+` matches the
    // clientId (= device serial). SQL only forwards eventType='connected'
    // (defense-in-depth alongside the topic filter).
    const coordRule = new iot.CfnTopicRule(this, 'ConnectionCoordinatorRule', {
      ruleName: `gosteady_${p}_connection_coordinator`,
      topicRulePayload: {
        sql: "SELECT clientId, timestamp, eventType FROM '$aws/events/presence/connected/+' WHERE eventType = 'connected'",
        awsIotSqlVersion: '2016-03-23',
        ruleDisabled: false,
        description:
          'Coord §C23: forwards $aws/events/presence/connected events to connection-coordinator Lambda',
        actions: [
          {
            lambda: {
              functionArn: this.connectionCoordinator.functionArn,
            },
          },
        ],
      },
    });

    this.connectionCoordinator.addPermission('AllowIoTRuleInvoke', {
      principal: new iam.ServicePrincipal('iot.amazonaws.com'),
      action: 'lambda:InvokeFunction',
      sourceArn: coordRule.attrArn,
    });

    // ── Alarm: stale-cmd-sweep rate (coord §C23 ops signal) ──────
    // device_cmd_swept_stale_count > 5 in 1h indicates cmds aging out
    // of the 24h ack window without firmware ack — real reliability
    // problem that needs investigation. Note device.cmd_swept_stale
    // emits ONE audit event per Lambda invocation with swept_count in
    // extra, so this metric counts sweep-invocations not individual
    // cmds; threshold accordingly.
    const opsTopicArn = cdk.Fn.importValue(`${p}-CostAlarmTopic`);
    const opsTopic = sns.Topic.fromTopicArn(this, 'OpsTopicRef', opsTopicArn);

    const sweepMetric = new cloudwatch.Metric({
      namespace: `GoSteady/Coordinator/${p}`,
      metricName: 'device_cmd_swept_stale_count',
      period: cdk.Duration.hours(1),
      statistic: 'Sum',
    });
    const sweepAlarm = new cloudwatch.Alarm(this, 'CoordinatorStaleCmdSweepRate', {
      alarmName: `gosteady-${p}-coordinator-stale-cmd-sweep-rate`,
      alarmDescription:
        'Coord §C23: connection-coordinator swept >5 stale cmd entries in 1h. ' +
        'Indicates cmds are aging out of the 24h ack window without firmware ack — ' +
        'investigate firmware connectivity or cmd-delivery path.',
      metric: sweepMetric,
      threshold: 5,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    sweepAlarm.addAlarmAction(new cloudwatch_actions.SnsAction(opsTopic));

    // ════════════════════════════════════════════════════════════
    // Phase 1C-slim — Behavioral Detector
    // ════════════════════════════════════════════════════════════
    //
    // Single Lambda + hourly EventBridge cron emits 5 rule types into
    // the existing Alert History table (reused; no new table). Closes
    // the §C11.7 offline-detector gap AND the 2B Q5 client-side-
    // notification-evaluation gap in one piece of infra.
    //
    // Rules (per spec L8–L12):
    //   no_activity_today          (CRITICAL, facility-local 09:00)
    //   below_typical_activity     (STANDARD, facility-local 22:00)
    //   declining_trend            (STANDARD, facility-local 22:00)
    //   device_offline             (WARNING,  hourly — lastSeen > 2h)
    //   device_silent              (CRITICAL, hourly — lastSeen > 24h)
    //
    // Reserved concurrency = 1: cron Lambda; serializing avoids the
    // rare race where two overlapping invocations both attempt the
    // same conditional PutItem on Alert History.
    //
    // Spec: docs/specs/phase-1c-slim-notifications.md
    const organizationsTableRef = dynamodb.Table.fromTableName(
      this, 'OrganizationsTableRef', `gosteady-${p}-organizations`,
    );

    const behavioralDet = new ProcessingLambda(this, 'BehavioralDetector', {
      config,
      functionName: `gosteady-${p}-behavioral-detector`,
      handlerDir: path.join(lambdaDir, 'behavioral-detector'),
      description: 'Phase 1C-slim: hourly cron — 5 behavioral + offline notification rules',
      // Bigger than the other processing Lambdas because the per-facility
      // iteration is read-heavy (Patients GSI + Activity Series range
      // queries per patient). 512 MB at MVP scale; revisit if duration
      // climbs as patient count grows.
      memoryMb: 512,
      // Per spec §Configuration: 60s gives slack for full sweep at
      // 50 facilities × ~100 patients = ~5000 patient-evaluations per
      // run (each = 1 GetItem + 2 Query calls, in-process aggregation).
      timeoutSeconds: 60,
      environment: {
        ENVIRONMENT: p,
        PATIENTS_TABLE: patientsTable.tableName,
        ACTIVITY_TABLE: activityTable.tableName,
        ALERT_TABLE: alertTable.tableName,
        ORGANIZATIONS_TABLE: organizationsTableRef.tableName,
        DEVICES_TABLE: deviceTable.tableName,
        ASSIGNMENTS_TABLE: deviceAssignmentsTable.tableName,
        // Tuning surface (all overridable without code change):
        NO_ACTIVITY_LOCAL_HOUR: '9',
        END_OF_DAY_LOCAL_HOUR: '22',
        HISTORY_DAYS: '30',
      },
      powertoolsLayer,
      tracingActive: true,
    });
    this.behavioralDetector = behavioralDet.function;

    // Reserved concurrency intentionally NOT set: dev account has the
    // 10-concurrency new-account floor and reservedConcurrentExecutions=1
    // would push the unreserved pool below the minimum (same gotcha
    // that hit Phase 1.7 deploy). Concurrency control isn't strictly
    // needed: the cron fires once per hour, the Lambda completes in
    // seconds, and overlapping invocations are caught by the
    // conditional PutItem dedup on Alert History (compound SK with
    // facility-local-date suffix — same-day re-runs are no-ops).
    // Revisit at prod-cutover if account-level Lambda quota is raised
    // and we want strict serialization.

    // IAM grants — read-only on the inputs, write on Alert History.
    // Patients is READ-only: behavioral-detector consults the row for
    // status / facilityId / notificationsPaused but does NOT mutate it.
    // Activity Processor (in this same stack) handles auto-resume by
    // REMOVE'ing notificationsPaused when fresh activity arrives.
    // ReadWrite on Patients: alert recurrence policy (2026-05-26-alert-
    // recurrence-policy.md L3) for device_offline + device_silent.
    patientsTable.grantReadWriteData(this.behavioralDetector);
    activityTable.grantReadData(this.behavioralDetector);
    // GSI access: behavioral-detector queries Patients.by-client-status
    // (active patients per facility) + Activity Series base table range
    // queries. The fromTableName helpers used in this stack don't
    // include GSI ARNs in grantReadData (they only know the base table),
    // so add explicit Query+Scan permissions on every table's index/*.
    // Without this, the by-client-status query fails with AccessDenied.
    this.behavioralDetector.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'BehavioralDetectorGSIRead',
        actions: ['dynamodb:Query', 'dynamodb:Scan'],
        resources: [
          `arn:aws:dynamodb:${region}:${account}:table/gosteady-${p}-patients/index/*`,
          `arn:aws:dynamodb:${region}:${account}:table/gosteady-${p}-activity/index/*`,
          `arn:aws:dynamodb:${region}:${account}:table/gosteady-${p}-device-assignments/index/*`,
        ],
      }),
    );
    alertTable.grantReadWriteData(this.behavioralDetector);
    organizationsTableRef.grantReadData(this.behavioralDetector);
    deviceTable.grantReadData(this.behavioralDetector);
    deviceAssignmentsTable.grantReadData(this.behavioralDetector);
    identityKey.grantDecrypt(this.behavioralDetector);
    identityKey.grant(this.behavioralDetector, 'kms:GenerateDataKey');
    // AuditKey: Alert History is AWS-managed-encrypted, but the audit-
    // forwarder will pick up our emit_audit lines and re-encrypt with
    // AuditKey downstream. Grant for symmetry with patient-mgmt /
    // patient-api / alert-actions (same justification).
    securityStack.auditKey.grantEncryptDecrypt(this.behavioralDetector);

    // EventBridge hourly schedule.
    new events.Rule(this, 'BehavioralDetectorSchedule', {
      ruleName: `gosteady-${p}-behavioral-detector-hourly`,
      description: 'Phase 1C-slim: invoke behavioral-detector once per hour',
      schedule: events.Schedule.rate(cdk.Duration.hours(1)),
      targets: [new events_targets.LambdaFunction(this.behavioralDetector)],
    });

    // Alarms — Lambda Errors + ERROR-pattern log filter (1.6 pattern).
    const behavioralErrorsAlarm = new cloudwatch.Alarm(this, 'BehavioralDetectorErrors', {
      alarmName: `gosteady-${p}-behavioral-detector-errors`,
      alarmDescription:
        'behavioral-detector Lambda Errors > 0 in 1h. Cron Lambda — any ' +
        'invocation failure means a full hour of behavioral + offline rule ' +
        'coverage is skipped. Check /aws/lambda/gosteady-{env}-behavioral-detector.',
      metric: this.behavioralDetector.metricErrors({
        period: cdk.Duration.hours(1),
        statistic: 'Sum',
      }),
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    behavioralErrorsAlarm.addAlarmAction(new cloudwatch_actions.SnsAction(opsTopic));

    // ERROR-pattern: catches logged-and-swallowed errors per-facility
    // (facility_evaluate_failed) so we see them even when the overall
    // Lambda invocation returns 200.
    const behavioralErrorPatternFilter = this.behavioralDetector.logGroup.addMetricFilter(
      'BehavioralDetectorErrorPattern',
      {
        filterPattern: logs.FilterPattern.literal('{ $.level = "ERROR" }'),
        metricNamespace: `GoSteady/Processing/${p}`,
        metricName: 'BehavioralDetectorErrorLogLines',
        metricValue: '1',
        defaultValue: 0,
      },
    );
    const behavioralErrorPatternAlarm = new cloudwatch.Alarm(
      this, 'BehavioralDetectorErrorPatternAlarm',
      {
        alarmName: `gosteady-${p}-behavioral-detector-error-log-pattern`,
        alarmDescription:
          'behavioral-detector emitted >0 ERROR-level structured log lines ' +
          'in the last hour (per-facility evaluation error, alert write ' +
          'failure, or unexpected exception).',
        metric: behavioralErrorPatternFilter.metric({
          period: cdk.Duration.hours(1),
          statistic: 'Sum',
        }),
        threshold: 0,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      },
    );
    behavioralErrorPatternAlarm.addAlarmAction(new cloudwatch_actions.SnsAction(opsTopic));

    // ── Outputs ──────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'ActivityProcessorArn', {
      value: this.activityProcessor.functionArn,
      exportName: `${p}-ActivityProcessorArn`,
    });
    new cdk.CfnOutput(this, 'HeartbeatProcessorArn', {
      value: this.heartbeatProcessor.functionArn,
      exportName: `${p}-HeartbeatProcessorArn`,
    });
    new cdk.CfnOutput(this, 'ThresholdDetectorArn', {
      value: this.thresholdDetector.functionArn,
      exportName: `${p}-ThresholdDetectorArn`,
    });
    new cdk.CfnOutput(this, 'AlertHandlerArn', {
      value: this.alertHandler.functionArn,
      exportName: `${p}-AlertHandlerArn`,
    });
    new cdk.CfnOutput(this, 'ConnectionCoordinatorArn', {
      value: this.connectionCoordinator.functionArn,
      exportName: `${p}-ConnectionCoordinatorArn`,
    });
    new cdk.CfnOutput(this, 'ConnectionCoordinatorName', {
      value: this.connectionCoordinator.functionName,
      exportName: `${p}-ConnectionCoordinatorName`,
    });
    new cdk.CfnOutput(this, 'BehavioralDetectorName', {
      value: this.behavioralDetector.functionName,
      exportName: `${p}-BehavioralDetectorName`,
    });
  }
}
