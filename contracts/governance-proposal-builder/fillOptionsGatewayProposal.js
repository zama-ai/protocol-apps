const fs = require('node:fs')
const path = require('node:path')
require('dotenv').config({ quiet: true })
const { Options } = require('@layerzerolabs/lz-v2-utilities')
const {
  isAddress,
  Interface,
  JsonRpcProvider,
  keccak256,
  toUtf8Bytes,
  dataSlice,
  concat,
} = require('ethers')

const DEFAULT_TEMP_PROPOSAL = 'gateway-proposal-temp.json'
const FILLED_OUTPUT_FILENAME = 'gateway-proposal-filled.json'
const ARAGON_OUTPUT_FILENAME = 'aragonProposal.json'
const SCRIPT_NAME = 'fillOptionsGatewayProposal.js'

const SEND_REMOTE_PROPOSAL_ABI = [
  'function sendRemoteProposal(address[] targets, uint256[] values, string[] functionSignatures, bytes[] datas, uint8[] operations, bytes options) payable',
]
const SEND_REMOTE_PROPOSAL_IFACE = new Interface(SEND_REMOTE_PROPOSAL_ABI)

const EXPECTED_METHOD = 'sendRemoteProposal'
const EXPECTED_EMPTY_OPTIONS = '0x'

// Buffers added on top of the summed per-call gas estimates to cover the
// pieces this script does NOT measure directly (lzReceive entry, abi.decode
// of the message, Safe module wrapping, event emission, RPC noise). The
// constant base overhead is in gas units; the proportional buffer is in
// basis points (10000 = 100%).
const GAS_BASE_OVERHEAD = 130_000
const GAS_BUFFER_BPS = 3000 // 30% safety margin on top of the total

const GOVERNANCE_OAPP_SENDER = {
  mainnet: '0x1c5D750D18917064915901048cdFb2dB815e0910',
  testnet: '0x909692c2f4979ca3fa11B5859d499308A1ec4932',
}

const SAFE_PROXY = {
  mainnet: '0x5f0F86BcEad6976711C9B131bCa5D30E767fe2bE',
  testnet: '0x3241b3A4036a356c5D7e36a432Da2B8e5739D9c9',
}

const RPC_ENV_VAR = {
  mainnet: 'RPC_GATEWAY_MAINNET',
  testnet: 'RPC_GATEWAY_TESTNET',
}

// Canonical proposal shape (mirrors gateway-proposal-temp.json):
// {
//   "to":     <GOVERNANCE_OAPP_SENDER[network]>,
//   "method": "sendRemoteProposal",
//   "arguments": {
//     "targets":            <string[]>,
//     "values":             <string[]>,
//     "functionSignatures": <string[]>,
//     "datas":              <string[]>,
//     "operations":         <string[]>,
//     "options":            "0x", // empty placeholder; this script fills it
//   }
// }
const EXPECTED_TOP_KEYS = ['to', 'method', 'arguments']
const EXPECTED_ARGS_KEYS = ['targets', 'values', 'functionSignatures', 'datas', 'operations', 'options']
const ARGS_ARRAY_KEYS = ['targets', 'values', 'functionSignatures', 'datas', 'operations']

function printUsage() {
  console.log(
    `Usage:
  npm run fill-options-gateway-proposal:<network>
  npm run fill-options-gateway-proposal:<network> -- --tempProposal <file>
  node ${SCRIPT_NAME} --network <mainnet|testnet> [--tempProposal <file>]

Flags:
  --network        REQUIRED  "mainnet" or "testnet".
  --tempProposal   OPTIONAL  Path to the proposal JSON file.
                             Default: ${DEFAULT_TEMP_PROPOSAL}
  -h, --help                 Show this help.

Reads the temp proposal, validates its structure / method / empty options /
"to" address, then forks the Gateway chain (RPC URL from .env) and
impersonates the Safe proxy to estimate the gas of each call one by one;
sums them with a constant base overhead and a proportional safety buffer
to compute the LayerZero executor lzReceive options, and writes two files
next to the input:
  - ${FILLED_OUTPUT_FILENAME}  (the filled gateway proposal, mirrors the input shape)
  - ${ARAGON_OUTPUT_FILENAME}  (the same call as a single Aragon transaction:
                               [{ to, value, data }], ready to upload to the
                               Aragon front-end)

Required env vars (one per network, set via .env, see .env.example):
  - RPC_GATEWAY_MAINNET   (used when --network mainnet)
  - RPC_GATEWAY_TESTNET   (used when --network testnet)

Refuses to overwrite either file if it already exists.
`
  )
}

