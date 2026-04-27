import * as cdk from 'aws-cdk-lib/core';
import * as iot from 'aws-cdk-lib/aws-iot';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { ProcessingStack } from './processing-stack.js';
import { SecurityStack } from './security-stack.js';
import { SnippetBucket } from '../constructs/snippet-bucket.js';
import { SnippetParserLambda } from '../constructs/snippet-parser-lambda.js';

export interface IngestionStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  readonly processingStack: ProcessingStack;
  readonly securityStack: SecurityStack;
}

/**
 * Device Ingestion — IoT Core MQTT broker, topic rules, device policies,
 * snippet ingestion path, OTA firmware artifact bucket.
 *
 * Serial format: GS + 10 digits (e.g. GS0000001234)
 *
 * Topics:
 *   gs/{serial}/activity   → session-based activity data
 *   gs/{serial}/heartbeat  → hourly device health
 *   gs/{serial}/alert      → urgent events (tip-over)
 *   gs/{serial}/snippet    → opportunistic raw-IMU windows (Phase 1A revision)
 *   gs/{serial}/cmd        → cloud → device commands (Phase 1A revision; v1 cmd: activate)
 *
 * Phase 1A revision additions (per docs/specs/phase-1a-revision.md):
 *   - SnippetRule + SnippetParser Lambda + snippet S3 bucket
 *   - cmd downlink topic granted via per-thing IoT policy
 *   - Shadow get/update granted on the device's own thing
 *   - OTA bucket migrated from AWS-managed SSE → FirmwareKey CMK
 *   - Per-thing IoT policy refactored from gs/<thing>/* wildcard to an
 *     explicit topic list (defense in depth, easier to audit)
 */
export class IngestionStack extends cdk.Stack {
  public readonly deadLetterQueue: sqs.Queue;
  public readonly otaBucket: s3.Bucket;
  public readonly snippetBucket: s3.Bucket;
  public readonly snippetParser: lambda.Function;

