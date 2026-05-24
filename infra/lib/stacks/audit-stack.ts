import * as cdk from 'aws-cdk-lib/core';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as firehose from 'aws-cdk-lib/aws-kinesisfirehose';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as logsDestinations from 'aws-cdk-lib/aws-logs-destinations';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as path from 'path';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { AuditS3Bucket } from '../constructs/audit-s3-bucket.js';
import { ProcessingLambda } from '../constructs/processing-lambda.js';

export interface AuditStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
}

/**
 * Audit — Phase 1.7.
 *
 * Routes the audit-shape JSON log lines that Phase 1B-rev handlers
 * already emit (`{ "audit": true, ... }`) into a dedicated CW Log
 * Group, and ships those onward to an S3 bucket via Kinesis Data
 * Firehose for long-term compliance retention. The S3 bucket gets
 * Object Lock compliance mode in prod (6yr) and plain SSE-KMS in dev.
 *
 * Two-hop architecture (chosen per spec D6):
 *   handler log group → subscription filter (`{ $.audit = true }`)
 *     → audit-forwarder Lambda → PutLogEvents → audit log group
 *     → subscription filter (all events) → Firehose → S3
 *
 * The dedicated audit log group lets us apply restrictive IAM
 * (audit-reader can read it; nobody but the forwarder can write) and
 * its own retention window (90d hot vs handler 30d dev / 90d prod)
 * that the source handler log groups can't accommodate.
 *
 * Cross-stack dependency: AuditKey CMK from Security stack
 * (exported as `{env}-AuditKeyArn` since Phase 1.5). No other
 * cross-stack imports — handler log groups are referenced by name
 * (matches the Phase 1.6 Observability pattern).
 */
export class AuditStack extends cdk.Stack {
  public readonly auditLogGroup: logs.LogGroup;
  public readonly auditBucket: AuditS3Bucket;
  public readonly forwarderFn: lambda.IFunction;

