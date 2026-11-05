#!/usr/bin/env node
// Claude Companion channel: lets the Companion app push Nick's spoken messages into
// THIS interactive Claude Code session (they appear in the terminal like a typed prompt),
// and gives Claude tools to look at his screen.
//
// Claude Code spawns this over stdio when started via integration/cc-voice. It talks to
// the app over http://127.0.0.1:47823 using the token in
// ~/Library/Application Support/ClaudeCompanion/token. Nothing leaves this machine.
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const BASE = 'http://127.0.0.1:47823'
const TOKEN_PATH = join(homedir(), 'Library/Application Support/ClaudeCompanion/token')
const claudePid = process.ppid
let tty = ''
try { tty = execFileSync('/bin/ps', ['-o', 'tty=', '-p', String(claudePid)]).toString().trim() } catch {}

function token() {
  try { return readFileSync(TOKEN_PATH, 'utf8').trim() } catch { return '' }
}

async function call(path, { method = 'GET', body, timeoutMs = 30000 } = {}) {
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    const r = await fetch(BASE + path, {
      method,
      signal: ctl.signal,
      headers: { 'x-companion-token': token(), 'x-claude-tty': tty, 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    })
    if (r.status === 204) return null
    const j = await r.json().catch(() => ({}))
    if (!r.ok) throw new Error(j.error || `HTTP ${r.status}`)
    return j
  } finally { clearTimeout(t) }
}

const mcp = new Server(
  { name: 'companion', version: '0.1.0' },
  {
    capabilities: { experimental: { 'claude/channel': {} }, tools: {} },
    instructions: [
      'Nick talks to this session by voice through the Claude Companion app.',
      'His spoken messages arrive as <channel source="companion" via="voice" ...>. Treat them exactly as if he had typed them here.',
      'Speech-to-text can mishear words; infer the intended meaning.',
      'If the tag has a screenshots="id1,id2" attribute, call the get_screenshot tool for each id to see what he was pointing at',
      '(a red ring marks his cursor, a red box marks a region he circled with the mouse).',
      'Your final message for the turn is read aloud to him, so make it conversational and lead with the answer.',
      "Put code, paths, long lists or other detail after a line containing only '---'; that part is shown but not spoken.",
      'Use the look tool whenever seeing his screen right now would help.',
    ].join(' '),
  },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'get_screenshot',
      description: "Fetch a screenshot Nick attached to a voice message (ids come from the channel tag's screenshots attribute).",
      inputSchema: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
    },
    {
      name: 'look',
      description: "Take a screenshot of Nick's screen right now (the display his cursor is on; red ring = cursor).",
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'speak',
      description: 'Say something aloud to Nick immediately (e.g. a quick status while you keep working). Your final reply is spoken automatically; do not repeat it here.',
      inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] },
    },
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  const { name, arguments: args = {} } = req.params
  try {
    if (name === 'get_screenshot' || name === 'look') {
      const j = name === 'look' ? await call('/look') : await call('/attachment?id=' + encodeURIComponent(args.id))
      return { content: [{ type: 'image', data: j.data, mimeType: j.media_type }] }
    }
    if (name === 'speak') {
      await call('/speak', { method: 'POST', body: { text: String(args.text || '') } })
      return { content: [{ type: 'text', text: 'spoken' }] }
    }
    throw new Error('unknown tool ' + name)
  } catch (e) {
    return { isError: true, content: [{ type: 'text', text: `Companion app: ${e.message} (is Claude Companion running?)` }] }
  }
})

await mcp.connect(new StdioServerTransport())

// When Claude Code exits it closes our stdin: tell the app right away so it stops
// targeting this session (instead of waiting for the registration to go stale).
let leaving = false
async function bye() {
  if (leaving) return
  leaving = true
  await call('/channel/bye', { method: 'POST', body: { pid: claudePid }, timeoutMs: 1500 }).catch(() => {})
  process.exit(0)
}
process.stdin.on('end', bye)
process.stdin.on('close', bye)
process.on('SIGTERM', bye)
process.on('SIGINT', bye)

// Register with the app, then long-poll for voice messages, forever. Survives app restarts.
const seen = new Set()
async function loop() {
  let registered = false
  for (;;) {
    try {
      if (!registered) {
        await call('/channel/register', { method: 'POST', body: { pid: claudePid, cwd: process.cwd() } })
        registered = true
      }
      const j = await call('/channel/poll', { timeoutMs: 35000 })
      for (const m of j?.messages ?? []) {
        if (m.id && seen.has(m.id)) {          // the app re-sends if an ack got lost: deliver once
          await call('/channel/ack', { method: 'POST', body: { id: m.id } }).catch(() => {})
          continue
        }
        if (m.id) { seen.add(m.id); if (seen.size > 200) seen.delete(seen.values().next().value) }
        const meta = { via: 'voice' }
        if (m.attachments?.length) meta.screenshots = m.attachments.join(',')
        await mcp.notification({ method: 'notifications/claude/channel', params: { content: m.text, meta } })
        if (m.id) await call('/channel/ack', { method: 'POST', body: { id: m.id } }).catch(() => {})
      }
    } catch {
      registered = false
      await new Promise(r => setTimeout(r, 3000))
    }
  }
}
loop()
