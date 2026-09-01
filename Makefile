# Protocol Apps Makefile
#
# Full list of SPDX identifiers can be found here: https://spdx.org/licenses/
#
# Scope is what we distribute: contracts/* ship bytecode, scripts/* ship source
# (public repo) and fhevm-cli also ships bytecode. Tooling and test dependencies
# stay in devDependencies and are excluded by --production.
# scripts/chains-config-checker is omitted: read-only view tooling.
# Deprecated packages omitted from license checks (see .github/dependabot.yml exclude-paths).
LICENSE_SKIP_PACKAGES := contracts/feesBurner contracts/pauserSetWrapper
LICENSE_PACKAGES := $(filter-out $(LICENSE_SKIP_PACKAGES),$(patsubst %/package.json,%,$(wildcard contracts/*/package.json))) scripts/fhevm-cli scripts/governance-proposal-builder
DEPLOY_PACKAGES := $(filter-out $(LICENSE_SKIP_PACKAGES),$(patsubst %/package.json,%,$(wildcard contracts/*/package.json))) scripts/fhevm-cli

# Excluded from --onlyAllow (exact name@version; bumps re-trigger review):
#
# In deployed bytecode (LZBL-1.2, PENDING):
# - lz-evm-protocol-v2@{3.0.141,3.0.142,3.0.156}
# - lz-evm-messagelib-v2@{3.0.141,3.0.142,3.0.156}  (ExecutorOptions/DVNOptions via OptionsBuilder)
#
# Cleared external use:
# - @safe-global/safe-contracts@1.4.1-2 (LGPL-3.0)
#
# Peer-install noise only — in node_modules via pnpm autoInstallPeers, not in our Solidity imports:
# - lz-evm-v1-0.7@{3.0.141,3.0.142,3.0.156} (BUSL-1.1; legacy V1 peer of messagelib-v2)
# - @chainlink/contracts-ccip@0.7.6 (BUSL-1.1; CCIP DVN peer of messagelib-v2)
# - @layerzerolabs/lz-v2-utilities@3.0.168 (BUSL-1.1; governance-proposal-builder script only)
#
# Keep on one line: license-checker splits --excludePackages on ';' without trimming.
EXCLUDE_PACKAGES := @safe-global/safe-contracts@1.4.1-2;@layerzerolabs/lz-evm-protocol-v2@3.0.141;@layerzerolabs/lz-evm-protocol-v2@3.0.142;@layerzerolabs/lz-evm-protocol-v2@3.0.156;@layerzerolabs/lz-evm-messagelib-v2@3.0.141;@layerzerolabs/lz-evm-messagelib-v2@3.0.142;@layerzerolabs/lz-evm-messagelib-v2@3.0.156;@layerzerolabs/lz-evm-v1-0.7@3.0.141;@layerzerolabs/lz-evm-v1-0.7@3.0.142;@layerzerolabs/lz-evm-v1-0.7@3.0.156;@layerzerolabs/lz-v2-utilities@3.0.168;@chainlink/contracts-ccip@0.7.6

ALLOWED_LICENSES := 0BSD;Apache-2.0;BSD-2-Clause;BSD-3-Clause;BSD-3-Clause-Clear;CC-BY-3.0;CC0-1.0;ISC;MIT;MPL-2.0;Python-2.0;WTFPL;PSF

.PHONY: help check-licenses

help:
	@echo "Protocol Apps Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  check-licenses  - Check dependency licenses for all distributed packages"
	@echo ""
	@echo "Packages: $(LICENSE_PACKAGES)"

# --excludePrivatePackages drops each package itself: license-checker reports any
# `"private": true` package as UNLICENSED regardless of its license field.
check-licenses:
	@failed=""; \
	for pkg in $(LICENSE_PACKAGES); do \
		echo "Checking licenses in $$pkg..."; \
		( \
			cd $$pkg && \
			if [ -f pnpm-lock.yaml ]; then \
				pnpm install --frozen-lockfile --ignore-scripts --config.node-linker=hoisted --prod >/dev/null; \
			else \
				npm install --ignore-scripts --no-audit --no-fund --omit=dev >/dev/null; \
			fi && \
			if echo " $(DEPLOY_PACKAGES) " | grep -q " $$pkg " && \
			   [ "$$(node -p "Object.keys(require('./package.json').dependencies||{}).length")" = "0" ]; then \
				echo "  ships Solidity but declares no production dependencies; move them out of devDependencies"; \
				exit 1; \
			fi && \
			npx --yes license-checker --production --excludePrivatePackages \
				--onlyAllow '$(ALLOWED_LICENSES)' \
				--excludePackages '$(EXCLUDE_PACKAGES)' \
				> /dev/null \
		) || failed="$$failed $$pkg"; \
	done; \
	if [ -n "$$failed" ]; then \
		echo ""; \
		echo "License check failed for:$$failed"; \
		exit 1; \
	fi; \
	echo "All license checks passed!"
