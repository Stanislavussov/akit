---
kind: flow
---
# order-to-billing

[[orders-api]] publishes the `order.created` event; [[billing]] reads it and makes the invoice.
A duplicate event is ignored by its order id.