function parseArgs(argv) {
  const args = {
    tempProposal: DEFAULT_TEMP_PROPOSAL,
    network: undefined,
  }

  for (let i = 2; i < argv.length; i++) {
    const flag = argv[i]
    switch (flag) {
      case '-h':
      case '--help':
        printUsage()
        process.exit(0)
      case '--tempProposal': {
        const value = argv[++i]
        if (!value) throw new Error(`Missing value for ${flag}`)
        args.tempProposal = value
        break
      }
      case '--network': {
        const value = argv[++i]
        if (!value) throw new Error(`Missing value for ${flag}`)
        if (value !== 'mainnet' && value !== 'testnet') {
          throw new Error(`--network must be "mainnet" or "testnet" (got: "${value}")`)
        }
        args.network = value
        break
      }
      default:
        throw new Error(`Unknown flag: ${flag}`)
    }
  }

  if (!args.network) {
    throw new Error('Missing required flag: --network <mainnet|testnet>')
  }

  return args
}

function loadProposal(filePath) {
  const absolutePath = path.resolve(process.cwd(), filePath)
  if (!fs.existsSync(absolutePath)) {
    throw new Error(`Proposal file not found: ${absolutePath}`)
  }
  try {
    return { absolutePath, proposal: JSON.parse(fs.readFileSync(absolutePath, 'utf8')) }
  } catch (err) {
    throw new Error(`Failed to parse JSON in ${absolutePath}: ${err.message}`)
  }
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v)
}

function checkExactKeys(obj, expectedKeys, label, errors) {
  const expectedSet = new Set(expectedKeys)
  const actualKeys = Object.keys(obj)
  const actualSet = new Set(actualKeys)

  for (const key of expectedKeys) {
    if (!actualSet.has(key)) errors.push(`${label} is missing key "${key}".`)
  }
  for (const key of actualKeys) {
    if (!expectedSet.has(key)) errors.push(`${label} has unexpected key "${key}".`)
  }
}

function validateStructure(proposal) {
  const errors = []

  if (!isPlainObject(proposal)) {
    errors.push('Root must be a JSON object.')
    return errors
  }

  checkExactKeys(proposal, EXPECTED_TOP_KEYS, '<root>', errors)

  if ('to' in proposal && typeof proposal.to !== 'string') {
    errors.push('"to" must be a string.')
  }
  if ('method' in proposal && typeof proposal.method !== 'string') {
    errors.push('"method" must be a string.')
  }

  if (!('arguments' in proposal)) return errors
  const args = proposal.arguments
  if (!isPlainObject(args)) {
    errors.push('"arguments" must be an object.')
    return errors
  }

  checkExactKeys(args, EXPECTED_ARGS_KEYS, 'arguments', errors)

  for (const key of ARGS_ARRAY_KEYS) {
    if (!(key in args)) continue
    if (!Array.isArray(args[key])) {
      errors.push(`"arguments.${key}" must be an array.`)
      continue
    }
    args[key].forEach((v, idx) => {
      if (typeof v !== 'string') {
        errors.push(`"arguments.${key}[${idx}]" must be a string (got ${typeof v}).`)
      }
    })
  }

  if ('options' in args && typeof args.options !== 'string') {
    errors.push('"arguments.options" must be a string.')
  }

  if (Array.isArray(args.targets)) {
    const targetsLen = args.targets.length
    for (const key of ARGS_ARRAY_KEYS) {
      if (key === 'targets') continue
      if (Array.isArray(args[key]) && args[key].length !== targetsLen) {
        errors.push(
          `"arguments.${key}" length (${args[key].length}) does not match "arguments.targets" length (${targetsLen}).`
        )
      }
    }
  }

  return errors
}

// Accepts any string that BigInt parses to 0n, e.g. "0", "0x0", "0x00", "00".
function isZeroNumericString(value) {
  if (typeof value !== 'string' || value.trim() === '') return false
  try {
    return BigInt(value) === 0n
  } catch {
    return false
  }
}

function computeLZOptions(gasLimit, nativeValue) {
  return Options.newOptions()
    .addExecutorLzReceiveOption(gasLimit, nativeValue)
    .toHex()
    .toString()
}

function buildOnChainCalldata(functionSignature, data) {
  if (functionSignature === '') return data
  const selector = dataSlice(keccak256(toUtf8Bytes(functionSignature)), 0, 4)
  return concat([selector, data])
}

