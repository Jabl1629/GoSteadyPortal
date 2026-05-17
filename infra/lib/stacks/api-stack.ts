import * as cdk from 'aws-cdk-lib/core';
import * as apigwv2 from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpUserPoolAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as path from 'path';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { AuthStack } from './auth-stack.js';
import { DataStack } from './data-stack.js';
import { ProcessingLambda } from '../constructs/processing-lambda.js';

export interface ApiStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  readonly authStack: AuthStack;
  readonly dataStack: DataStack;
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

    const { config, authStack } = props;
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

    // ── JWT authorizer (Cognito User Pool, both App Clients) ──────
    // Single authorizer with both audiences (D2). Per-route logic
    // differentiates customer vs internal via the custom:role claim
    // inside handler code (api_authz.is_internal).
    const userPoolAuthorizer = new HttpUserPoolAuthorizer(
      'PortalUserPoolAuthorizer',
      authStack.userPool,
      {
        userPoolClients: [authStack.portalCustomerClient, authStack.portalInternalClient],
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

    // ── Outputs ────────────────────────────────────────────────────
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