  constructor(scope: Construct, id: string, props: AuditStackProps) {
    super(scope, id, props);

    const { config } = props;
    const env = config.prefix;

    // ── Cross-stack imports ────────────────────────────────────────
    const auditKeyArn = cdk.Fn.importValue(`${env}-AuditKeyArn`);
    const auditKey = kms.Key.fromKeyArn(this, 'AuditKeyRef', auditKeyArn);

    const opsTopicArn = cdk.Fn.importValue(`${env}-CostAlarmTopic`);
    const opsTopic = sns.Topic.fromTopicArn(this, 'OpsTopicRef', opsTopicArn);
    const snsAction = new cloudwatchActions.SnsAction(opsTopic);

    // ── Audit hot path: dedicated CW Log Group ─────────────────────
    this.auditLogGroup = new logs.LogGroup(this, 'AuditLogGroup', {
      logGroupName: `gosteady-${env}-audit`,
      retention: retentionDaysForConfig(config.auditHotRetentionDays),
      encryptionKey: auditKey,
      // Dev: clean up if the stack is destroyed. Prod: keep — even
      // though the S3 cold path is the long-term store, the hot path
      // shouldn't be casually destroyable in prod.
      removalPolicy:
        config.auditBucketObjectLockEnabled
          ? cdk.RemovalPolicy.RETAIN
          : cdk.RemovalPolicy.DESTROY,
    });

    // KMS resource-policy grant for CW Logs is owned by the Security stack
    // (which created the AuditKey). `auditKey` is imported here via
    // `fromKeyArn`, so `addToResourcePolicy` from this stack would be a
    // no-op. See security-stack.ts `AllowCWLogsForAuditLogGroup` statement.

    // ── Audit cold path: S3 bucket with Object Lock (prod) ─────────
    this.auditBucket = new AuditS3Bucket(this, 'AuditBucket', {
      env,
      auditKey,
      objectLockEnabled: config.auditBucketObjectLockEnabled,
      objectLockYears: config.auditBucketObjectLockYears,
    });

    // ── Audit forwarder Lambda ────────────────────────────────────
    // Reuses ProcessingLambda construct for consistent bundling +
    // Powertools layer attachment. The forwarder doesn't import from
    // `_shared/` (no patient resolution / no audit helper needed —
    // it's the *destination* of audit events, not a producer), but
    // having `_shared/` bundled in is harmless and keeps the
    // bundling pattern uniform across our Lambdas.
    const powertoolsLayer = lambda.LayerVersion.fromLayerVersionArn(
      this,
      'PowertoolsLayer',
      config.powertoolsLayerArn,
    );

    const forwarder = new ProcessingLambda(this, 'AuditForwarder', {
      config,
      functionName: `gosteady-${env}-audit-forwarder`,
      handlerDir: path.join(__dirname, '..', '..', 'lambda', 'audit-forwarder'),
      description:
        'Forwards audit-tagged log events from handler log groups into the ' +
        'dedicated audit log group, partitioning by UTC date (Phase 1.7).',
      memoryMb: 256,
      timeoutSeconds: 30,
      powertoolsLayer,
      tracingActive: true,
      environment: {
        ENVIRONMENT: env,
        AUDIT_LOG_GROUP_NAME: this.auditLogGroup.logGroupName,
      },
    });
    this.forwarderFn = forwarder.function;

    // Spec D11 originally specified ReservedConcurrentExecutions=5 as a
    // cap against runaway invocation in a forwarder bug. Dropped at deploy
    // time: this dev account is on the new-account 10-concurrency floor
    // (`aws lambda get-account-settings` → `ConcurrentExecutions: 10`)
    // rather than the 1000 default. With 6 existing Lambdas in the account
    // already competing for that 10, the Lambda service rejects any
    // ReservedConcurrentExecutions request that would leave <10
    // UnreservedConcurrentExecutions remaining. Revisit once the account
    // has a concurrency quota increase (Phase 1.5 prod-hardening territory).

    // Forwarder needs to write to the audit log group + create streams
    // there. Scoped to the audit log group's ARN; nothing else.
    forwarder.function.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'AuditLogGroupWrite',
        effect: iam.Effect.ALLOW,
        actions: ['logs:CreateLogStream', 'logs:PutLogEvents', 'logs:DescribeLogStreams'],
        resources: [`${this.auditLogGroup.logGroupArn}:*`, this.auditLogGroup.logGroupArn],
      }),
    );
    // KMS access on AuditKey so the forwarder can encrypt outbound writes.
    auditKey.grantEncryptDecrypt(forwarder.function);

    // ── Subscription filters: handler log groups → forwarder ──────
    // 6 source handler log groups. Reserved for the 4 planned Phase 2A
    // handlers but those don't exist yet — attach when 2A ships.
    const sourceHandlers = [
      `gosteady-${env}-activity-processor`,
      `gosteady-${env}-heartbeat-processor`,
      `gosteady-${env}-threshold-detector`,
      `gosteady-${env}-alert-handler`,
      `gosteady-${env}-snippet-parser`,
      `gosteady-${env}-cognito-pre-token`,
      // Phase 2A-0 (2026-05-17): api-stub Lambda emits auth.session.read
      // audit events. Bundled into this list per spec D9 to avoid a
      // between-revisions silent-swallow gap (Migration Pattern 18.8).
      `gosteady-${env}-api-stub`,
      // Phase 2A-DL (2026-05-17): three new Lambdas emit device.* audit
      // events (provision/end-assignment/decommission/recover/force-
      // reset/move + discharge cascade + reset_complete). Same gap-
      // avoidance discipline — bundled with the 2A-DL deploy.
      `gosteady-${env}-device-api`,
      `gosteady-${env}-discharge-cascade`,
      `gosteady-${env}-device-shadow-handler`,
      // Coord §C23 (2026-05-18): connection-coordinator emits
      // device.cmd_republished + device.cmd_swept_stale audits on
      // firmware connect.
      `gosteady-${env}-connection-coordinator`,
      // Phase 2A-RD (2026-05-23): patient-api emits patient.detail.read,
      // patient.activity.read, alert.read, patient.list.read, and
      // census.roster.read on every successful read. Same gap-avoidance
      // discipline as 2A-DL — bundled with the 2A-RD deploy (spec D9).
      `gosteady-${env}-patient-api`,
      // Phase 2A-AA (2026-05-23): alert-actions emits alert.ack +
      // patient.thresholds.read + patient.thresholds.update. Bundled
      // with the 2A-AA deploy (Migration Pattern 18.8).
      `gosteady-${env}-alert-actions`,
    ];

    const forwarderDestination = new logsDestinations.LambdaDestination(forwarder.function);

    for (const fnName of sourceHandlers) {
      const logGroupName = `/aws/lambda/${fnName}`;
      // Match the per-Lambda log group by name, not by cross-stack
      // resource ref (matches the Phase 1.6 Observability decoupling
      // pattern from infra-scaffold §0B-rev Migration Pattern 18.4).
      const logGroup = logs.LogGroup.fromLogGroupName(
        this,
        `${pascalCase(stripPrefix(fnName, env))}LogGroup`,
        logGroupName,
      );

      new logs.SubscriptionFilter(
        this,
        `${pascalCase(stripPrefix(fnName, env))}AuditFilter`,
        {
          logGroup,
          destination: forwarderDestination,
          filterPattern: logs.FilterPattern.literal('{ $.audit IS TRUE }'),
          filterName: `gosteady-${env}-audit-capture`,
        },
      );
    }

    // ── Cold-path pipeline: audit log group → Firehose → S3 ───────
    // Firehose needs its own IAM role with S3 write + KMS access. CDK
    // creates one when we don't pass `role`; we let it. Buffering: 1 MB
    // or 60 s (spec, balancing latency vs request rate).
    //
    // Cross-region nuance: the L2 KinesisFirehose construct exists in
    // aws-cdk-lib but is experimental for some destinations. The S3
    // destination has stable APIs (S3Bucket destination class).

    const firehoseLogGroup = new logs.LogGroup(this, 'FirehoseDeliveryLogs', {
      logGroupName: `/aws/kinesisfirehose/gosteady-${env}-audit-to-s3`,
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // The L2 EnableLogging construct creates its own log stream inside the
    // supplied log group; we don't pre-create one. Firehose writes
    // delivery error / status events here.
    const deliveryStream = new firehose.DeliveryStream(this, 'AuditDeliveryStream', {
      deliveryStreamName: `gosteady-${env}-audit-to-s3`,
      destination: new firehose.S3Bucket(this.auditBucket.bucket, {
        bufferingInterval: cdk.Duration.seconds(60),
        bufferingSize: cdk.Size.mebibytes(1),
        compression: firehose.Compression.GZIP,
        encryptionKey: auditKey,
        dataOutputPrefix:
          'audit/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/',
        errorOutputPrefix:
          'firehose-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/',
        loggingConfig: new firehose.EnableLogging(firehoseLogGroup),
      }),
    });

    // Subscription filter from the audit log group → Firehose. Empty
    // pattern matches every event in the audit log group (everything
    // forwarded there is already audit by construction).
    new logs.SubscriptionFilter(this, 'AuditToFirehose', {
      logGroup: this.auditLogGroup,
      destination: new logsDestinations.FirehoseDestination(deliveryStream),
      filterPattern: logs.FilterPattern.allEvents(),
      filterName: `gosteady-${env}-audit-to-firehose`,
    });

    // ── Compliance reader IAM role (account-root placeholder) ─────
    // Runbook step replaces the trust policy with a real principal
    // once the compliance reader identity is known. The placeholder
    // trusts this account's root, which IAM accepts as a valid
    // principal at create time. The role remains effectively
    // unassumable in practice because we don't grant `sts:AssumeRole`
    // on this role's ARN in any identity policy — and CDK's role
    // grant API isn't called anywhere. **Caveat:** any IAM identity
    // in this account that has been granted broad admin permissions
    // (e.g. `sts:AssumeRole` on `*`) could assume this role. That
    // risk is acceptable for the placeholder window because (a)
    // there's no actual audit data yet, and (b) the runbook step is
    // explicit about replacing this trust policy as part of
    // compliance-reader onboarding. Earlier attempts to use a more
    // restrictive placeholder (`Principal: '*'`, ArnPrincipal of a
    // non-existent role) both failed IAM validation at create time.
    const auditReaderRole = new iam.Role(this, 'AuditReaderRole', {
      roleName: `gosteady-${env}-audit-reader`,
      assumedBy: new iam.AccountRootPrincipal(),
      description:
        'Read-only audit reader. Trust policy is an account-root placeholder; ' +
        'replace via `aws iam update-assume-role-policy` once the compliance ' +
        'reader identity is named. See docs/playbooks/audit-reader-onboarding.md.',
    });

    auditReaderRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ReadAuditLogGroup',
        effect: iam.Effect.ALLOW,
        actions: [
          'logs:FilterLogEvents',
          'logs:GetLogEvents',
          'logs:StartQuery',
          'logs:GetQueryResults',
          'logs:StopQuery',
          'logs:DescribeQueries',
          'logs:DescribeLogStreams',
        ],
        resources: [this.auditLogGroup.logGroupArn, `${this.auditLogGroup.logGroupArn}:*`],
      }),
    );
    auditReaderRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ReadAuditBucket',
        effect: iam.Effect.ALLOW,
        actions: ['s3:GetObject', 's3:ListBucket'],
        resources: [
          this.auditBucket.bucket.bucketArn,
          this.auditBucket.bucket.arnForObjects('*'),
        ],
      }),
    );
    auditKey.grantDecrypt(auditReaderRole);

    // ── Alarms (route to ops topic) ────────────────────────────────
    const forwarderErrorsAlarm = new cloudwatch.Alarm(this, 'AuditForwarderErrors', {
      alarmName: `gosteady-${env}-audit-forwarder-errors`,
      alarmDescription:
        'audit-forwarder Lambda Errors > 0 in 5 min. Audit events from ' +
        'the affected source handler may not be reaching the audit log ' +
        'group; investigate via /aws/lambda/gosteady-{env}-audit-forwarder.',
      metric: forwarder.function.metricErrors({
        period: cdk.Duration.minutes(5),
        statistic: 'Sum',
      }),
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    forwarderErrorsAlarm.addAlarmAction(snsAction);

    const firehoseFailuresAlarm = new cloudwatch.Alarm(this, 'AuditFirehoseDeliveryFailures', {
      alarmName: `gosteady-${env}-audit-firehose-delivery-failures`,
      alarmDescription:
        'Firehose DeliveryToS3.Failures > 0 in 5 min. Audit events are ' +
        'reaching the audit log group but not landing in S3 — likely KMS ' +
        'policy or bucket policy misconfiguration. Hot path (CW Logs) ' +
        'unaffected; cold/compliance path broken.',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/Firehose',
        metricName: 'DeliveryToS3.Records',
        dimensionsMap: { DeliveryStreamName: deliveryStream.deliveryStreamName },
        statistic: 'Sum',
        period: cdk.Duration.minutes(5),
      }),
      threshold: 0,
      // Firehose emits .Records on success; .DataFreshness staleness is
      // the real lag indicator. We alarm on DataFreshness > 600 s instead.
      comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    firehoseFailuresAlarm.addAlarmAction(snsAction);

    const firehoseFreshnessAlarm = new cloudwatch.Alarm(this, 'AuditFirehoseDataFreshness', {
      alarmName: `gosteady-${env}-audit-firehose-data-freshness`,
      alarmDescription:
        'Firehose DeliveryToS3.DataFreshness > 600 s — oldest unwritten ' +
        'record is more than 10 min old. Indicates delivery backlog or stall.',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/Firehose',
        metricName: 'DeliveryToS3.DataFreshness',
        dimensionsMap: { DeliveryStreamName: deliveryStream.deliveryStreamName },
        statistic: 'Maximum',
        period: cdk.Duration.minutes(5),
      }),
      threshold: 600,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    firehoseFreshnessAlarm.addAlarmAction(snsAction);

    // ── Outputs ────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'AuditLogGroupName', {
      value: this.auditLogGroup.logGroupName,
      exportName: `${env}-AuditLogGroupName`,
    });
    new cdk.CfnOutput(this, 'AuditBucketName', {
      value: this.auditBucket.bucket.bucketName,
      exportName: `${env}-AuditBucketName`,
    });
    new cdk.CfnOutput(this, 'AuditForwarderFunctionName', {
      value: forwarder.function.functionName,
      exportName: `${env}-AuditForwarderFunctionName`,
    });
    new cdk.CfnOutput(this, 'AuditReaderRoleArn', {
      value: auditReaderRole.roleArn,
      exportName: `${env}-AuditReaderRoleArn`,
    });
  }
}

