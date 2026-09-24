## before-fix (Playbot 0.117.0 envelope snapshot)
- get_thread_card: ERROR: Playbot 0.117.0 returned a thread snapshot without agentStatus, phase, userInputRequests, approvalRequests, mcpElicitationRequests, respondingRequestIds, pendingMessages, outboundMessages. This surface is verified against Playbot 0.95.x; re-verify the snapshot shape before trusting these tools.
- list_queued_messages: ERROR: Playbot 0.117.0 returned a thread snapshot without agentStatus, phase, userInputRequests, approvalRequests, mcpElicitationRequests, respondingRequestIds, pendingMessages, outboundMessages. This surface is verified against Playbot 0.95.x; re-verify the snapshot shape before trusting these tools.
- send_message: ERROR: Playbot 0.117.0 returned a send snapshot for chat-0117-probe without pendingMessages, outboundMessages, so whether the message was delivered or is only held cannot be read. This surface is verified against Playbot 0.95.x; re-verify the snapshot shape, and check list_queued_messages before resending.
- dispatch: ERROR: Playbot 0.117.0 returned a send snapshot for chat-0117-probe without pendingMessages, outboundMessages, so whether the message was delivered or is only held cannot be read. This surface is verified against Playbot 0.95.x; re-verify the snapshot shape, and check list_queued_messages before resending. SUPERVISION NOT ARMED: this worker was dispatched and nothing is polling it. /tmp/fm-playbot-lanes.ijzNdd/fixture/controller/state does not exist, so PLAYBOT_LANES_CONTROLLER_ROOT is not a firstmate home that can hold a watcher poll Arm a poll before relying on a wake, or supervise it by hand with get_thread_status, read_thread, get_thread_card.
- drop_queued_message: outcome=recalled queueAfter.queued=undefined verifiedVersions=0.95.x
- answer_thread_card: ERROR: Playbot 0.117.0 returned a thread snapshot without agentStatus, phase, userInputRequests, approvalRequests, mcpElicitationRequests, respondingRequestIds, pendingMessages, outboundMessages. This surface is verified against Playbot 0.95.x; re-verify the snapshot shape before trusting these tools.
- list_queued_messages (pendingMessages dropped): ERROR: Playbot 0.117.0 returned a thread snapshot without agentStatus, phase, userInputRequests, approvalRequests, mcpElicitationRequests, respondingRequestIds, pendingMessages, outboundMessages. This surface is verified against Playbot 0.95.x; re-verify the snapshot shape before trusting these tools.
- send_message (pendingMessages:null): ERROR: Playbot 0.117.0 returned a send snapshot for chat-0117-probe without pendingMessages, outboundMessages, so whether the message was delivered or is only held cannot be read. This surface is verified against Playbot 0.95.x; re-verify the snapshot shape, and check list_queued_messages before resending.

## after-fix (Playbot 0.117.0 envelope snapshot)
- get_thread_card: parked=true status=pending_input card.requestId=117 queued=msg-117 verifiedVersions=0.95.x and 0.117.0
- list_queued_messages: queued=msg-117 sending=0
- send_message: delivery.state=queued queuedTotal=2
- dispatch: delivery.state=queued queuedTotal=3
- drop_queued_message: outcome=recalled queueAfter.queued=2 verifiedVersions=0.95.x
- answer_thread_card: answered=true statusAfter=working cardsRemaining=0
- list_queued_messages (pendingMessages dropped): ERROR: Playbot 0.117.0 returned a thread snapshot without pendingMessages. The 'threads:getSnapshot' shape is verified against Playbot 0.95.x and 0.117.0; re-verify the snapshot shape before trusting these tools.
- send_message (pendingMessages:null): ERROR: Playbot 0.117.0 returned a send snapshot for chat-0117-probe without pendingMessages, so whether the message was delivered or is only held cannot be read. The 'threads:send' return snapshot is verified against Playbot 0.95.x, and only the 'threads:getSnapshot' read against Playbot 0.95.x and 0.117.0; re-verify the snapshot shape, and check list_queued_messages before resending.

