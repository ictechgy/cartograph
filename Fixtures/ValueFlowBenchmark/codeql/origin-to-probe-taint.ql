/**
 * Report taint flow from origin literals to the second argument of probe.
 *
 * The result is intentionally kept separate from value flow. A taint path can cross
 * a transformation that preserves influence without proving that the literal value
 * reaches the sink.
 *
 * @name Origin literals reaching probe by taint flow
 * @kind table
 * @id cartograph/value-flow-benchmark-taint
 */

import swift
import codeql.swift.dataflow.DataFlow
import codeql.swift.dataflow.TaintTracking

private predicate isOriginLiteral(DataFlow::Node node, string origin) {
  exists(StringLiteralExpr literal |
    node.asExpr() = literal and
    literal.getValue() = origin
  )
}

private predicate isProbeValue(DataFlow::Node node, string label) {
  exists(CallExpr call, Argument argument |
    call.getStaticTarget().(Function).getShortName() = "probe" and
    argument = call.getArgumentWithLabel("value") and
    node.asExpr() = argument.getExpr() and
    label = call.getArgumentWithLabel("label").getExpr().(StringLiteralExpr).getValue()
  )
}

module OriginTaintConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node node) {
    isOriginLiteral(node, "origin-A") or
    isOriginLiteral(node, "origin-B")
  }

  predicate isSink(DataFlow::Node node) {
    exists(string label | isProbeValue(node, label))
  }
}

module OriginTaintFlow = TaintTracking::Global<OriginTaintConfig>;

from DataFlow::Node source, DataFlow::Node sink, string origin, string label
where
  OriginTaintFlow::flow(source, sink) and
  isOriginLiteral(source, origin) and
  isProbeValue(sink, label)
select source, sink, label, origin
