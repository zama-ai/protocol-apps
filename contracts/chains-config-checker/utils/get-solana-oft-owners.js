#!/usr/bin/env node

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const { Connection, PublicKey } = require('@solana/web3.js');
const { createUmi } = require('@metaplex-foundation/umi-bundle-defaults');
const { fetchMint, mplToolbox } = require('@metaplex-foundation/mpl-toolbox');
const { publicKey, unwrapOption } = require('@metaplex-foundation/umi');
const { toWeb3JsPublicKey } = require('@metaplex-foundation/umi-web3js-adapters');
const { EndpointPDADeriver, EndpointProgram } = require('@layerzerolabs/lz-solana-sdk-v2');
const { oft } = require('@layerzerolabs/oft-v2-solana-sdk');

const REQUIRED_ENV = ['SOLANA_RPC_URL', 'SOLANA_OFT_MINT'];

function validateEnv() {
  const missing = REQUIRED_ENV.filter((key) => !process.env[key]);
  if (missing.length > 0) {
    console.error(`Missing required environment variables: ${missing.join(', ')}`);
    process.exit(1);
  }
}

async function main() {
  validateEnv();

  const rpcUrl = process.env.SOLANA_RPC_URL;
  const oftMintAddress = process.env.SOLANA_OFT_MINT;

  const connection = new Connection(rpcUrl);
  const umi = createUmi(rpcUrl).use(mplToolbox());

  const oftMintKey = publicKey(oftMintAddress);

  // Fetch mint account for authority info
  let mintAuthority;
  try {
    const mintAccount = await fetchMint(umi, oftMintKey);
    mintAuthority = unwrapOption(mintAccount.mintAuthority);
  } catch (e) {
    console.error(`Failed to fetch mint account at ${oftMintKey.toBase58()}:`, e.message);
    process.exit(1);
  }

  let oftStoreInfo;
  let oftStoreKey = publicKey(mintAuthority);
  try {
    oftStoreInfo = await oft.accounts.fetchOFTStore(umi, oftStoreKey);
  } catch (e) {
    console.error(`Failed to fetch OFT Store account at ${oftStoreKey.toBase58()}:`, e.message);
    process.exit(1);
  }

  // Derive OAppRegistry PDA from the endpoint program and fetch delegate
  const endpointProgramKey = new PublicKey(oftStoreInfo.endpointProgram);
  const epDeriver = new EndpointPDADeriver(endpointProgramKey);
  const [oAppRegistryPda] = epDeriver.oappRegistry(toWeb3JsPublicKey(oftStoreKey));

  let oAppRegistryInfo;
  try {
    oAppRegistryInfo = await EndpointProgram.accounts.OAppRegistry.fromAccountAddress(
      connection,
      oAppRegistryPda
    );
  } catch (e) {
    console.error(`Failed to fetch OAppRegistry at ${oAppRegistryPda.toBase58()}:`, e.message);
    process.exit(1);
  }

  console.log('\n=== Solana OFT ===');
  console.log(`\nAdmin (Owner):   ${oftStoreInfo.admin}`);

  const delegate = oAppRegistryInfo?.delegate?.toBase58() ?? 'None';
  console.log(`\nOApp Delegate:     ${delegate}`);

  console.log(`\nToken Mint:        ${oftStoreInfo.tokenMint}`);
  console.log(`  Mint Authority:  ${mintAuthority}`);
}

main();
