import * as cdk from 'aws-cdk-lib/core';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as sns from 'aws-cdk-lib/aws-sns';
import { Construct } from 'constructs';

/**
 * Handler-Alarms — Phase 1.6.
 *
 * Per-Lambda alarms covering both standard CloudWatch metrics (Lambda
 * Errors, Throttles) and log-pattern alarms that close the §16
 * "DLQ-not-sufficient" observability gap. IoT Rule Lambda actions are
 * async-invoked, so a Lambda exception doesn't trip the IoT-side error
 * action's SQS DLQ — the alarm has to come from the Lambda Errors
 * metric or from a log-pattern filter. We do both: the standard
 * `Errors > 0` alarm catches uncaught exceptions, and the log-pattern
 * alarms catch logged-and-swallowed errors (e.g.
 * `unmapped_serial_count` in activity-processor or
 * `SnippetValidationError` in snippet-parser).
 *
 * All alarms publish to the shared ops topic (Phase 1.5's
 * `costAlarmTopic`, repurposed for ops in Phase 1.6).
 */
export interface HandlerAlarmsProps {
  readonly env: string;
  readonly opsTopic: sns.ITopic;
  /**
   * Lambda functions to alarm on. Each gets a `gosteady-{env}-{name}-errors`
   * Lambda Errors alarm; some additionally get log-pattern alarms below.
   */
  readonly lambdaNames: string[];
}

export class HandlerAlarms extends Construct {
  constructor(scope: Construct, id: string, props: HandlerAlarmsProps) {
    super(scope, id);

    const { env, opsTopic, lambdaNames } = props;
    const snsAction = new cloudwatchActions.SnsAction(opsTopic);

    // ── Per-Lambda Errors alarm ────────────────────────────────
    for (const fn of lambdaNames) {
      const alarmName = `gosteady-${env}-${stripPrefix(fn, env)}-errors`;
      const alarm = new cloudwatch.Alarm(this, `${pascalCase(stripPrefix(fn, env))}Errors`, {
        alarmName,
        alarmDescription:
          `${fn} Lambda Errors > 0 in 5 min — see CloudWatch Logs ` +
          `(/aws/lambda/${fn}) for the exception. ` +
          `Phase 1.6 §Architecture L5: Errors metric is the canonical signal — IoT Rule ` +
          `async invocation means the IoT DLQ stays empty on Lambda exceptions.`,
        metric: new cloudwatch.Metric({
          namespace: 'AWS/Lambda',
          metricName: 'Errors',
          dimensionsMap: { FunctionName: fn },
          statistic: 'Sum',
          period: cdk.Duration.minutes(5),
        }),
        threshold: 0,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });
      alarm.addAlarmAction(snsAction);
    }

    // ── Log-pattern alarms (the §16 ask) ───────────────────────
    // Each handler log group gets:
    //   1. A "level":"ERROR" structured-log filter for Powertools-shape
    //      handlers (4 of 6). Snippet-parser + cognito-pre-token are
    //      stdlib-only so the Powertools JSON shape doesn't apply —
    //      they get a plain `[ERROR]` substring filter instead, which
    //      catches Lambda runtime's uncaught-exception format.
    //   2. Handler-specific filters for known-swallowed failure modes
    //      (activity-processor unmapped_serial, snippet-parser
    //      SnippetValidationError).
    const POWERTOOLS_HANDLERS = new Set<string>([
      `gosteady-${env}-activity-processor`,
      `gosteady-${env}-heartbeat-processor`,
      `gosteady-${env}-threshold-detector`,
      `gosteady-${env}-alert-handler`,
    ]);

    for (const fn of lambdaNames) {
      const logGroup = logs.LogGroup.fromLogGroupName(
        this,
        `${pascalCase(stripPrefix(fn, env))}LogGroup`,
        `/aws/lambda/${fn}`,
      );

      const isPowertools = POWERTOOLS_HANDLERS.has(fn);
      // Powertools handlers: structured JSON `"level": "ERROR"` filter.
      // Stdlib handlers: substring match on `[ERROR]` (Lambda runtime's
      // uncaught-exception line prefix). Both cover the §16 gap of
      // logged-and-swallowed errors that don't trip the IoT DLQ.
      const errFilterPattern = isPowertools
        ? logs.FilterPattern.literal('{ $.level = "ERROR" }')
        : logs.FilterPattern.allTerms('[ERROR]');

      const errMetric = logGroup.addMetricFilter(
        `${pascalCase(stripPrefix(fn, env))}ErrorLogPattern`,
        {
          filterName: `gosteady-${env}-${stripPrefix(fn, env)}-error-pattern`,
          filterPattern: errFilterPattern,
          metricNamespace: `GoSteady/Handlers/${env}`,
          metricName: `${stripPrefix(fn, env)}_error_count`,
          metricValue: '1',
          defaultValue: 0,
        },
      );

      const errAlarm = new cloudwatch.Alarm(
        this,
        `${pascalCase(stripPrefix(fn, env))}ErrorPatternAlarm`,
        {
          alarmName: `gosteady-${env}-${stripPrefix(fn, env)}-error-pattern`,
          alarmDescription:
            `${fn} emitted an ERROR log line in 5 min — closes the ` +
            `§16 swallowed-error gap. Tail /aws/lambda/${fn} for context.`,
          metric: errMetric.metric({
            statistic: 'Sum',
            period: cdk.Duration.minutes(5),
          }),
          threshold: 0,
          comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
          evaluationPeriods: 1,
          treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
        },
      );
      errAlarm.addAlarmAction(snsAction);

      // Handler-specific patterns
      if (fn.endsWith('-activity-processor')) {
        addLogPatternAlarm(this, {
          env,
          opsTopic,
          logGroup,
          patternId: 'UnmappedSerial',
          functionName: fn,
          // Powertools shape: $.message holds the literal log message string.
          filterPattern: logs.FilterPattern.stringValue(
            '$.message',
            '=',
            'unmapped_serial',
          ),
          alarmDescriptionTail:
            'Device published activity without an active DeviceAssignment ' +
            '(orphan serial). Row dropped cleanly; investigate provisioning.',
        });
      }

      if (fn.endsWith('-snippet-parser')) {
        addLogPatternAlarm(this, {
          env,
          opsTopic,
          logGroup,
          patternId: 'SnippetValidationError',
          functionName: fn,
          // snippet-parser is stdlib-only; uncaught SnippetValidationError
          // surfaces as Lambda runtime's `[ERROR] SnippetValidationError: ...`
          // format. Substring match catches the exception class name.
          filterPattern: logs.FilterPattern.allTerms('SnippetValidationError'),
          alarmDescriptionTail:
            'snippet-parser raised SnippetValidationError on a malformed ' +
            'payload — IoT DLQ stays empty (async Lambda invoke). Inspect ' +
            'the log for the offending snippet_id + payload preamble.',
        });
      }
    }
  }
}