  constructor(scope: Construct, id: string, props: IngestionStackProps) {
    super(scope, id, props);

    const { config, processingStack, securityStack } = props;
    const p = config.prefix;
    const account = cdk.Stack.of(this).account;
    const region = cdk.Stack.of(this).region;

    // ── Thing Type ───────────────────────────────────────────────
    new iot.CfnThingType(this, 'WalkerCapType', {
      thingTypeName: `GoSteadyWalkerCap-${p}`,
      thingTypeProperties: {
        thingTypeDescription: 'GoSteady smart walker cap device',
        searchableAttributes: ['serialNumber', 'firmwareVersion'],
      },
    });

    // ── IoT Policy (per-device topic restriction) ────────────────
    // Phase 1A revision: refactored from gs/<thing>/* wildcard to explicit
    // topic list per spec L7 + Open Question (defense in depth, easier to
    // audit). Authorized topics:
    //   Publish (uplink):  heartbeat, activity, alert, snippet
    //   Subscribe/Receive: cmd                        (downlink only)
    //   Shadow API:        Get/UpdateThingShadow on own thing (DL14)
    const ownTopic = (suffix: string) =>
      `arn:aws:iot:${region}:${account}:topic/gs/\${iot:Connection.Thing.ThingName}/${suffix}`;
    const ownTopicFilter = (suffix: string) =>
      `arn:aws:iot:${region}:${account}:topicfilter/gs/\${iot:Connection.Thing.ThingName}/${suffix}`;

    new iot.CfnPolicy(this, 'DevicePolicy', {
      policyName: `gosteady-${p}-device-policy`,
      policyDocument: {
        Version: '2012-10-17',
        Statement: [
          {
            Sid: 'Connect',
            Effect: 'Allow',
            Action: 'iot:Connect',
            Resource: `arn:aws:iot:${region}:${account}:client/\${iot:Connection.Thing.ThingName}`,
          },
          {
            Sid: 'PublishUplinks',
            Effect: 'Allow',
            Action: 'iot:Publish',
            Resource: [
              ownTopic('heartbeat'),
              ownTopic('activity'),
              ownTopic('alert'),
              ownTopic('snippet'),
            ],
          },
          {
            Sid: 'SubscribeOwnCmd',
            Effect: 'Allow',
            Action: ['iot:Subscribe', 'iot:Receive'],
            Resource: [ownTopicFilter('cmd'), ownTopic('cmd')],
          },
          // Shadow re-check on every cellular wake (DL14, firmware coord
          // §F.9.4 decision 2026-04-26): firmware reads desired.activated_at
          // and writes reported.activated_at. Cloud's transition handlers
          // (Phase 2A) maintain the invariant that desired.activated_at is
          // non-null iff Device Registry status ∈ {provisioned, active_monitoring}.
          {
            Sid: 'OwnShadowApi',
            Effect: 'Allow',
            Action: ['iot:GetThingShadow', 'iot:UpdateThingShadow'],
            Resource: `arn:aws:iot:${region}:${account}:thing/\${iot:Connection.Thing.ThingName}`,
          },
        ],
      },
    });

    // ── Dead Letter Queue (failed rule actions) ──────────────────
    this.deadLetterQueue = new sqs.Queue(this, 'RuleDLQ', {
      queueName: `gosteady-${p}-iot-dlq`,
      retentionPeriod: cdk.Duration.days(14),
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // IAM role for IoT Rules to push to DLQ
    const dlqRole = new iam.Role(this, 'DLQRole', {
      roleName: `gosteady-${p}-iot-dlq-role`,
      assumedBy: new iam.ServicePrincipal('iot.amazonaws.com'),
    });
    this.deadLetterQueue.grantSendMessages(dlqRole);

    // Error action config reused by all rules
    const errorAction: iot.CfnTopicRule.ActionProperty = {
      sqs: {
        queueUrl: this.deadLetterQueue.queueUrl,
        roleArn: dlqRole.roleArn,
        useBase64: false,
      },
    };

    // ── IAM role for IoT Rules to invoke Lambda ──────────────────
    const ruleRole = new iam.Role(this, 'RuleLambdaRole', {
      roleName: `gosteady-${p}-iot-rule-role`,
      assumedBy: new iam.ServicePrincipal('iot.amazonaws.com'),
    });

    // Grant IoT permission to invoke each Lambda
    processingStack.activityProcessor.grantInvoke(ruleRole);
    processingStack.heartbeatProcessor.grantInvoke(ruleRole);
    processingStack.alertHandler.grantInvoke(ruleRole);
    processingStack.thresholdDetector.grantInvoke(ruleRole);

    // Also grant Lambda resource-based policy for IoT invocation
    processingStack.activityProcessor.addPermission('IotInvoke', {
      principal: new iam.ServicePrincipal('iot.amazonaws.com'),
      sourceArn: `arn:aws:iot:${region}:${account}:rule/gosteady_${p}_*`,
    });
    processingStack.heartbeatProcessor.addPermission('IotInvoke', {
      principal: new iam.ServicePrincipal('iot.amazonaws.com'),
      sourceArn: `arn:aws:iot:${region}:${account}:rule/gosteady_${p}_*`,
    });
    processingStack.alertHandler.addPermission('IotInvoke', {
      principal: new iam.ServicePrincipal('iot.amazonaws.com'),
      sourceArn: `arn:aws:iot:${region}:${account}:rule/gosteady_${p}_*`,
    });
    processingStack.thresholdDetector.addPermission('IotInvoke', {
      principal: new iam.ServicePrincipal('iot.amazonaws.com'),
      sourceArn: `arn:aws:iot:${region}:${account}:rule/gosteady_${p}_*`,
    });

    // ── Topic Rule: Activity ─────────────────────────────────────
    // Session-based activity payloads from walker cap
    new iot.CfnTopicRule(this, 'ActivityRule', {
      ruleName: `gosteady_${p}_activity`,
      topicRulePayload: {
        description: 'Routes activity session payloads to processing Lambda',
        sql: "SELECT *, topic(2) AS thingName FROM 'gs/+/activity'",
        awsIotSqlVersion: '2016-03-23',
        ruleDisabled: false,
        actions: [
          {
            lambda: {
              functionArn: processingStack.activityProcessor.functionArn,
            },
          },
        ],
        errorAction,
      },
    });

    // ── Topic Rule: Heartbeat ────────────────────────────────────
    // Hourly device health check-ins
    new iot.CfnTopicRule(this, 'HeartbeatRule', {
      ruleName: `gosteady_${p}_heartbeat`,
      topicRulePayload: {
        description: 'Routes heartbeat payloads to processing Lambda',
        sql: "SELECT *, topic(2) AS thingName FROM 'gs/+/heartbeat'",
        awsIotSqlVersion: '2016-03-23',
        ruleDisabled: false,
        actions: [
          {
            lambda: {
              functionArn: processingStack.heartbeatProcessor.functionArn,
            },
          },
        ],
        errorAction,
      },
    });

    // ── Topic Rule: Alert ────────────────────────────────────────
    // Urgent events (tip-over, fall detected)
    new iot.CfnTopicRule(this, 'AlertRule', {
      ruleName: `gosteady_${p}_alert`,
      topicRulePayload: {
        description: 'Routes alert events to handler Lambda',
        sql: "SELECT *, topic(2) AS thingName FROM 'gs/+/alert'",
        awsIotSqlVersion: '2016-03-23',
        ruleDisabled: false,
        actions: [
          {
            lambda: {
              functionArn: processingStack.alertHandler.functionArn,
            },
          },
        ],
        errorAction,
      },
    });

    // ── Topic Rule: Shadow Update (Phase 1B revision) ────────────
    // Triggers Threshold Detector on every Shadow update.
    //
    // Topic note: subscribes to `update/documents` (not `update/accepted`).
    // `update/documents` carries both `current` and `previous` full-state
    // documents, which is what the SQL projects. The phase-1b-revision
    // spec's SQL block paired `current.*`/`previous.*` with the
    // `update/accepted` topic — that's an internal inconsistency in the
    // spec; `update/accepted` only carries the merged delta as a flat
    // `state.reported` object, not the `current`/`previous` shape.
    // Resolved 2026-04-27 during deploy verification.
    new iot.CfnTopicRule(this, 'ShadowUpdateRule', {
      ruleName: `gosteady_${p}_shadow_update`,
      topicRulePayload: {
        description: 'Routes Shadow update/documents events to Threshold Detector',
        sql:
          'SELECT current.state.reported AS reported, ' +
          'previous.state.reported AS previous_reported, ' +
          'topic(3) AS thingName, ' +
          'timestamp() AS rule_ts_ms ' +
          "FROM '$aws/things/+/shadow/update/documents'",
        awsIotSqlVersion: '2016-03-23',
        ruleDisabled: false,
        actions: [
          {
            lambda: {
              functionArn: processingStack.thresholdDetector.functionArn,
            },
          },
        ],
        errorAction,
      },
    });

    // ── Snippet ingestion path (Phase 1A revision) ───────────────
    const snippetBucketConstruct = new SnippetBucket(this, 'SnippetBucketConstruct', { config });
    this.snippetBucket = snippetBucketConstruct.bucket;

    const snippetParserConstruct = new SnippetParserLambda(this, 'SnippetParserConstruct', {
      config,
      snippetBucket: this.snippetBucket,
    });
    this.snippetParser = snippetParserConstruct.function;

    // Allow IoT Rules in this stack (gosteady_<env>_*) to invoke the parser
    this.snippetParser.addPermission('IotInvoke', {
      principal: new iam.ServicePrincipal('iot.amazonaws.com'),
      sourceArn: `arn:aws:iot:${region}:${account}:rule/gosteady_${p}_*`,
    });
    this.snippetParser.grantInvoke(ruleRole);

    // ── Topic Rule: Snippet (Phase 1A revision) ──────────────────
    // Binary payload (length-prefixed JSON header + IMU samples) is
    // base64-encoded by the rule for transport into the Lambda event.
    // The Lambda parses the preamble, extracts snippet_id, and writes
    // the full payload to S3.
    new iot.CfnTopicRule(this, 'SnippetRule', {
      ruleName: `gosteady_${p}_snippet`,
      topicRulePayload: {
        description: 'Routes snippet binary payloads to SnippetParser Lambda',
        sql:
          "SELECT encode(*, 'base64') AS payload_b64, " +
          "topic(2) AS thingName, " +
          "timestamp() AS rule_ts_ms " +
          "FROM 'gs/+/snippet'",
        awsIotSqlVersion: '2016-03-23',
        ruleDisabled: false,
        actions: [
          {
            lambda: {
              functionArn: this.snippetParser.functionArn,
            },
          },
        ],
        errorAction,
      },
    });

    // ── S3 bucket for firmware OTA ───────────────────────────────
    // Phase 1A revision (L10 / D14): swap from AWS-managed SSE to
    // FirmwareKey CMK. The bucket is empty pre-Phase-5A so the
    // in-place encryption change has zero data-migration cost.
    // The CMK is imported via cross-stack ref from Security stack.
    const firmwareKey = kms.Key.fromKeyArn(this, 'FirmwareKeyRef', securityStack.firmwareKey.keyArn);

    this.otaBucket = new s3.Bucket(this, 'OtaBucket', {
      bucketName: `gosteady-${p}-firmware-ota`,
      versioned: true,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: firmwareKey,
      bucketKeyEnabled: true, // amortizes KMS calls; expected for OTA artifact downloads
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      removalPolicy:
        p === 'prod' ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: p !== 'prod',
    });

    // Allow the IoT service principal to encrypt/decrypt with the FirmwareKey
    // when delivering OTA artifacts via IoT Jobs (Phase 5A). Restricted to
    // calls originating from this account + the OTA bucket ARN.
    firmwareKey.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: `AllowIotOtaUseOf${p[0].toUpperCase()}${p.slice(1)}FirmwareKey`,
        effect: iam.Effect.ALLOW,
        principals: [new iam.ServicePrincipal('iot.amazonaws.com')],
        actions: ['kms:Decrypt', 'kms:GenerateDataKey'],
        resources: ['*'],
        conditions: {
          StringEquals: { 'aws:SourceAccount': account },
          StringLike: { 'kms:EncryptionContext:aws:s3:arn': `${this.otaBucket.bucketArn}/*` },
        },
      }),
    );

