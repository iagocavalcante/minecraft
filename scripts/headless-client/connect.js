// Headless Bedrock client for exercising the Elixir server's join sequence.
//
// Usage: node connect.js [host] [port]
// Exits 0 once the client spawns (join sequence fully works), 1 on
// timeout/disconnect/parse error. Logs every relevant packet so a failure
// pinpoints the first bad packet the server sent.
const bedrock = require('bedrock-protocol')

const host = process.argv[2] || '127.0.0.1'
const port = parseInt(process.argv[3] || '19132', 10)

const client = bedrock.createClient({
  host,
  port,
  username: 'TestBot',
  offline: true,
  version: '1.26.30',
  // raknet-native has no prebuild for current macOS; the JS implementation
  // works everywhere and is fast enough for a test harness.
  raknetBackend: 'jsp-raknet'
})

const log = (...args) => console.log(new Date().toISOString().slice(11, 23), ...args)

client.on('status', (s) => log('status:', s))
client.on('join', () => log('join: server accepted login'))

client.on('packet', ({ data: { name, params } }) => {
  switch (name) {
    case 'play_status':
      log(`packet play_status: ${params.status}`)
      break
    case 'start_game':
      log('packet start_game: parsed OK,',
        `gamemode=${params.player_gamemode} pos=${JSON.stringify(params.player_position)}`)
      break
    case 'level_chunk':
      log(`packet level_chunk: x=${params.x} z=${params.z}`,
        `sub_chunk_count=${params.sub_chunk_count} payload=${params.payload.length}b`)
      break
    case 'item_registry':
    case 'item_component':
      log(`packet ${name}: ${params.entries ? params.entries.length : '?'} entries`)
      break
    case 'network_chunk_publisher_update':
    case 'chunk_radius_update':
    case 'resource_packs_info':
    case 'resource_pack_stack':
    case 'network_settings':
      log(`packet ${name}`)
      break
    case 'disconnect':
      log('packet disconnect:', JSON.stringify(params))
      break
  }
})

client.on('spawn', () => {
  log('SPAWNED — join sequence is fully working')
  client.close()
  process.exit(0)
})

client.on('error', (err) => {
  log('ERROR:', err.message || err)
})

client.on('close', () => log('connection closed'))
client.on('kick', (reason) => {
  log('KICKED:', JSON.stringify(reason))
  process.exit(1)
})

setTimeout(() => {
  log('TIMEOUT: did not spawn within 30s')
  process.exit(1)
}, 30000)
