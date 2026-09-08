/**
 * List literal constants occurring directly at probe's value argument.
 *
 * This is a syntax observation, separate from interprocedural value-flow results.
 * It provides a stable view of literal-at-sink cases without claiming that a
 * non-literal expression has a statically known runtime value.
 *
 * @name Literal constants observed at probe sinks
 * @kind table
 * @id cartograph/value-flow-benchmark-constants
 */

import swift

from CallExpr call, StringLiteralExpr literal, string label
where
  call.getStaticTarget().(Function).getShortName() = "probe" and
  literal = call.getArgumentWithLabel("value").getExpr() and
  label = call.getArgumentWithLabel("label").getExpr().(StringLiteralExpr).getValue()
select literal, label, literal.getValue()
