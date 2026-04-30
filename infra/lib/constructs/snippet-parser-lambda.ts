import * as cdk from 'aws-cdk-lib/core';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as path from 'path';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface SnippetParserLambdaProps {
  readonly config: GoSteadyEnvConfig;
  readonly snippetBucket: s3.IBucket;
}

/**
 * SnippetParser Lambda — Phase 1A revision.
 *
 * IoT Rule (gs/+/snippet) base64-encodes the binary payload via
 * `encode(*, 'base64')` and invokes this Lambda. The handler parses
 * the [4-byte length prefix][JSON header][binary body] framing,
 * validates the header, and PutObject's the full payload to S3 at
 * `{serial}/{date}/{snippet_id}.bin`.
 *
 * Architecture: Python 3.12 ARM64 (G6/G7). stdlib + boto3 only — no
 * Lambda layer required.
 */
export class SnippetParserLambda extends Construct {
  public readonly function: lambda.Function;

  constructor(scope: Construct, id: string, props: SnippetParserLambdaProps) {
    super(scope, id);

    const { config, snippetBucket } = props;
    const p = config.prefix;
    const lambdaDir = path.join(__dirname, '..', '..', 'lambda', 'snippet-parser');

    this.function = new lambda.Function(this, 'Function', {
      functionName: `gosteady-${p}-snippet-parser`,
      runtime: lambda.Runtime.PYTHON_3_12,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(lambdaDir),
      timeout: cdk.Duration.seconds(config.snippetParserTimeoutSeconds),
      memorySize: config.snippetParserMemoryMb,
      // Phase 1.6: enable X-Ray Active Tracing. CDK auto-grants
      // AWSXRayDaemonWriteAccess (PutTraceSegments + PutTelemetryRecords)
      // on the function execution role.
      tracing: lambda.Tracing.ACTIVE,
      environment: {
        SNIPPET_BUCKET: snippetBucket.bucketName,
        ENVIRONMENT: p,
      },
      description: 'Parses snippet preamble + writes full payload to S3 (Phase 1A revision)',
      logRetention: logs.RetentionDays.ONE_MONTH,
    });

    snippetBucket.grantPut(this.function);
  }
}