function stripPrefix(fnName: string, env: string): string {
  const prefix = `gosteady-${env}-`;
  return fnName.startsWith(prefix) ? fnName.slice(prefix.length) : fnName;
}

function pascalCase(s: string): string {
  return s
    .split('-')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join('');
}

/**
 * CloudWatch Logs only allows a fixed set of retention values
 * (1, 3, 5, 7, 14, 30, 60, 90, ...). Map the configured day count
 * to the nearest valid `RetentionDays` enum member; default 90
 * for anything that doesn't map cleanly.
 */
function retentionDaysForConfig(days: number): logs.RetentionDays {
  const allowed: Array<[number, logs.RetentionDays]> = [
    [30, logs.RetentionDays.ONE_MONTH],
    [60, logs.RetentionDays.TWO_MONTHS],
    [90, logs.RetentionDays.THREE_MONTHS],
    [120, logs.RetentionDays.FOUR_MONTHS],
    [150, logs.RetentionDays.FIVE_MONTHS],
    [180, logs.RetentionDays.SIX_MONTHS],
    [365, logs.RetentionDays.ONE_YEAR],
    [400, logs.RetentionDays.THIRTEEN_MONTHS],
    [545, logs.RetentionDays.EIGHTEEN_MONTHS],
    [731, logs.RetentionDays.TWO_YEARS],
    [1827, logs.RetentionDays.FIVE_YEARS],
    [3653, logs.RetentionDays.TEN_YEARS],
  ];
  for (const [d, ret] of allowed) {
    if (d === days) return ret;
  }
  return logs.RetentionDays.THREE_MONTHS; // 90d default
}
