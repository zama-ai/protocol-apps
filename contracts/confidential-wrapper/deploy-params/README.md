# Submitting deploy params

## What

`deploy-params/` holds the reviewed inputs for every ConfidentialWrapper
deployment: one entry per wrapper, under `<tier>/<network>/wrappers.json`. Field-by-field
reference: [`SCHEMA.md`](./SCHEMA.md).

## How

1. **Add your entry.** Edit `<tier>/<network>/wrappers.json` (e.g. `mainnet/ethereum/wrappers.json`),
   keyed by the wrapper symbol. Each `underlying` may appear only once per network.
2. **Open a PR** against `main` with just that change. In the description, state the token being
   wrapped and the source for the denylist selector and any blocked users.
3. **Get it reviewed and merged.** Merging says these values are cleared to deploy.
4. **Zama dispatches the deploy.** The workflow runs against the merged params. You do not need
   access to it.
5. **Results land back here.** A follow-up PR adds the deployment artifacts and addresses. Registry
   registration is a separate Protocol DAO governance action.