interface AddLogPatternAlarmProps {
  env: string;
  opsTopic: sns.ITopic;
  logGroup: logs.ILogGroup;
  /** Camel-case fragment for CDK construct IDs and metric/alarm names. */
  patternId: string;
  functionName: string;
  filterPattern: logs.IFilterPattern;
  alarmDescriptionTail: string;
}

function addLogPatternAlarm(scope: Construct, p: AddLogPatternAlarmProps): void {
  const env = p.env;
  const fnSuffix = stripPrefix(p.functionName, env);
  const id = `${pascalCase(fnSuffix)}${p.patternId}`;
  const metricName = `${fnSuffix}_${snakeCase(p.patternId)}_count`;

  const filter = p.logGroup.addMetricFilter(`${id}Filter`, {
    filterName: `gosteady-${env}-${fnSuffix}-${kebabCase(p.patternId)}`,
    filterPattern: p.filterPattern,
    metricNamespace: `GoSteady/Handlers/${env}`,
    metricName,
    metricValue: '1',
    defaultValue: 0,
  });

  const alarm = new cloudwatch.Alarm(scope, `${id}Alarm`, {
    alarmName: `gosteady-${env}-${fnSuffix}-${kebabCase(p.patternId)}`,
    alarmDescription: `${p.functionName}: ${p.alarmDescriptionTail}`,
    metric: filter.metric({
      statistic: 'Sum',
      period: cdk.Duration.minutes(5),
    }),
    threshold: 0,
    comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
    evaluationPeriods: 1,
    treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
  });
  alarm.addAlarmAction(new cloudwatchActions.SnsAction(p.opsTopic));
}

// ── Naming helpers ────────────────────────────────────────────
function stripPrefix(fn: string, env: string): string {
  return fn.startsWith(`gosteady-${env}-`) ? fn.slice(`gosteady-${env}-`.length) : fn;
}

function pascalCase(s: string): string {
  return s.split(/[-_]/).map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join('');
}

function snakeCase(s: string): string {
  // PascalCase → snake_case: insert "_" before any inner uppercase letter
  return s.replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase();
}

function kebabCase(s: string): string {
  return snakeCase(s).replace(/_/g, '-');
}
