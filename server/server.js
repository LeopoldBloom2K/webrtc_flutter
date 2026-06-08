const WebSocket = require('ws');

const PORT = 8080;
const wss = new WebSocket.Server({ port: PORT });
const clients = new Set();

console.log(`Signaling server running on ws://localhost:${PORT}`);
console.log('Android emulators connect via ws://10.0.2.2:8080');

wss.on('connection', (ws) => {
  clients.add(ws);
  console.log(`[+] Client connected. Total: ${clients.size}`);

  ws.on('message', (data) => {
    const msg = data.toString();
    try {
      const parsed = JSON.parse(msg);
      console.log(`[>] type=${parsed.type}  (relay to ${clients.size - 1} peer(s))`);
    } catch {
      console.log(`[>] raw: ${msg.substring(0, 80)}`);
    }

    for (const c of clients) {
      if (c !== ws && c.readyState === WebSocket.OPEN) {
        c.send(msg);
      }
    }
  });

  ws.on('close', () => {
    clients.delete(ws);
    console.log(`[-] Client disconnected. Total: ${clients.size}`);
  });

  ws.on('error', (err) => {
    console.error('[!] WebSocket error:', err.message);
    clients.delete(ws);
  });
});