    // ── Fleet Provisioning ───────────────────────────────────────
    // IAM role that IoT Core assumes during fleet provisioning
    const provisioningRole = new iam.Role(this, 'FleetProvisioningRole', {
      roleName: `gosteady-${p}-fleet-provisioning`,
      assumedBy: new iam.ServicePrincipal('iot.amazonaws.com'),
      inlinePolicies: {
        provision: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              actions: [
                'iot:CreateThing',
                'iot:CreateCertificateFromCsr',
                'iot:RegisterCertificate',
                'iot:AttachPolicy',
                'iot:AttachThingPrincipal',
                'iot:DescribeCertificate',
                'iot:UpdateCertificate',
                'iot:AddThingToThingGroup',
              ],
              resources: ['*'],
            }),
          ],
        }),
      },
    });

    // Fleet provisioning template — auto-registers devices on first boot
    new iot.CfnProvisioningTemplate(this, 'FleetTemplate', {
      templateName: `gosteady-${p}-fleet-template`,
      description:
        'Auto-provisions GoSteady walker cap devices on first connection',
      enabled: true,
      provisioningRoleArn: provisioningRole.roleArn,
      templateBody: JSON.stringify({
        Parameters: {
          SerialNumber: { Type: 'String' },
          'AWS::IoT::Certificate::Id': { Type: 'String' },
        },
        Resources: {
          thing: {
            Type: 'AWS::IoT::Thing',
            Properties: {
              ThingName: { Ref: 'SerialNumber' },
              ThingTypeName: `GoSteadyWalkerCap-${p}`,
              AttributePayload: {
                serialNumber: { Ref: 'SerialNumber' },
              },
            },
          },
          certificate: {
            Type: 'AWS::IoT::Certificate',
            Properties: {
              CertificateId: { Ref: 'AWS::IoT::Certificate::Id' },
              Status: 'ACTIVE',
            },
          },
          policy: {
            Type: 'AWS::IoT::Policy',
            Properties: {
              PolicyName: `gosteady-${p}-device-policy`,
            },
          },
        },
      }),
    });

    // ── Outputs ──────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'DLQUrl', {
      value: this.deadLetterQueue.queueUrl,
      exportName: `${p}-IotDlqUrl`,
    });
    new cdk.CfnOutput(this, 'OtaBucketName', {
      value: this.otaBucket.bucketName,
      exportName: `${p}-OtaBucket`,
    });
    new cdk.CfnOutput(this, 'SnippetBucketName', {
      value: this.snippetBucket.bucketName,
      exportName: `${p}-SnippetBucket`,
    });
    new cdk.CfnOutput(this, 'SnippetParserArn', {
      value: this.snippetParser.functionArn,
      exportName: `${p}-SnippetParserArn`,
    });
    new cdk.CfnOutput(this, 'IoTEndpoint', {
      value: `See: aws iot describe-endpoint --endpoint-type iot:Data-ATS --region ${region}`,
      exportName: `${p}-IotEndpointHint`,
    });
  }
}
