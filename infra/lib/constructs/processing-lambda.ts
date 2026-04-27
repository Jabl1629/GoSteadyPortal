import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib/core';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface ProcessingLambdaProps {
  readonly config: GoSteadyEnvConfig;
  readonly functionName: string;
  /** Directory under infra/lambda/ that holds handler.py + requirements.txt. */
  readonly handlerDir: string;
  readonly description: string;
  readonly memoryMb: number;
  readonly timeoutSeconds: number;
  readonly environment: { [key: string]: string };
}

/**
 * Lambda construct for Phase 1B handlers — Python 3.12 ARM64, with local
 * pip-bundling that vendors aws-lambda-powertools + the shared `_shared/`
 * Python module into the asset zip.
 *
 * Why local bundling: the developer machine doesn't have Docker installed
 * (single-developer setup), so CDK's docker-image bundling path isn't
 * available. CDK's `BundlingOptions.local.tryBundle` falls back to a
 * locally-executed bundling step — we run pip install + a copy from
 * `_shared/` and the handler dir directly. Pure-Python wheels (Powertools
 * 3.x is pure Python) work cross-platform; ARM64 vs x86_64 doesn't matter.
 *
 * Phase 1.6 will refactor to a shared Lambda layer; until then, each
 * handler bundle ships its own Powertools install (~6–20 MB extra).
 */
export class ProcessingLambda extends Construct {
  public readonly function: lambda.Function;

  constructor(scope: Construct, id: string, props: ProcessingLambdaProps) {
    super(scope, id);

    const sharedDir = path.resolve(__dirname, '..', '..', 'lambda', '_shared');
    if (!fs.existsSync(sharedDir)) {
      throw new Error(`Expected shared module at ${sharedDir}`);
    }
    const handlerDirAbs = path.resolve(props.handlerDir);
    if (!fs.existsSync(path.join(handlerDirAbs, 'handler.py'))) {
      throw new Error(`Expected handler.py in ${handlerDirAbs}`);
    }

    this.function = new lambda.Function(this, 'Function', {
      functionName: props.functionName,
      runtime: lambda.Runtime.PYTHON_3_12,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler.handler',
      memorySize: props.memoryMb,
      timeout: cdk.Duration.seconds(props.timeoutSeconds),
      environment: {
        POWERTOOLS_SERVICE_NAME: props.functionName,
        POWERTOOLS_TRACER_DISABLED: 'true', // Phase 1.6 will activate X-Ray
        ...props.environment,
      },
      description: props.description,
      logRetention: logs.RetentionDays.ONE_MONTH,
      code: lambda.Code.fromAsset(handlerDirAbs, {
        bundling: {
          // Image is required for CDK bundling-option type, but we use the
          // local tryBundle path on this machine (no Docker installed).
          image: lambda.Runtime.PYTHON_3_12.bundlingImage,
          command: [
            'bash',
            '-c',
            'pip install -r requirements.txt -t /asset-output && cp -au . /asset-output && cp -auv ' +
              path.basename(sharedDir) +
              ' /asset-output/',
          ],
          local: {
            tryBundle(outputDir: string): boolean {
              // Copy handler files
              copyRecursive(handlerDirAbs, outputDir);
              // Copy _shared/ as a package next to handler
              const sharedDest = path.join(outputDir, path.basename(sharedDir));
              fs.mkdirSync(sharedDest, { recursive: true });
              copyRecursive(sharedDir, sharedDest);

              // pip install requirements.txt → outputDir
              const requirements = path.join(handlerDirAbs, 'requirements.txt');
              if (!fs.existsSync(requirements)) {
                return true; // nothing to install
              }
              const result = spawnSync(
                'python3',
                [
                  '-m',
                  'pip',
                  'install',
                  '--quiet',
                  '--target',
                  outputDir,
                  '--upgrade',
                  '--no-compile',
                  '-r',
                  requirements,
                ],
                { stdio: 'inherit' },
              );
              if (result.status !== 0) {
                throw new Error(
                  `pip install failed for ${handlerDirAbs} (status=${result.status})`,
                );
              }
              return true;
            },
          },
        },
      }),
    });
  }
}

function copyRecursive(src: string, dest: string): void {
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const sp = path.join(src, entry.name);
    const dp = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      // Skip pyc caches and any nested test artifacts
      if (entry.name === '__pycache__' || entry.name === '.pytest_cache') continue;
      fs.mkdirSync(dp, { recursive: true });
      copyRecursive(sp, dp);
    } else {
      fs.copyFileSync(sp, dp);
    }
  }
}
