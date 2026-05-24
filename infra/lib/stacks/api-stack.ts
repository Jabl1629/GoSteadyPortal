import * as cdk from 'aws-cdk-lib/core';
import * as apigwv2 from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpUserPoolAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as iot from 'aws-cdk-lib/aws-iot';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { DynamoEventSource } from 'aws-cdk-lib/aws-lambda-event-sources';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as path from 'path';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { AuthStack } from './auth-stack.js';
import { DataStack } from './data-stack.js';
import { SecurityStack } from './security-stack.js';
import { ProcessingLambda } from '../constructs/processing-lambda.js';

export interface ApiStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  readonly authStack: AuthStack;
  readonly dataStack: DataStack;
  readonly securityStack: SecurityStack;
}

/**
 * Portal API — Phase 2A foundation (2A-0).
 *
 * HTTP API + Cognito JWT authorizer + one stub endpoint
 * (GET /api/v1/me) wired through audit middleware to Phase 1.7's
 * audit pipeline. Subsequent 2A subsets (device-lifecycle 2A-DL,
 * patient-reads 2A-RD, alert-actions 2A-AA, user-management 2A-UM,
 * internal-tools 2A-INT) add their Lambdas + routes on this
 * foundation.
 *
 * WAF deferred to Phase 3A (CloudFront). WAFv2 cannot associate with
 * API Gateway HTTP API v2 stages directly — see comment near the
 * (removed) WAF block below for details. API Gateway stage-level
 * throttling provides basic rate-limiting at MVP.
 *
 * The stub `/me` endpoint exists to smoke-test the end-to-end
 * pipeline before any business endpoints exist:
 *   - JWT authorizer validates token
 *   - Custom claims accessible to handler
 *   - Audit middleware emits → 1.7 pipeline → S3
 *   - Error envelope on 401/403 paths
 *   - Access logs land in CloudWatch
 *
 * Cross-stack imports:
 *   - AuthStack: User Pool + both App Clients (passed as objects, not
 *     name-string-imports, because the L2 HttpUserPoolAuthorizer needs
 *     the IUserPool interface)
 *   - SecurityStack: ops SNS topic ARN (via Fn.importValue)
 */
export class ApiStack extends cdk.Stack {
  public readonly httpApi: apigwv2.HttpApi;

