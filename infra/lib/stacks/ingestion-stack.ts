import * as cdk from 'aws-cdk-lib/core';
import * as iot from 'aws-cdk-lib/aws-iot';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { ProcessingStack } from './processing-stack.js';

export interface IngestionStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  readonly processingStack: ProcessingStack;
}

/**
 * Device Ingestion — IoT Core MQTT broker, topic rules, device policies.
 *
 * Serial format: GS + 10 digits (e.g. GS0000001234)
 *
 * Topics:
 *   gs/{serial}/activity   → session-based activity data
 *   gs/{serial}/heartbeat  → hourly device health
 *   gs/{serial}/alert      → urgent events (tip-over)
 *   gs/{serial}/cmd        → reserved for cloud → device commands (future)
 */
export class IngestionStack extends cdk.Stack {
  public readonly deadLetterQueue: sqs.Queue;
  public readonly otaBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: IngestionStackProps) {
    super(scope, id, props);

    const { config, processingStack } = props;
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
    // Uses IoT policy variables — ${iot:Connection.Thing.ThingName}
    // resolves to the Thing Name from the device certificate.
    new iot.CfnPolicy(this, 'DevicePolicy', {
      policyName: `gosteady-${p}-device-policy`,
      policyDocument: {
        Version: '2012-10-17',
        Statement: [
          {
            Effect: 'Allow',
            Action: 'iot:Connect',
            Resource: `arn:aws:iot:${region}:${account}:client/\${iot:Connection.Thing.ThingName}`,
          },
          {
            Effect: 'Allow',
            Action: 'iot:Publish',
            Resource: `arn:aws:iot:${region}:${account}:topic/gs/\${iot:Connection.Thing.ThingName}/*`,
          },
          {
            Effect: 'Allow',
            Action: ['iot:Subscribe'],
            Resource: `arn:aws:iot:${region}:${account}:topicfilter/gs/\${iot:Connection.Thing.ThingName}/*`,
          },
          {
            Effect: 'Allow',
            Action: 'iot:Receive',
            Resource: `arn:aws:iot:${region}:${account}:topic/gs/\${iot:Connection.Thing.ThingName}/*`,
          },
          // Phase 0A→0B→firmware coord progression added Shadow as the
          // pre-activation re-check mechanism (DL14, §F.9.4 decided
          // 2026-04-26). Devices read desired.activated_at on every wake
          // and write reported.activated_at to confirm device-side persist.
          // 1A-rev spec §IoT-policy-update Statement B documents this.
          // Adding here ahead of full 1A-rev deploy so the first 4 dev
          // certs (GS9999999999 bench + GS0000000001-3 shipping) work
          // end-to-end with Shadow without waiting for 1A-rev.
          {
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

    // ── S3 bucket for firmware OTA ───────────────────────────────
    this.otaBucket = new s3.Bucket(this, 'OtaBucket', {
      bucketName: `gosteady-${p}-firmware-ota`,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy:
        p === 'prod' ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: p !== 'prod',
    });

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
    new cdk.CfnOutput(this, 'IoTEndpoint', {
      value: `See: aws iot describe-endpoint --endpoint-type iot:Data-ATS --region ${region}`,
      exportName: `${p}-IotEndpointHint`,
    });
  }
}
