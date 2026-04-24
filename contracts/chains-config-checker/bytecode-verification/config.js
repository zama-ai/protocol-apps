/**
 * Maps the human-authored markdown docs to source-code metadata.
 *
 * Addresses stay single-source in docs/addresses/**; audit tags + commits stay
 * single-source in contracts/<pkg>/audits/README.md. This file only provides
 * what is NOT in those docs:
 *   - display name / section -> source contract + proxy flag
 *   - per-row tag overrides (e.g. Luganodes uses a different staking tag)
 *   - chain -> RPC env var + addresses doc path
 *   - optional per-package packageManager override for worktree compiles
 *
 * contracts vs sections:
 *   - contracts: a specific display name maps to one source (distinct rows)
 *   - sections: every row under a given markdown section maps to one source
 *     (long tables where each row is an instance of the same contract)
 *   - overrides: per-display-name deviations within a section (e.g. Luganodes)
 */
module.exports = {
  packages: {
    token: {
      // token uses pnpm; auto-detect should catch this from the lockfile,
      // but we set it explicitly as a safety net.
      packageManager: 'pnpm',
      contracts: {
        'Zama Token': { source: 'ZamaERC20', proxy: false },
        'Zama OFT': { source: 'ZamaOFT', proxy: false },
        'Zama OFT Adapter': { source: 'ZamaOFTAdapter', proxy: false },
      },
    },
    governance: {
      contracts: {
        'Governance OApp Sender': { source: 'GovernanceOAppSender', proxy: false },
        'Governance OApp Receiver': { source: 'GovernanceOAppReceiver', proxy: false },
      },
    },
    'confidential-wrapper': {
      sections: {
        'Confidential wrappers': { source: 'ConfidentialWrapper', proxy: true },
      },
    },
    'confidential-token-wrappers-registry': {
      contracts: {
        'Wrappers Registry': { source: 'ConfidentialTokenWrappersRegistry', proxy: true },
      },
    },
    staking: {
      sections: {
        'Protocol staking': { source: 'ProtocolStaking', proxy: true },
        'Operator staking': { source: 'OperatorStaking', proxy: true },
      },
      // (**) footnote in staking audits README: Luganodes uses a different tag
      // than the other Operator staking rows.
      overrides: {
        'Operator staking': {
          Luganodes: { tag: 'staking-v1.0.1-luganodes' },
        },
      },
    },
    feesBurner: {
      contracts: {
        ProtocolFeesBurner: { source: 'ProtocolFeesBurner', proxy: false },
        FeesSenderToBurner: { source: 'FeesSenderToBurner', proxy: false },
      },
    },
    pauserSetWrapper: {
      contracts: {
        'Pauser Set Wrapper (minting)': { source: 'PauserSetWrapper', proxy: false },
      },
    },
    safe: {
      contracts: {
        'Admin Module': { source: 'AdminModule', proxy: false },
      },
    },
    solanaOFT: {
      solana: {
        programAddress: 'A8W6AL4JhE4EDDcfXZ1Q8vQpwp83AnPj4UZ6y86gVFKN',
        anchorBin: 'zama_oft',
      },
    },
  },

  chains: {
    ethereum: { rpcEnv: 'RPC_ETHEREUM', addressesDoc: 'docs/addresses/mainnet/ethereum.md' },
    gateway: { rpcEnv: 'RPC_GATEWAY', addressesDoc: 'docs/addresses/mainnet/gateway.md' },
    bsc: { rpcEnv: 'RPC_BSC', addressesDoc: 'docs/addresses/mainnet/bsc.md' },
    hyperevm: { rpcEnv: 'RPC_HYPEREVM', addressesDoc: 'docs/addresses/mainnet/hyper_evm.md' },
    solana: { rpcEnv: 'SOLANA_RPC_URL', addressesDoc: 'docs/addresses/mainnet/solana.md' },
  },
};
