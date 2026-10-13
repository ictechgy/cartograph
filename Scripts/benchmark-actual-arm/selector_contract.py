"""골드 없이 열 개의 고유한 소스 질의 모양을 검증한다."""


def selectors(queries):
    if not isinstance(queries, list) or len(queries) != 10:
        raise ValueError("Exactly ten source selectors required")
    if any(not isinstance(q, dict) or set(q) != {"id", "context", "signature", "max_depth"} for q in queries):
        raise ValueError("Only source selectors are engine query inputs")
    if any(
        any(not isinstance(q[k], str) or not q[k] for k in ("id", "context", "signature"))
        or type(q["max_depth"]) is not int
        or not 1 <= q["max_depth"] <= 128
        for q in queries
    ):
        raise ValueError("Invalid source selector types")
    if (
        len({q["id"] for q in queries}) != 10
        or len({(q["context"], q["signature"]) for q in queries}) != 10
        or len({q["max_depth"] for q in queries}) != 1
    ):
        raise ValueError("Distinct semantic selectors and one common depth required")
