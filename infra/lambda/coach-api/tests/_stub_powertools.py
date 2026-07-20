"""
Stub `aws_lambda_powertools` so unit tests of pure-function modules don't
need the Lambda layer installed locally. Import this module BEFORE any
`_shared.*` import. (Copied from care-circle/tests/_stub_powertools.py.)
"""
from __future__ import annotations

import sys
import types


def _install_stub() -> None:
    if "aws_lambda_powertools" in sys.modules:
        return

    pkg = types.ModuleType("aws_lambda_powertools")
    metrics_mod = types.ModuleType("aws_lambda_powertools.metrics")
    log_mod = types.ModuleType("aws_lambda_powertools.logging")
    log_formatter_mod = types.ModuleType("aws_lambda_powertools.logging.formatter")

    def _noop_or_decorator(*a, **kw):
        if len(a) == 1 and callable(a[0]) and not kw:
            return a[0]

        def _decorate(fn):
            return fn

        return _decorate

    class _NoopLogger:
        def __init__(self, *a, **kw): pass
        def __getattr__(self, _): return _noop_or_decorator
        def info(self, *a, **kw): pass
        def warning(self, *a, **kw): pass
        def error(self, *a, **kw): pass
        def exception(self, *a, **kw): pass
        def debug(self, *a, **kw): pass

    class _NoopMetrics:
        def __init__(self, *a, **kw): pass
        def __getattr__(self, _): return _noop_or_decorator
        def add_metric(self, *a, **kw): pass
        def add_dimension(self, *a, **kw): pass
        def flush_metrics(self, *a, **kw): pass

    class _NoopTracer:
        def __init__(self, *a, **kw): pass
        def __getattr__(self, _): return lambda *a, **kw: None
        def capture_lambda_handler(self, fn=None, **kw): return fn
        def capture_method(self, fn=None, **kw): return fn

    class _MetricUnit:
        Count = "Count"
        Seconds = "Seconds"
        Milliseconds = "Milliseconds"
        Bytes = "Bytes"
        Percent = "Percent"

    class _EphemeralMetrics(_NoopMetrics):
        pass

    pkg.Logger = _NoopLogger
    pkg.Metrics = _NoopMetrics
    pkg.Tracer = _NoopTracer
    metrics_mod.MetricUnit = _MetricUnit
    metrics_mod.EphemeralMetrics = _EphemeralMetrics

    class _PowertoolsFormatter:
        def __init__(self, *a, **kw): pass

    log_formatter_mod.LambdaPowertoolsFormatter = _PowertoolsFormatter
    log_mod.formatter = log_formatter_mod

    sys.modules["aws_lambda_powertools"] = pkg
    sys.modules["aws_lambda_powertools.metrics"] = metrics_mod
    sys.modules["aws_lambda_powertools.logging"] = log_mod
    sys.modules["aws_lambda_powertools.logging.formatter"] = log_formatter_mod


_install_stub()
