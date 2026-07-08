#!/usr/bin/env node

// Verifies that the runtime bytecode deployed at a given address matches a
// locally compiled Hardhat artifact. Immutables (e.g. OZ UUPSUpgradeable's
// `address(this)` self-reference) are masked using the immutableReferences map
// from the artifact's build-info, so a legitimate deployment reports a match.

const fs = require('fs')
const path = require('path')
const { isAddress, JsonRpcProvider } = require('ethers')

const SCRIPT_NAME = 'verifyBytecode.js'
const DEFAULT_RPC_URL = 'https://ethereum-rpc.publicnode.com'

function strip0x(hex) {
  return hex.toLowerCase().replace(/^0x/, '')
}

// Loads { deployedBytecode, immutableReferences } from a Hardhat artifact path.
// immutableReferences is read from the build-info pointed to by the sibling
// .dbg.json; it is {} when unavailable (older artifacts / no immutables).
function loadArtifact(artifactPath) {
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))
  if (!artifact.deployedBytecode) {
    throw new Error(`No deployedBytecode field in artifact ${artifactPath}`)
  }

  let immutableReferences = {}
  const dbgPath = artifactPath.replace(/\.json$/, '.dbg.json')
  try {
    const dbg = JSON.parse(fs.readFileSync(dbgPath, 'utf8'))
    const buildInfoPath = path.resolve(path.dirname(dbgPath), dbg.buildInfo)
    const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, 'utf8'))
    const contract = buildInfo.output.contracts[artifact.sourceName][artifact.contractName]
    immutableReferences = contract.evm.deployedBytecode.immutableReferences || {}
  } catch (err) {
    console.warn(`Warning: could not read immutableReferences (${err.message}); comparing without masking.`)
  }

  return { deployedBytecode: strip0x(artifact.deployedBytecode), immutableReferences }
}

// Zeroes out every immutable byte-range in a hex string (no 0x prefix).
// Ranges come straight from solc's immutableReferences (byte offsets/lengths).
function maskImmutables(hex, immutableReferences) {
  const bytes = Buffer.from(hex, 'hex')
  for (const refs of Object.values(immutableReferences)) {
    for (const { start, length } of refs) {
      // Skip ranges outside this buffer (e.g. when the on-chain code is shorter
      // than the artifact, as for a proxy) — those bytes can't match anyway.
      if (start >= bytes.length) continue
      bytes.fill(0, start, Math.min(start + length, bytes.length))
    }
  }
  return bytes.toString('hex')
}

async function verifyBytecode(address, artifactPath, options = {}) {
  const rpcUrl = options.rpcUrl || DEFAULT_RPC_URL
  const provider = new JsonRpcProvider(rpcUrl)

  const { deployedBytecode: local, immutableReferences } = loadArtifact(artifactPath)

  const onchain = strip0x(await provider.getCode(address))
  if (onchain === '') {
    throw new Error(`No contract code found at ${address} on ${rpcUrl}`)
  }

  const exact = onchain === local
  const maskedOnchain = maskImmutables(onchain, immutableReferences)
  const maskedLocal = maskImmutables(local, immutableReferences)
  const matchesMasked = maskedOnchain === maskedLocal

  const immutableCount = Object.values(immutableReferences).reduce((n, r) => n + r.length, 0)

  // Locate the first residual mismatch (after masking) for diagnostics.
  let firstDiff = null
  if (!matchesMasked) {
    const len = Math.max(maskedOnchain.length, maskedLocal.length)
    for (let i = 0; i < len; i += 2) {
      if (maskedOnchain.slice(i, i + 2) !== maskedLocal.slice(i, i + 2)) {
        firstDiff = {
          byte: i / 2,
          onchain: maskedOnchain.slice(i, i + 2) || '(end)',
          local: maskedLocal.slice(i, i + 2) || '(end)',
        }
        break
      }
    }
  }

  return {
    match: exact || matchesMasked,
    exact,
    matchesMasked,
    lengthsEqual: onchain.length === local.length,
    immutableSlots: immutableCount,
    firstDiff,
  }
}

async function main() {
  const rpcIdx = process.argv.indexOf('--rpc')
  const rpcUrl = rpcIdx !== -1 ? process.argv[rpcIdx + 1] : undefined
  const positional = process.argv.slice(2).filter((a, i, arr) => {
    return a !== '--rpc' && arr[i - 1] !== '--rpc'
  })
  const [address, artifactPath] = positional

  if (!address || !artifactPath) {
    console.error(`Usage: node ${SCRIPT_NAME} <address> <artifact-path> [--rpc <url>]`)
    console.error(`Example: node ${SCRIPT_NAME} 0x5226... \\`)
    console.error('  ../../contracts/confidential-wrapper/artifacts/contracts/upgrades/ConfidentialWrapperV3.sol/ConfidentialWrapperV3.json')
    process.exit(2)
  }
  if (!isAddress(address)) {
    console.error(`Invalid Ethereum address: ${address}`)
    process.exit(2)
  }
  if (!fs.existsSync(artifactPath)) {
    console.error(`Artifact not found: ${artifactPath}`)
    process.exit(2)
  }

  try {
    console.log(`Verifying ${path.basename(artifactPath)} against ${address}...`)
    const r = await verifyBytecode(address, artifactPath, { rpcUrl })

    console.log(`  immutable slots: ${r.immutableSlots}`)

    if (r.match) {
      console.log(
        r.immutableSlots === 0
          ? '\n✅ MATCH — deployed runtime bytecode is byte-for-byte identical to the artifact.'
          : `\n✅ MATCH — deployed runtime bytecode matches the artifact (the ${r.immutableSlots} immutable slot(s) hold deployment-time values, as expected).`
      )
      process.exit(0)
    } else {
      console.log(
        `\n❌ NO MATCH — first differing byte at offset ${r.firstDiff.byte} ` +
          `(onchain=${r.firstDiff.onchain} local=${r.firstDiff.local}).`
      )
      console.log('   Likely a different compiler version/settings, different source, or unmapped immutables.')
      process.exit(1)
    }
  } catch (error) {
    console.error(`Error: ${error.message}`)
    process.exit(2)
  }
}

module.exports = { verifyBytecode, loadArtifact, maskImmutables, DEFAULT_RPC_URL }

if (require.main === module) {
  main()
}
