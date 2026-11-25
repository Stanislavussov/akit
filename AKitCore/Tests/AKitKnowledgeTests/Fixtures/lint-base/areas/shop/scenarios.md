---
description: The rules and scenarios of cancelling an order.
---
# Scenarios — orders

A plan cites SC-ORD-001 (defined) and SC-ORD-099 (no note defines it).

## R-ORD-01 Cancel until shipped

```gherkin
# R-ORD-01 · ADO 123456 · status: agreed
Rule: An order can be cancelled until it is shipped

  # SC-ORD-001 · ADO 123456 · level: e2e · journey · status: agreed
  # test: lint-repo · tests/cancel.test.ts · cancel › refunds a paid order
  Scenario: The customer cancels a paid order before shipping

  # SC-ORD-001 · ADO 123456 · level: unit · status: agreed
  Scenario: A copy with the same ID

  # SC-ORD-002 · ADO 123457 · status: agreed
  # test: lint-repo · tests/cancel.test.ts · cancel › keeps a shipped order as it is
  Scenario: A shipped order cannot be cancelled
```

## R-PAY-01 Another feature

```gherkin
# R-PAY-01 · status: draft
Rule: Payments are refunded within a week
```
