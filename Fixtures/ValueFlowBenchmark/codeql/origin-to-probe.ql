/**
 * Report value-preserving flow from origin literals to the second argument of probe.
 *
 * This query deliberately uses CodeQL's value-flow module. The companion taint query
 * reports the broader taint relation, so the benchmark can show where taint adds paths
 * that do not preserve the literal value.
 *
 * @name Origin literals reaching probe by value flow
 * @kind table
 * @id cartograph/value-flow-benchmark
 */

import swift
import codeql.swift.dataflow.DataFlow

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

module OriginValueConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node node) {
    isOriginLiteral(node, "origin-A") or
    isOriginLiteral(node, "origin-B")
  }

  predicate isSink(DataFlow::Node node) {
    exists(string label | isProbeValue(node, label))
  }
}

module OriginValueFlow = DataFlow::Global<OriginValueConfig>;

from DataFlow::Node source, DataFlow::Node sink, string origin, string label
where
  OriginValueFlow::flow(source, sink) and
  isOriginLiteral(source, origin) and
  isProbeValue(sink, label)
select source, sink, label, origin
