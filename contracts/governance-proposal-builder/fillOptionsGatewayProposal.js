const fs = require('node:fs')
const path = require('node:path')
const { Options } = require('@layerzerolabs/lz-v2-utilities')
const { isAddress } = require('ethers')

const DEFAULT_TEMP_PROPOSAL = 'gateway-proposal-temp.json'
const OUTPUT_FILENAME = 'gateway-proposal.json'
const SCRIPT_NAME = 'fillOptionsGatewayProposal.js'

const EXPECTED_METHOD = 'sendRemoteProposal'
const EXPECTED_EMPTY_OPTIONS = '0x'

// TODO: replace this part with fork testing and gas estimation
const DEFAULT_GAS_LIMIT = 300_000

const GOVERNANCE_OAPP_SENDER = {
  mainnet: '0x1c5D750D18917064915901048cdFb2dB815e0910',
  testnet: '0x909692c2f4979ca3fa11B5859d499308A1ec4932',
}

const SAFE_PROXY = {
  mainnet: '0x5f0F86BcEad6976711C9B131bCa5D30E767fe2bE',
  testnet: '0x3241b3A4036a356c5D7e36a432Da2B8e5739D9c9',
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
"to" address, computes the LayerZero executor lzReceive options via gas estimation by fork testing, and writes the result to ${OUTPUT_FILENAME}
next to the input file. Refuses to overwrite an existing output file.
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

/**
 * Verifies the proposal JSON has exactly the same structure as the canonical
 * gateway-proposal-temp.json: same set of keys (no extras, none missing), same
 * value types, and consistent array lengths across the per-call arrays.
 * Returns an array of error messages (empty when valid).
 */
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

function writeOutputFile(outputDir, filename, data) {
  const outputPath = path.join(outputDir, filename)
  // 'wx' makes open+create atomic and fails if the file already exists, so we
  // never overwrite an existing gateway-proposal.json (even on a TOCTOU race).
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

function main() {
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

  // 7. Compute LZ executor lzReceive options.
  const lzOptions = computeLZOptions(DEFAULT_GAS_LIMIT, 0) // always assuming native value to be sent is 0

  // 8. Build the filled proposal. Spread keeps original key order: because
  // "options" already exists in proposal.arguments, the explicit assignment
  // updates the value in-place rather than appending it at the end.
  const output = {
    ...proposal,
    arguments: {
      ...proposal.arguments,
      options: lzOptions,
    },
  }

  // 9. Write next to the input, refusing to overwrite an existing file.
  let outputPath
  try {
    outputPath = writeOutputFile(path.dirname(absolutePath), OUTPUT_FILENAME, output)
  } catch (err) {
    console.error(`Error: ${err.message}`)
    process.exit(1)
  }

  console.log(`Validated proposal:    ${absolutePath}`)
  console.log(`Network:               ${args.network}`)
  console.log(
    `LZ executor option:    lzReceive(gasLimit=${DEFAULT_GAS_LIMIT})`
  )
  console.log(`                       ${lzOptions}`)
  console.log(`Wrote output:          ${outputPath}`)
}

main()
