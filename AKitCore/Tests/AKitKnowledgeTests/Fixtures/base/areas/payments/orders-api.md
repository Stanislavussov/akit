---
kind: service
repo: git@example.com:shop/orders-api.git
files: [src/events/order-created.ts]
---
# orders-api

Takes orders from the shop and publishes `order.created` for [[billing]].

## Events

- order created: sent once the order is saved; see [[order-to-billing]].
- retry: a failed publish is retried three times, then the order waits in the outbox.

## Owners

The checkout team.