async function estimatePerCallGas(provider, safeProxy, proposalArgs, network) {
  const { targets, functionSignatures, datas } = proposalArgs
  const estimates = []
  for (let i = 0; i < targets.length; i++) {
    const code = await provider.getCode(targets[i])
    if (code === '0x') {
      throw new Error(
        `target #${i} (${targets[i]}) has no bytecode on the ${network} Gateway chain`
      )
    }

    const calldata = buildOnChainCalldata(functionSignatures[i], datas[i])
    let gas
    try {
      gas = await provider.estimateGas({
        from: safeProxy,
        to: targets[i],
        data: calldata,
        value: 0,
      })
    } catch (err) {
      const reason = err.shortMessage || err.message
      throw new Error(
        `eth_estimateGas failed for call #${i} (target=${targets[i]}, signature="${functionSignatures[i]}"): ${reason}`
      )
    }
    estimates.push(gas)
  }
  return estimates
}

function applyGasBuffers(perCallEstimates) {
  const sumEstimates = perCallEstimates.reduce((acc, g) => acc + g, 0n)
  const subtotal = sumEstimates + BigInt(GAS_BASE_OVERHEAD)
  const buffered = (subtotal * BigInt(10_000 + GAS_BUFFER_BPS)) / 10_000n
  return { sumEstimates, subtotal, buffered }
}

/**
 * Builds the Aragon proposal payload corresponding to a filled gateway
 * proposal: a single Aragon transaction that calls sendRemoteProposal on the
 * GovernanceOAppSender with the same arguments. The shape matches what the
 * Aragon front-end expects when uploading a JSON proposal: an array of
 * { to, value, data } objects.
 */
function buildAragonProposal(filledProposal) {
  const a = filledProposal.arguments
  const data = SEND_REMOTE_PROPOSAL_IFACE.encodeFunctionData('sendRemoteProposal', [
    a.targets,
    a.values,
    a.functionSignatures,
    a.datas,
    a.operations,
    a.options,
  ])
  return [
    {
      to: filledProposal.to,
      value: 0,
      data,
    },
  ]
}

function writeOutputFile(outputDir, filename, data) {
  const outputPath = path.join(outputDir, filename)
  // 'wx' makes open+create atomic and fails if the file already exists, so we
  // never overwrite an existing output file (even on a TOCTOU race).
  try {
    fs.writeFileSync(outputPath, JSON.stringify(data, null, 2) + '\n', { flag: 'wx' })
  } catch (err) {
    if (err.code === 'EEXIST') {
      throw new Error(`Refusing to overwrite existing file: ${outputPath}`)
    }
    throw err
  }
  return outputPath
}

function assertOutputDoesNotExist(outputDir, filename) {
  const outputPath = path.join(outputDir, filename)
  if (fs.existsSync(outputPath)) {
    throw new Error(`Refusing to overwrite existing file: ${outputPath}`)
  }
}

