import * as cdk from 'aws-cdk-lib/core';
import * as logs from 'aws-cdk-lib/aws-logs';
import { IConstruct } from 'constructs';

/**
 * EnforceLogRetention — Phase 1.6 CDK Aspect.
 *
 * Walks the construct tree at synth time and sets `retentionInDays` on
 * every `AWS::Logs::LogGroup` whose retention is not already set.
 * Defense-in-depth against unbounded log cost — most explicit Lambda
 * log groups already set `logRetention`, but ad-hoc log groups (custom
 * resources, future Lambdas added without explicit retention, etc.)
 * pick up the default of "Never expire" without an aspect.
 *
 * Spec L3: 30 days dev / 90 days prod. Target retention is passed in
 * by the consumer; the aspect doesn't read GoSteadyEnvConfig directly
 * because aspects shouldn't have wide context dependencies.
 *
 * Pre-existing log groups whose retention IS explicitly set (via the
 * Lambda `logRetention` prop or a `new logs.LogGroup(... retention: ...)`
 * call) are left alone — the aspect only fills in missing retention,
 * not overrides explicit ones.
 *
 * Usage (in bin/gosteady.ts):
 *   cdk.Aspects.of(app).add(new EnforceLogRetention({ retention: ... }));
 */
export interface EnforceLogRetentionProps {
  /** Target retention to apply when missing. */
  readonly retention: logs.RetentionDays;
}

export class EnforceLogRetention implements cdk.IAspect {
  constructor(private readonly props: EnforceLogRetentionProps) {}

  visit(node: IConstruct): void {
    if (!(node instanceof logs.CfnLogGroup)) {
      return;
    }
    // If retention is already explicitly set in the template, don't override.
    // CfnLogGroup.retentionInDays is `number | undefined` — check the raw
    // CFN-property value rather than relying on a JSII getter.
    const cfn = node as cdk.CfnResource & { retentionInDays?: number };
    if (cfn.retentionInDays !== undefined && cfn.retentionInDays !== null) {
      return;
    }
    cfn.addPropertyOverride('RetentionInDays', this.props.retention);
  }
}