  constructor(scope: Construct, id: string, props: ApiStackProps) {
    super(scope, id, props);

    const { config, authStack, dataStack, securityStack } = props;
    const env = config.prefix;

    // ── Cross-stack imports ────────────────────────────────────────
    const opsTopicArn = cdk.Fn.importValue(`${env}-CostAlarmTopic`);
    const opsTopic = sns.Topic.fromTopicArn(this, 'OpsTopicRef', opsTopicArn);
    const snsAction = new cloudwatchActions.SnsAction(opsTopic);

    // ── Stub Lambda (api-stub) ─────────────────────────────────────
    // Uses ProcessingLambda construct for the standard bundling +
    // Powertools-layer pattern. The lambda is intentionally minimal:
    // it returns the JWT claims it received. Real business endpoints
    // land in subsequent subset Lambdas (device-api, etc.) — this
    // stub gets removed once any subset is live, or kept as a smoke
    // ping. D7 of phase-2a-foundation.md.
    const powertoolsLayer = lambda.LayerVersion.fromLayerVersionArn(
      this,
      'PowertoolsLayer',
      config.powertoolsLayerArn,
    );

    const apiStub = new ProcessingLambda(this, 'ApiStub', {
      config,
      functionName: `gosteady-${env}-api-stub`,
      handlerDir: path.join(__dirname, '..', '..', 'lambda', 'api-stub'),
      description:
        'Phase 2A-0 foundation smoke endpoint — GET /api/v1/me mirrors JWT claims',
      memoryMb: 128,
      timeoutSeconds: 10,
      powertoolsLayer,
      tracingActive: true,
      environment: {
        ENVIRONMENT: env,
      },
    });

    // ── HTTP API ───────────────────────────────────────────────────
    const accessLogGroup = new logs.LogGroup(this, 'AccessLogs', {
      logGroupName: `/aws/apigateway/gosteady-${env}-api`,
      retention:
        env === 'prod' ? logs.RetentionDays.THREE_MONTHS : logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    this.httpApi = new apigwv2.HttpApi(this, 'HttpApi', {
      apiName: `gosteady-${env}-api`,
      description: `GoSteady Portal API — ${config.envName}`,
      corsPreflight: {
        allowOrigins:
          env === 'prod'
            ? ['https://portal.gosteady.co']
            : ['http://localhost:8080', 'http://localhost:8090'],
        allowMethods: [
          apigwv2.CorsHttpMethod.GET,
          apigwv2.CorsHttpMethod.POST,
          apigwv2.CorsHttpMethod.PATCH,
          apigwv2.CorsHttpMethod.DELETE,
          apigwv2.CorsHttpMethod.OPTIONS,
        ],
        allowHeaders: ['Authorization', 'Content-Type'],
        maxAge: cdk.Duration.hours(1),
      },
    });

    // Default stage with access logging + throttling.
    const defaultStage = this.httpApi.defaultStage!.node.defaultChild as apigwv2.CfnStage;
    defaultStage.accessLogSettings = {
      destinationArn: accessLogGroup.logGroupArn,
      format: JSON.stringify({
        requestId: '$context.requestId',
        requestTime: '$context.requestTime',
        httpMethod: '$context.httpMethod',
        routeKey: '$context.routeKey',
        status: '$context.status',
        ip: '$context.identity.sourceIp',
        userAgent: '$context.identity.userAgent',
        latency: '$context.responseLatency',
        integrationLatency: '$context.integrationLatency',
        error: '$context.error.message',
      }),
    };
    defaultStage.defaultRouteSettings = {
      throttlingBurstLimit: config.apiThrottleBurst,
      throttlingRateLimit: config.apiThrottleRate,
      detailedMetricsEnabled: true,
    };

    // ── JWT authorizer (Cognito User Pool, single App Client) ─────
    // Per phase-2a-foundation.md Q8 + phase-2b-portal-integration.md L1:
    // unified-portal decision — all web users (customer + internal) sign in
    // via Portal-Customer. Portal-Internal client is reserved for non-browser
    // tools (CLI / server-side scripts where the client secret is safe);
    // it's no longer in the authorizer audience list.
    //
    // Internal-tier authority is enforced via the `custom:role` claim at
    // the handler layer (`api_authz.is_internal`), and the 4-hr absolute
    // session cap that the Portal-Internal client used to enforce is now
    // enforced app-side via `_shared/api_authz.enforce_internal_session_age`
    // called from `audit_middleware`.
    const userPoolAuthorizer = new HttpUserPoolAuthorizer(
      'PortalUserPoolAuthorizer',
      authStack.userPool,
      {
        userPoolClients: [authStack.portalCustomerClient],
        identitySource: ['$request.header.Authorization'],
      },
    );

    // ── Stub route: GET /api/v1/me ────────────────────────────────
    this.httpApi.addRoutes({
      path: '/api/v1/me',
      methods: [apigwv2.HttpMethod.GET],
      integration: new HttpLambdaIntegration('MeIntegration', apiStub.function),
      authorizer: userPoolAuthorizer,
    });

    // ── WAF (deferred to Phase 3A) ────────────────────────────────
    // WAFv2 cannot associate with API Gateway HTTP API (v2) stages —
    // only REST API (v1), CloudFront, ALB, AppSync, Cognito User Pool,
    // etc. Surfaced at first deploy 2026-05-17 with: "The ARN isn't
    // valid... arn:aws:apigateway:us-east-1::/apis/{id}/stages/$default".
    //
    // Mitigation: API Gateway stage-level throttling (configured above)
    // covers basic rate-limiting until Phase 3A. The WAF managed rules
    // (CRS, IP reputation) only matter at the public CloudFront edge
    // serving the Flutter portal — which is the natural place to put
    // them. Phase 3A's CloudFront distribution will fan out to both
    // the S3 portal bucket and the API Gateway origin, and WAF
    // associates with the CloudFront distribution.
    //
    // The `portal-waf.ts` construct + `apiWafRateLimitPerIp` config
    // field are kept in code (deleted from synth wire-up) for re-use
    // at Phase 3A.

    // ── Alarms ────────────────────────────────────────────────────
    const api5xxAlarm = new cloudwatch.Alarm(this, 'Api5xxRate', {
      alarmName: `gosteady-${env}-api-5xx-rate`,
      alarmDescription:
        'API Gateway 5xx error count > 5 in 5 min — investigate handler ' +
        'errors via /aws/lambda/gosteady-{env}-* log groups and ' +
        '/aws/apigateway/gosteady-{env}-api access logs.',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApiGateway',
        metricName: '5xx',
        dimensionsMap: { ApiId: this.httpApi.apiId, Stage: '$default' },
        statistic: 'Sum',
        period: cdk.Duration.minutes(5),
      }),
      threshold: 5,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    api5xxAlarm.addAlarmAction(snsAction);

    const api4xxBurst = new cloudwatch.Alarm(this, 'Api4xxBurst', {
      alarmName: `gosteady-${env}-api-4xx-burst`,
      alarmDescription:
        'API Gateway 4xx count > 50 in 5 min — possible credential stuffing, ' +
        'broken UI deployment, or aggressive scraper. Check WAF + access logs.',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApiGateway',
        metricName: '4xx',
        dimensionsMap: { ApiId: this.httpApi.apiId, Stage: '$default' },
        statistic: 'Sum',
        period: cdk.Duration.minutes(5),
      }),
      threshold: 50,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    api4xxBurst.addAlarmAction(snsAction);

    const apiLatencyP99 = new cloudwatch.Alarm(this, 'ApiLatencyP99', {
      alarmName: `gosteady-${env}-api-latency-p99`,
      alarmDescription: `API Gateway p99 latency > ${config.apiLatencyP99AlarmMs}ms in 5 min — investigate slow handlers via X-Ray.`,
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApiGateway',
        metricName: 'Latency',
        dimensionsMap: { ApiId: this.httpApi.apiId, Stage: '$default' },
        statistic: 'p99',
        period: cdk.Duration.minutes(5),
      }),
      threshold: config.apiLatencyP99AlarmMs,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    apiLatencyP99.addAlarmAction(snsAction);

    const stubErrorsAlarm = new cloudwatch.Alarm(this, 'ApiStubErrors', {
      alarmName: `gosteady-${env}-api-stub-errors`,
      alarmDescription:
        'api-stub Lambda Errors > 0 in 5 min — uncaught exception in the ' +
        'foundation stub handler. Check /aws/lambda/gosteady-{env}-api-stub.',
      metric: apiStub.function.metricErrors({
        period: cdk.Duration.minutes(5),
        statistic: 'Sum',
      }),
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    stubErrorsAlarm.addAlarmAction(snsAction);

    // ════════════════════════════════════════════════════════════════
    // Phase 2A-DL — Device Lifecycle
    // ════════════════════════════════════════════════════════════════
    //
    // Three Lambdas + 10 API routes + DDB Stream + IoT Topic Rule +
    // L16 stuck-in-provisioned alarm. See phase-2a-device-lifecycle.md
    // §Architecture for the full picture.
    //
    // Lambda placement: all 3 in api-stack for 2A-DL coherence
    // (device-api is the HTTP-API consumer, discharge-cascade reads
    // the Patients DDB Stream, device-shadow-handler is IoT-Rule-
    // triggered). The Patients table stream is owned by data-stack
    // and exposed as a public property; the IoT shadow topic is
    // public (firmware writes to it), so this api-stack can attach a
    // new IoT Topic Rule directly.
    //
    // The existing threshold-detector rule (1B-rev) subscribes to the
    // same `$aws/things/+/shadow/update/documents` topic — both rules
    // fire on every shadow update and each Lambda filters for its own
    // concern (threshold-detector → threshold breaches;
    // device-shadow-handler → reset_complete transitions).

    // Cross-stack imports (security-stack public properties)
    const identityKey = securityStack.identityKey;
    const auditKey = securityStack.auditKey;

    // ── device-api Lambda (10 routes) ──────────────────────────────
    const deviceApi = new ProcessingLambda(this, 'DeviceApi', {
      config,
      functionName: `gosteady-${env}-device-api`,
      handlerDir: path.join(__dirname, '..', '..', 'lambda', 'device-api'),
      description: 'Phase 2A-DL device-lifecycle handler (10 routes; state machine + audit)',
      memoryMb: 256,
      timeoutSeconds: 15,
      powertoolsLayer,
      tracingActive: true,
      environment: {
        ENVIRONMENT: env,
        DEVICES_TABLE: dataStack.deviceTable.tableName,
        ASSIGNMENTS_TABLE: dataStack.deviceAssignmentsTable.tableName,
        PATIENTS_TABLE: dataStack.patientsTable.tableName,
        ACTIVATION_ACK_WINDOW_HOURS: String(config.activationAckWindowHours),
      },
    });
    dataStack.deviceTable.grantReadWriteData(deviceApi.function);
    dataStack.deviceAssignmentsTable.grantReadWriteData(deviceApi.function);
    dataStack.patientsTable.grantReadData(deviceApi.function);
    identityKey.grantEncryptDecrypt(deviceApi.function);
    auditKey.grantEncryptDecrypt(deviceApi.function);
    // IoT publish for activate cmd + Shadow update for desired.activated_at
    deviceApi.function.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['iot:Publish'],
      resources: [
        `arn:aws:iot:${this.region}:${this.account}:topic/gs/*/cmd`,
      ],
    }));
    deviceApi.function.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['iot:UpdateThingShadow', 'iot:GetThingShadow'],
      resources: [`arn:aws:iot:${this.region}:${this.account}:thing/*`],
    }));

    // 10 routes on the existing HTTP API
    const deviceApiIntegration = new HttpLambdaIntegration('DeviceApiIntegration', deviceApi.function);
    const deviceRoutes: Array<[apigwv2.HttpMethod, string]> = [
      [apigwv2.HttpMethod.GET, '/api/v1/devices/{serial}'],
      [apigwv2.HttpMethod.GET, '/api/v1/patients/{patientId}/devices'],
      [apigwv2.HttpMethod.POST, '/api/v1/devices/{serial}/provision'],
      [apigwv2.HttpMethod.POST, '/api/v1/devices/{serial}/end-assignment'],
      [apigwv2.HttpMethod.POST, '/api/v1/devices/{serial}/decommission'],
      [apigwv2.HttpMethod.POST, '/api/v1/devices/{serial}/recover'],
      [apigwv2.HttpMethod.POST, '/api/v1/devices/{serial}/force-reset'],
      [apigwv2.HttpMethod.POST, '/api/v1/devices/{serial}/move-facility'],
      [apigwv2.HttpMethod.POST, '/api/v1/devices/{serial}/move-client'],
      [apigwv2.HttpMethod.POST, '/api/v1/admin/devices'],
    ];
    for (const [method, p] of deviceRoutes) {
      this.httpApi.addRoutes({
        path: p,
        methods: [method],
        integration: deviceApiIntegration,
        authorizer: userPoolAuthorizer,
      });
    }

    // ── discharge-cascade Lambda (DDB Stream on Patients) ──────────
    const dischargeCascade = new ProcessingLambda(this, 'DischargeCascade', {
      config,
      functionName: `gosteady-${env}-discharge-cascade`,
      handlerDir: path.join(__dirname, '..', '..', 'lambda', 'discharge-cascade'),
      description: 'Phase 2A-DL — Patients.status=discharged → end all active DeviceAssignments',
      memoryMb: 256,
      timeoutSeconds: 30,
      powertoolsLayer,
      tracingActive: true,
      environment: {
        ENVIRONMENT: env,
        DEVICES_TABLE: dataStack.deviceTable.tableName,
        ASSIGNMENTS_TABLE: dataStack.deviceAssignmentsTable.tableName,
      },
    });
    dataStack.deviceTable.grantReadWriteData(dischargeCascade.function);
    dataStack.deviceAssignmentsTable.grantReadWriteData(dischargeCascade.function);
    identityKey.grantEncryptDecrypt(dischargeCascade.function);
    auditKey.grantEncryptDecrypt(dischargeCascade.function);
    dischargeCascade.function.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['iot:UpdateThingShadow'],
      resources: [`arn:aws:iot:${this.region}:${this.account}:thing/*`],
    }));

    // Attach DDB Stream event source (NEW_AND_OLD_IMAGES from 0B-rev)
    dischargeCascade.function.addEventSource(new DynamoEventSource(dataStack.patientsTable, {
      startingPosition: lambda.StartingPosition.LATEST,
      batchSize: 10,
      retryAttempts: 3,
      // Filter: only process MODIFY/INSERT where new status=discharged.
      // DDB Streams filter syntax (AWS doc'd JSON-pattern):
      filters: [
        lambda.FilterCriteria.filter({
          eventName: lambda.FilterRule.isEqual('MODIFY'),
          dynamodb: { NewImage: { status: { S: ['discharged'] } } },
        }),
        lambda.FilterCriteria.filter({
          eventName: lambda.FilterRule.isEqual('INSERT'),
          dynamodb: { NewImage: { status: { S: ['discharged'] } } },
        }),
      ],
    }));

    // ── device-shadow-handler Lambda (IoT Topic Rule) ──────────────
    const shadowHandler = new ProcessingLambda(this, 'DeviceShadowHandler', {
      config,
      functionName: `gosteady-${env}-device-shadow-handler`,
      handlerDir: path.join(__dirname, '..', '..', 'lambda', 'device-shadow-handler'),
      description: 'Phase 2A-DL — handles reported.reset_complete shadow updates → ready_to_provision',
      memoryMb: 256,
      timeoutSeconds: 15,
      powertoolsLayer,
      tracingActive: true,
      environment: {
        ENVIRONMENT: env,
        DEVICES_TABLE: dataStack.deviceTable.tableName,
        ASSIGNMENTS_TABLE: dataStack.deviceAssignmentsTable.tableName,
      },
    });
    dataStack.deviceTable.grantReadWriteData(shadowHandler.function);
    dataStack.deviceAssignmentsTable.grantReadWriteData(shadowHandler.function);
    auditKey.grantEncryptDecrypt(shadowHandler.function);
    shadowHandler.function.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['iot:UpdateThingShadow'],
      resources: [`arn:aws:iot:${this.region}:${this.account}:thing/*`],
    }));

    // New IoT Topic Rule for reset_complete. Same source topic as the
    // existing threshold-detector rule (1B-rev); both fire on every
    // shadow update. Each Lambda filters for its concern.
    const shadowRule = new iot.CfnTopicRule(this, 'ShadowResetCompleteRule', {
      ruleName: `gosteady_${env}_shadow_reset_complete`,
      topicRulePayload: {
        description: 'Routes shadow update/documents → device-shadow-handler (resets discontinued → ready)',
        sql:
          'SELECT current.state.reported AS reported, ' +
          'previous.state.reported AS previous_reported, ' +
          'topic(3) AS thingName, ' +
          'timestamp() AS rule_ts_ms ' +
          "FROM '$aws/things/+/shadow/update/documents'",
        awsIotSqlVersion: '2016-03-23',
        ruleDisabled: false,
        actions: [{ lambda: { functionArn: shadowHandler.function.functionArn } }],
      },
    });
    shadowHandler.function.addPermission('AllowIotInvoke', {
      principal: new iam.ServicePrincipal('iot.amazonaws.com'),
      action: 'lambda:InvokeFunction',
      sourceArn: shadowRule.attrArn,
    });

    // ── L16 alarm: stuck in provisioned >24h ───────────────────────
    // CloudWatch Logs metric filter on the device-api log group counts
    // `device.activation_sent` events. A separate filter counts
    // `device.activated` events. Math alarm: filter1 - filter2 > 0 for
    // >24h would indicate an activation that never got acked. For MVP
    // simplicity we just alarm on `device.activation_sent` count > 0
    // with `device.activated` count = 0 in the same 24h window via
    // metric-math, and trust the operational follow-up to investigate.
    // (Per-device tracking with metric dimensioning is overkill at MVP
    // volume — at first-prod-customer scale, we'll move to a real
    // per-device metric.)
    const activationSentMetric = deviceApi.function.logGroup.addMetricFilter('ActivationSentFilter', {
      filterPattern: logs.FilterPattern.literal('{ $.event = "device.activation_sent" }'),
      metricNamespace: `GoSteady/Audit/${env}`,
      metricName: 'DeviceActivationSent',
      metricValue: '1',
      defaultValue: 0,
    });
    // device.activated is emitted by the heartbeat-processor (1B-rev), not
    // device-api. Read it from that log group via a parallel filter.
    const heartbeatLogGroup = logs.LogGroup.fromLogGroupName(
      this, 'HeartbeatProcessorLogRef',
      `/aws/lambda/gosteady-${env}-heartbeat-processor`,
    );
    const activationAckMetric = heartbeatLogGroup.addMetricFilter('ActivationAckFilter', {
      filterPattern: logs.FilterPattern.literal('{ $.event = "device.activated" }'),
      metricNamespace: `GoSteady/Audit/${env}`,
      metricName: 'DeviceActivated',
      metricValue: '1',
      defaultValue: 0,
    });

    const sentMetric = activationSentMetric.metric({
      period: cdk.Duration.hours(24),
      statistic: 'Sum',
    });
    const ackedMetric = activationAckMetric.metric({
      period: cdk.Duration.hours(24),
      statistic: 'Sum',
    });
    const stuckExpression = new cloudwatch.MathExpression({
      expression: 'sent - acked',
      usingMetrics: { sent: sentMetric, acked: ackedMetric },
      period: cdk.Duration.hours(24),
      label: 'unacked_activations_24h',
    });

    const stuckAlarm = new cloudwatch.Alarm(this, 'DeviceStuckInProvisioned', {
      alarmName: `gosteady-${env}-device-stuck-in-provisioned`,
      alarmDescription:
        'L16: device.activation_sent count exceeds device.activated count over 24h — at least ' +
        'one provisioned device has not echoed last_cmd_id in its heartbeat. Investigate via ' +
        'Device Registry rows in `provisioned` state with old outstandingActivationCmds entries.',
      metric: stuckExpression,
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    stuckAlarm.addAlarmAction(snsAction);

    // ── L17 alarm: wipe-ack stuck >24h (AA-battery-recycle, 2026-05-17) ──
    // Sibling of L16 for the new wipe-ack path. device-api emits
    // `device.wipe_requested` on every end-assignment; heartbeat-processor
    // OR device-shadow-handler emits `device.wipe_complete` on ack.
    // Math alarm: requested - complete > 0 for 24h indicates at least
    // one device that received the wipe cmd but never acked (firmware
    // bug, device permanently offline, etc.). Admin force-reset clears.
    // Spec: 2026-05-17-aa-battery-recycle.md memo §9 W-R1 + ARCH DL15.
    const wipeRequestedMetric = deviceApi.function.logGroup.addMetricFilter('WipeRequestedFilter', {
      filterPattern: logs.FilterPattern.literal('{ $.event = "device.wipe_requested" }'),
      metricNamespace: `GoSteady/Audit/${env}`,
      metricName: 'DeviceWipeRequested',
      metricValue: '1',
      defaultValue: 0,
    });
    // device.wipe_complete can fire from either heartbeat-processor or
    // device-shadow-handler. We attach a metric filter on each log group;
    // CloudWatch sums them under the same metric name.
    const wipeCompleteHeartbeatMetric = heartbeatLogGroup.addMetricFilter('WipeCompleteHeartbeatFilter', {
      filterPattern: logs.FilterPattern.literal('{ $.event = "device.wipe_complete" }'),
      metricNamespace: `GoSteady/Audit/${env}`,
      metricName: 'DeviceWipeComplete',
      metricValue: '1',
      defaultValue: 0,
    });
    const shadowLogGroup = logs.LogGroup.fromLogGroupName(
      this, 'DeviceShadowHandlerLogRef',
      `/aws/lambda/gosteady-${env}-device-shadow-handler`,
    );
    const wipeCompleteShadowMetric = shadowLogGroup.addMetricFilter('WipeCompleteShadowFilter', {
      filterPattern: logs.FilterPattern.literal('{ $.event = "device.wipe_complete" }'),
      metricNamespace: `GoSteady/Audit/${env}`,
      metricName: 'DeviceWipeComplete',
      metricValue: '1',
      defaultValue: 0,
    });
    // Reference the unified metric for the math expression (both filters
    // emit into the same metric name, so we just query the namespace).
    const wipeRequestedSum = wipeRequestedMetric.metric({
      period: cdk.Duration.hours(24),
      statistic: 'Sum',
    });
    const wipeCompletedSum = new cloudwatch.Metric({
      namespace: `GoSteady/Audit/${env}`,
      metricName: 'DeviceWipeComplete',
      period: cdk.Duration.hours(24),
      statistic: 'Sum',
    });
    void wipeCompleteHeartbeatMetric;  // referenced for the implicit metric-filter side-effect
    void wipeCompleteShadowMetric;

    const wipeStuckExpression = new cloudwatch.MathExpression({
      expression: 'requested - completed',
      usingMetrics: { requested: wipeRequestedSum, completed: wipeCompletedSum },
      period: cdk.Duration.hours(24),
      label: 'unacked_wipes_24h',
    });

    const wipeStuckAlarm = new cloudwatch.Alarm(this, 'DeviceWipeAckStuck', {
      alarmName: `gosteady-${env}-device-wipe-ack-stuck`,
      alarmDescription:
        'L17: device.wipe_requested count exceeds device.wipe_complete count over 24h — at least ' +
        'one discontinued device has not acked the wipe cmd (firmware bug, permanently offline, ' +
        'etc.). Admin force-reset is the recovery path. See ARCH DL15 + 2026-05-17-aa-battery-recycle.md.',
      metric: wipeStuckExpression,
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    wipeStuckAlarm.addAlarmAction(snsAction);

    // ════════════════════════════════════════════════════════════════
    // Phase 2A-RD — Patient Reads
    // ════════════════════════════════════════════════════════════════
    //
    // Single patient-api Lambda + 5 GET routes. Read-only against DDB
    // (Patients, Activity Series, Alert History, Organizations,
    // DeviceAssignments, Device Registry, RoleAssignments). No DDB
    // writes, no IoT publishes, no state machine.
    //
    // RoleAssignments lives in the Auth stack (not Data stack) because
    // it carries the family_viewer linkedPatientIds + role+scope tuples
    // that the Pre-Token Lambda reads at sign-in. patient-api needs
    // read access for the family_viewer auth chain.
    //
    // Spec: docs/specs/phase-2a-read.md
    const patientApi = new ProcessingLambda(this, 'PatientApi', {
      config,
      functionName: `gosteady-${env}-patient-api`,
      handlerDir: path.join(__dirname, '..', '..', 'lambda', 'patient-api'),
      description: 'Phase 2A-RD patient reads — 5 GET endpoints; tenancy + scope; audit emission',
      memoryMb: config.patientApiMemoryMb,
      timeoutSeconds: config.patientApiTimeoutSeconds,
      powertoolsLayer,
      tracingActive: true,
      environment: {
        ENVIRONMENT: env,
        PATIENTS_TABLE: dataStack.patientsTable.tableName,
        ACTIVITY_TABLE: dataStack.activityTable.tableName,
        ALERTS_TABLE: dataStack.alertTable.tableName,
        ORGANIZATIONS_TABLE: dataStack.organizationsTable.tableName,
        DEVICE_ASSIGNMENTS_TABLE: dataStack.deviceAssignmentsTable.tableName,
        DEVICES_TABLE: dataStack.deviceTable.tableName,
        ROLE_ASSIGNMENTS_TABLE: authStack.roleAssignmentsTable.tableName,
      },
    });
    // Read-only grants on every table the Lambda queries.
    dataStack.patientsTable.grantReadData(patientApi.function);
    dataStack.activityTable.grantReadData(patientApi.function);
    dataStack.alertTable.grantReadData(patientApi.function);
    dataStack.organizationsTable.grantReadData(patientApi.function);
    dataStack.deviceAssignmentsTable.grantReadData(patientApi.function);
    dataStack.deviceTable.grantReadData(patientApi.function);
    authStack.roleAssignmentsTable.grantReadData(patientApi.function);
    // IdentityKey CMK for the CMK-encrypted identity tables (Patients,
    // Organizations, DeviceAssignments, RoleAssignments are all
    // CMK-encrypted per Phase 0B-rev + 0A-rev).
    identityKey.grantDecrypt(patientApi.function);
    // AuditKey: emit_audit writes go to the handler log group, which is
    // forwarded to the audit log group by the Audit stack's forwarder.
    // Forwarder + audit log group encrypt with AuditKey; patient-api's
    // own log group is AWS-managed-encrypted (no AuditKey needed here),
    // BUT emit_audit may produce audit-shape lines that downstream
    // KMS-encrypted streams need to decrypt. Grant for symmetry with
    // device-api (same pattern, same justification — see 2A-DL block).
    auditKey.grantEncryptDecrypt(patientApi.function);

    // Wire 5 routes to the existing HTTP API + JWT authorizer.
    const patientApiIntegration = new HttpLambdaIntegration(
      'PatientApiIntegration',
      patientApi.function,
    );
    const patientRoutes: Array<[apigwv2.HttpMethod, string]> = [
      [apigwv2.HttpMethod.GET, '/api/v1/patients/{id}'],
      [apigwv2.HttpMethod.GET, '/api/v1/patients/{id}/activity'],
      [apigwv2.HttpMethod.GET, '/api/v1/patients/{id}/alerts'],
      [apigwv2.HttpMethod.GET, '/api/v1/me/patients'],
      [apigwv2.HttpMethod.GET, '/api/v1/facilities/{facilityId}/censuses/{censusId}/patients'],
    ];
    for (const [method, p] of patientRoutes) {
      this.httpApi.addRoutes({
        path: p,
        methods: [method],
        integration: patientApiIntegration,
        authorizer: userPoolAuthorizer,
      });
    }

    // patient-api alarms (mirrors 1.6 per-handler pattern):
    //   1. Lambda Errors > 0 in 5 min (uncaught exceptions)
    //   2. ERROR-pattern log filter (logged-and-swallowed errors;
    //      Powertools level=ERROR or [ERROR] substring)
    const patientApiErrorsAlarm = new cloudwatch.Alarm(this, 'PatientApiErrors', {
      alarmName: `gosteady-${env}-patient-api-errors`,
      alarmDescription:
        'patient-api Lambda Errors > 0 in 5 min — uncaught exception in a ' +
        'read handler. Check /aws/lambda/gosteady-{env}-patient-api.',
      metric: patientApi.function.metricErrors({
        period: cdk.Duration.minutes(5),
        statistic: 'Sum',
      }),
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    patientApiErrorsAlarm.addAlarmAction(snsAction);

    const patientApiErrorPatternFilter = patientApi.function.logGroup.addMetricFilter(
      'PatientApiErrorPattern',
      {
        filterPattern: logs.FilterPattern.literal('{ $.level = "ERROR" }'),
        metricNamespace: `GoSteady/Handlers/${env}`,
        metricName: 'PatientApiErrorLogLines',
        metricValue: '1',
        defaultValue: 0,
      },
    );
    const patientApiErrorPatternAlarm = new cloudwatch.Alarm(this, 'PatientApiErrorPatternAlarm', {
      alarmName: `gosteady-${env}-patient-api-error-log-pattern`,
      alarmDescription:
        'patient-api emitted >0 ERROR-level structured log lines in 5 min ' +
        '(logged-and-swallowed handler error or Powertools ERROR-level event).',
      metric: patientApiErrorPatternFilter.metric({
        period: cdk.Duration.minutes(5),
        statistic: 'Sum',
      }),
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    patientApiErrorPatternAlarm.addAlarmAction(snsAction);

    // ════════════════════════════════════════════════════════════════
    // Phase 2A-AA — Alert Actions
    // ════════════════════════════════════════════════════════════════
    //
    // Single alert-actions Lambda + 3 routes:
    //   PATCH /api/v1/alerts/{patientId}/{timestamp}    (ack)
    //   GET   /api/v1/patients/{id}/thresholds          (read effective)
    //   PUT   /api/v1/patients/{id}/thresholds          (set override)
    //
    // Writes back to Patients table (thresholds map attribute) +
    // Alert History (ack fields). Threshold Detector amended separately
    // in Processing stack to consume per-patient overrides on shadow
    // delta.
    //
    // Spec: docs/specs/phase-2a-alert-actions.md
    const alertActions = new ProcessingLambda(this, 'AlertActions', {
      config,
      functionName: `gosteady-${env}-alert-actions`,
      handlerDir: path.join(__dirname, '..', '..', 'lambda', 'alert-actions'),
      description: 'Phase 2A-AA — alert ack + per-patient threshold overrides',
      memoryMb: config.alertActionsMemoryMb,
      timeoutSeconds: config.alertActionsTimeoutSeconds,
      powertoolsLayer,
      tracingActive: true,
      environment: {
        ENVIRONMENT: env,
        PATIENTS_TABLE: dataStack.patientsTable.tableName,
        ALERTS_TABLE: dataStack.alertTable.tableName,
        ROLE_ASSIGNMENTS_TABLE: authStack.roleAssignmentsTable.tableName,
      },
    });
    // Patients: read for tenancy + scope; write for thresholds.update
    dataStack.patientsTable.grantReadWriteData(alertActions.function);
    // Alert History: read for ack lookup; write for ack fields
    dataStack.alertTable.grantReadWriteData(alertActions.function);
    // RoleAssignments: read-only for family_viewer linkedPatientIds
    authStack.roleAssignmentsTable.grantReadData(alertActions.function);
    // KMS — identity-bearing tables (Patients + RoleAssignments are
    // CMK-encrypted per 0A-rev + 0B-rev). Alert History is AWS-managed.
    identityKey.grantEncryptDecrypt(alertActions.function);
    auditKey.grantEncryptDecrypt(alertActions.function);

    // 3 routes
    const alertActionsIntegration = new HttpLambdaIntegration(
      'AlertActionsIntegration',
      alertActions.function,
    );
    const alertActionsRoutes: Array<[apigwv2.HttpMethod, string]> = [
      [apigwv2.HttpMethod.PATCH, '/api/v1/alerts/{patientId}/{timestamp}'],
      [apigwv2.HttpMethod.GET, '/api/v1/patients/{id}/thresholds'],
      [apigwv2.HttpMethod.PUT, '/api/v1/patients/{id}/thresholds'],
    ];
    for (const [method, p] of alertActionsRoutes) {
      this.httpApi.addRoutes({
        path: p,
        methods: [method],
        integration: alertActionsIntegration,
        authorizer: userPoolAuthorizer,
      });
    }

    // Lambda Errors + ERROR-pattern log filter alarms (mirrors 1.6 + 2A-RD pattern)
    const alertActionsErrorsAlarm = new cloudwatch.Alarm(this, 'AlertActionsErrors', {
      alarmName: `gosteady-${env}-alert-actions-errors`,
      alarmDescription:
        'alert-actions Lambda Errors > 0 in 5 min — uncaught exception. ' +
        'Check /aws/lambda/gosteady-{env}-alert-actions.',
      metric: alertActions.function.metricErrors({
        period: cdk.Duration.minutes(5),
        statistic: 'Sum',
      }),
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    alertActionsErrorsAlarm.addAlarmAction(snsAction);

    const alertActionsErrorPatternFilter = alertActions.function.logGroup.addMetricFilter(
      'AlertActionsErrorPattern',
      {
        filterPattern: logs.FilterPattern.literal('{ $.level = "ERROR" }'),
        metricNamespace: `GoSteady/Handlers/${env}`,
        metricName: 'AlertActionsErrorLogLines',
        metricValue: '1',
        defaultValue: 0,
      },
    );
    const alertActionsErrorPatternAlarm = new cloudwatch.Alarm(this, 'AlertActionsErrorPatternAlarm', {
      alarmName: `gosteady-${env}-alert-actions-error-log-pattern`,
      alarmDescription:
        'alert-actions emitted >0 ERROR-level structured log lines in 5 min.',
      metric: alertActionsErrorPatternFilter.metric({
        period: cdk.Duration.minutes(5),
        statistic: 'Sum',
      }),
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    alertActionsErrorPatternAlarm.addAlarmAction(snsAction);

    // ── 2A-DL outputs ──────────────────────────────────────────────
    new cdk.CfnOutput(this, 'DeviceApiName', {
      value: deviceApi.function.functionName,
      exportName: `${env}-DeviceApiName`,
    });
    new cdk.CfnOutput(this, 'DischargeCascadeName', {
      value: dischargeCascade.function.functionName,
      exportName: `${env}-DischargeCascadeName`,
    });
    new cdk.CfnOutput(this, 'DeviceShadowHandlerName', {
      value: shadowHandler.function.functionName,
      exportName: `${env}-DeviceShadowHandlerName`,
    });
    // ── 2A-RD outputs ──────────────────────────────────────────────
    new cdk.CfnOutput(this, 'PatientApiName', {
      value: patientApi.function.functionName,
      exportName: `${env}-PatientApiName`,
    });
    // ── 2A-AA outputs ──────────────────────────────────────────────
    new cdk.CfnOutput(this, 'AlertActionsName', {
      value: alertActions.function.functionName,
      exportName: `${env}-AlertActionsName`,
    });

    // ── Outputs (existing 2A-0) ───────────────────────────────────
    new cdk.CfnOutput(this, 'HttpApiUrl', {
      value: this.httpApi.apiEndpoint,
      exportName: `${env}-PortalApiUrl`,
      description: 'Base URL for the GoSteady Portal API HTTP API',
    });
    new cdk.CfnOutput(this, 'HttpApiId', {
      value: this.httpApi.apiId,
      exportName: `${env}-PortalApiId`,
    });
    new cdk.CfnOutput(this, 'StubLambdaName', {
      value: apiStub.function.functionName,
      exportName: `${env}-ApiStubName`,
    });
  }
}
