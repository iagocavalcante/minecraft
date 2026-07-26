// Headless interaction test: joins, breaks the block at the spawn surface,
// then places a block next to the hole, asserting the server confirms both
// with UpdateBlock packets.
//
// Usage: node interact.js [host] [port]
// Exits 0 when both interactions are confirmed, 1 on timeout.
const bedrock = require('bedrock-protocol')

const host = process.argv[2] || '127.0.0.1'
const port = parseInt(process.argv[3] || '19132', 10)

const client = bedrock.createClient({
  host,
  port,
  username: 'InteractBot',
  offline: true,
  version: '1.26.30',
  raknetBackend: 'jsp-raknet'
})

const log = (...args) => console.log(new Date().toISOString().slice(11, 23), ...args)

let surfaceY = null
const confirmed = []

const emptyItem = {
  network_id: 0,
  count: 0,
  metadata: 0,
  has_stack_id: 0,
  block_runtime_id: 0,
  extra_data: Buffer.alloc(0)
}

function useItem (actionType, blockPosition, face) {
  client.queue('inventory_transaction', {
    transaction: {
      legacy: { legacy_request_id: 0 },
      transaction_type: 'item_use',
      actions: [],
      transaction_data: {
        action_type: actionType,
        trigger_type: 'player_input',
        block_position: blockPosition,
        face,
        hotbar_slot: 0,
        held_item: emptyItem,
        player_pos: { x: 0.5, y: surfaceY + 3, z: 0.5 },
        click_pos: { x: 0.5, y: 0.5, z: 0.5 },
        block_runtime_id: 0,
        client_prediction: 'failure',
        client_cooldown_state: 'off'
      }
    }
  })
}

client.on('packet', ({ data: { name, params } }) => {
  if (name === 'start_game') {
    // Server spawns the player 3 blocks above the surface.
    surfaceY = Math.round(params.player_position.y - 3)
    log(`start_game: spawn surface y=${surfaceY}`)
  }
  if (name === 'update_block') {
    log('update_block:', JSON.stringify(params))
    confirmed.push(params)
    if (confirmed.length === 2) {
      log('BOTH INTERACTIONS CONFIRMED')
      client.close()
      process.exit(0)
    }
  }
})

client.on('spawn', () => {
  log(`spawned — breaking block at 0,${surfaceY},0`)
  useItem('break_block', { x: 0, y: surfaceY, z: 0 }, 1)

  setTimeout(() => {
    log(`placing block on top of 0,${surfaceY - 1},0`)
    useItem('click_block', { x: 0, y: surfaceY - 1, z: 0 }, 1)
  }, 700)
})

client.on('kick', (reason) => {
  log('KICKED:', JSON.stringify(reason))
  process.exit(1)
})

setTimeout(() => {
  log(`TIMEOUT — confirmed ${confirmed.length}/2 interactions`)
  process.exit(1)
}, 30000)