async function main() {
  let args
  try {
    args = parseArgs(process.argv)
  } catch (err) {
    console.error(`Error: ${err.message}\n`)
    printUsage()
    process.exit(1)
  }

  let absolutePath, proposal
  try {
    ;({ absolutePath, proposal } = loadProposal(args.tempProposal))
  } catch (err) {
    console.error(`Error: ${err.message}`)
    process.exit(1)
  }

  // 1. Structural validation (must match gateway-proposal-temp.json shape).
  const structureErrors = validateStructure(proposal)
  if (structureErrors.length > 0) {
    console.error(
      `Error: ${absolutePath} does not match the expected structure of ${DEFAULT_TEMP_PROPOSAL}:`
    )
    for (const msg of structureErrors) console.error(`  - ${msg}`)
    process.exit(1)
  }

  // 2. method must be exactly "sendRemoteProposal".
  if (proposal.method !== EXPECTED_METHOD) {
    console.error(
      `Error: proposal "method" must be "${EXPECTED_METHOD}" (got "${proposal.method}").`
    )
    process.exit(1)
  }

  // 3. options must be the empty hex placeholder - this script's job is to fill it.
  if (proposal.arguments.options !== EXPECTED_EMPTY_OPTIONS) {
    console.error(
      `Error: proposal "arguments.options" must be "${EXPECTED_EMPTY_OPTIONS}" (got "${proposal.arguments.options}"). This script's purpose is to fill it; if you want to regenerate, reset it to "0x".`
    )
    process.exit(1)
  }

  // 4. "to" must match the GovernanceOAppSender for the chosen network.
  if (!isAddress(proposal.to)) {
    console.error(
      `Error: proposal "to" (${proposal.to}) is not a well-formed 0x-prefixed 20-byte hex address.`
    )
    process.exit(1)
  }
  const expectedSender = GOVERNANCE_OAPP_SENDER[args.network]
  if (proposal.to.toLowerCase() !== expectedSender.toLowerCase()) {
    console.error(
      `Error: proposal "to" (${proposal.to}) does not match the GovernanceOAppSender for ${args.network} (${expectedSender}).`
    )
    process.exit(1)
  }

  // 5. Each entry in arguments.targets must be a well-formed address.
  const invalidTargets = proposal.arguments.targets
    .map((target, index) => ({ target, index }))
    .filter(({ target }) => !isAddress(target))
  if (invalidTargets.length > 0) {
    console.error('Error: proposal "arguments.targets" contains invalid addresses:')
    for (const { target, index } of invalidTargets) {
      console.error(`  - targets[${index}] = ${target}`)
    }
    process.exit(1)
  }

  // 6. Each entry in arguments.values and arguments.operations must be zero.
  const nonZeroByKey = {}
  for (const key of ['values', 'operations']) {
    const nonZero = proposal.arguments[key]
      .map((value, index) => ({ value, index }))
      .filter(({ value }) => !isZeroNumericString(value))
    if (nonZero.length > 0) nonZeroByKey[key] = nonZero
  }
  if (Object.keys(nonZeroByKey).length > 0) {
    console.error('Error: proposal contains non-zero entries that must be zero:')
    for (const [key, entries] of Object.entries(nonZeroByKey)) {
      console.error(`  arguments.${key}:`)
      for (const { value, index } of entries) {
        console.error(`    - ${key}[${index}] = ${value}`)
      }
    }
    process.exit(1)
  }

  // 7. Estimate the lzReceive gas limit by forking the Gateway chain,
  //    impersonating the Safe proxy as msg.sender, and running
  //    eth_estimateGas for each (target, calldata) one by one. Sum the
  //    estimates and add the constant base overhead + proportional buffer.
  const rpcEnvVar = RPC_ENV_VAR[args.network]
  const rpcUrl = process.env[rpcEnvVar]
  if (!rpcUrl || rpcUrl.trim() === '') {
    console.error(
      `Error: missing env var ${rpcEnvVar} (required to fork the ${args.network} Gateway chain). Set it in .env (see .env.example).`
    )
    process.exit(1)
  }

  const safeProxy = SAFE_PROXY[args.network]
  const provider = new JsonRpcProvider(rpcUrl)
  let chainId
  try {
    chainId = (await provider.getNetwork()).chainId
  } catch (err) {
    console.error(
      `Error: failed to connect to ${rpcEnvVar}=${rpcUrl}: ${err.shortMessage || err.message}`
    )
    process.exit(1)
  }

  let perCallEstimates
  try {
    perCallEstimates = await estimatePerCallGas(provider, safeProxy, proposal.arguments, args.network)
  } catch (err) {
    console.error(`Error: ${err.message}`)
    process.exit(1)
  }
  const { sumEstimates, subtotal, buffered } = applyGasBuffers(perCallEstimates)
  const gasLimit = buffered

  // 8. Compute LZ executor lzReceive options.
  const lzOptions = computeLZOptions(gasLimit, 0) // always assuming native value to be sent is 0

  // 9. Build the filled proposal. Spread keeps original key order: because
  // "options" already exists in proposal.arguments, the explicit assignment
  // updates the value in-place rather than appending it at the end.
  const filledProposal = {
    ...proposal,
    arguments: {
      ...proposal.arguments,
      options: lzOptions,
    },
  }

  // 10. Build the Aragon proposal payload: a single { to, value, data } tx
  //     where data is the ABI-encoded sendRemoteProposal(...) calldata.
  const aragonProposal = buildAragonProposal(filledProposal)

  // 11. Write both outputs next to the input, refusing to overwrite either.
  //     Pre-check both paths first so we never end up writing only one.
  const outputDir = path.dirname(absolutePath)
  let filledPath, aragonPath
  try {
    assertOutputDoesNotExist(outputDir, FILLED_OUTPUT_FILENAME)
    assertOutputDoesNotExist(outputDir, ARAGON_OUTPUT_FILENAME)
    filledPath = writeOutputFile(outputDir, FILLED_OUTPUT_FILENAME, filledProposal)
    aragonPath = writeOutputFile(outputDir, ARAGON_OUTPUT_FILENAME, aragonProposal)
  } catch (err) {
    console.error(`Error: ${err.message}`)
    process.exit(1)
  }

  console.log(`Validated proposal:    ${absolutePath}`)
  console.log(`Network:               ${args.network} (chainId ${chainId.toString()})`)
  console.log(
    `LZ executor option (estimated gas limit via fork testing and impersonating the Safe proxy):    lzReceive(gasLimit=${gasLimit.toString()})`
  )
  console.log(`                       ${lzOptions}`)
  console.log(`Wrote filled proposal: ${filledPath}`)
  console.log(`Wrote Aragon proposal: ${aragonPath}`)
}

main().catch((err) => {
  console.error(`Error: ${err.stack || err.message || err}`)
  process.exit(1)
})
