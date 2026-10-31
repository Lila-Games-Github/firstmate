### Asynchronous handoffs

When an asynchronous handoff replaces a poll, review it through the complete consumer path: success, producer failure, delivery exhaustion, and any partial-success branch that already changed durable state.
Drive each path from the producer through the paused consumer or supervisor and assert the required wake arrives without polling.
The landing successor and unrecorded-receipt cases in [`tests/fm-merge-local.test.sh`](../../../tests/fm-merge-local.test.sh) (`test_landing_steers_next_queue_car` and `test_unrecorded_receipt_still_steers_next_queue_car`) cover the consumer side; the capped-notification escalation in [`tests/fm-test-service.test.sh`](../../../tests/fm-test-service.test.sh) covers delivery exhaustion and the supervising wake.

