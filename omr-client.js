/**
 * OMR Agent Client
 * usage: AGENT_NAME=rose node omr-client.js
 */
const AGENT_NAME = process.env.AGENT_NAME || 'unknown';
const ADMIN_HOST = process.env.ADMIN_HOST || 'http://openclaw-admin:18999';
const POLL_INTERVAL = 3000;

console.log(`[OMR] Agent ${AGENT_NAME} starting... connecting to ${ADMIN_HOST}`);

let lastMessageId = 0;

// Initialize: Get latest ID to avoid replying to old history upon restart
async function init() {
    try {
        const res = await fetch(`${ADMIN_HOST}/api/omr/history?limit=5`);
        if (res.ok) {
            const data = await res.json();
            // If there are messages, we start from the last one heard
            if (data.messages && data.messages.length > 0) {
                lastMessageId = data.messages[data.messages.length - 1].id;
            }
        }
        console.log(`[OMR] Initialized. Listening from ID: ${lastMessageId}`);

        // Start polling loop
        setInterval(poll, POLL_INTERVAL);

        // Send a wake-up signal
        await sendWakeUpSignal();

    } catch (err) {
        console.error('[OMR] Init failed (is Admin Panel up?):', err.message);
        setTimeout(init, 5000); // Retry logic
    }
}

async function sendWakeUpSignal() {
    try {
        await fetch(`${ADMIN_HOST}/api/omr/send`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-Agent-ID': AGENT_NAME,
                'Authorization': `Bearer ${process.env.AGENT_TOKEN}`
            },
            body: JSON.stringify({
                content: `🔵 **${AGENT_NAME}** is online and listening.`,
                type: 'text',
                agent_status: 'online'
            })
        });
    } catch (e) { /* ignore */ }
}

async function poll() {
    try {
        const res = await fetch(`${ADMIN_HOST}/api/omr/history?since_id=${lastMessageId}`);
        if (!res.ok) return;

        const data = await res.json();
        const messages = data.messages || [];

        for (const msg of messages) {
            // Update cursor to ensure we don't process again
            lastMessageId = Math.max(lastMessageId, msg.id);

            // Filter: Only listen to Human (kimfull) or maybe System
            if (msg.sender !== 'kimfull') continue;

            const content = msg.content.toLowerCase();
            const me = AGENT_NAME.toLowerCase();

            // Trigger logic:
            // 1. Direct mention: "@rose"
            // 2. Broadcast: "@all"
            if (content.includes(`@${me}`) || content.includes('@all')) {
                console.log(`[OMR] Received command: ${msg.content}`);
                await reply(msg);
            }
        }
    } catch (err) {
        console.error('[OMR] Poll error:', err.message);
    }
}

async function reply(triggerMsg) {
    // This is where we will hook into LLM logic later.
    // For now, simple echo.
    const response = `🤖 **${AGENT_NAME}** received task: "${triggerMsg.content}"\n_Processing logic placeholder..._`;

    try {
        // Send immediate response
        await fetch(`${ADMIN_HOST}/api/omr/send`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-Agent-ID': AGENT_NAME,
                'Authorization': `Bearer ${process.env.AGENT_TOKEN}`
            },
            body: JSON.stringify({
                content: response,
                type: 'text',
                reply_to_id: triggerMsg.id,
                agent_status: 'working'
            })
        });

        // Simulate work done after 2 seconds
        setTimeout(async () => {
            try {
                await fetch(`${ADMIN_HOST}/api/omr/send`, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'X-Agent-ID': AGENT_NAME,
                        'Authorization': `Bearer ${process.env.AGENT_TOKEN}`
                    },
                    body: JSON.stringify({
                        content: `✅ Task complete.`,
                        type: 'text',
                        agent_status: 'idle'
                    })
                });
            } catch (e) { console.error('[OMR] Async reply failed', e); }
        }, 2000);

    } catch (err) {
        console.error('[OMR] Reply failed:', err.message);
    }
}

// Start
init();
