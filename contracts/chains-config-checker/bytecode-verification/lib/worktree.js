const fs = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');

/**
 * Adds a git worktree at a given commit, resolves the package manager for the
 * target contracts package, runs install + hardhat compile, and hands back the
 * path to the compiled package dir. Caller is responsible for calling
 * removeWorktree() when done.
 */

function addWorktree(repoRoot, commit, worktreeRoot) {
  fs.mkdirSync(path.dirname(worktreeRoot), { recursive: true });

  // If commit isn't reachable locally, try fetching it.
  try {
    execSync(`git -C "${repoRoot}" cat-file -e ${commit}^{commit}`, { stdio: 'ignore' });
  } catch {
    try {
      execSync(`git -C "${repoRoot}" fetch origin ${commit}`, { stdio: 'inherit' });
    } catch (e) {
      throw new Error(`Commit ${commit} not found locally and 'git fetch origin ${commit}' failed: ${e.message}`);
    }
  }

  execSync(`git -C "${repoRoot}" worktree add --detach "${worktreeRoot}" ${commit}`, {
    stdio: 'inherit',
  });
}

function removeWorktree(repoRoot, worktreeRoot) {
  try {
    execSync(`git -C "${repoRoot}" worktree remove --force "${worktreeRoot}"`, { stdio: 'inherit' });
  } catch (e) {
    console.warn(`worktree remove failed for ${worktreeRoot}: ${e.message}`);
  }
}

/**
 * Detect which package manager this contracts package uses.
 *
 * Precedence:
 *   1. package.json "packageManager" field (Corepack convention)
 *   2. explicit override from config (passed in)
 *   3. lockfile presence: pnpm-lock.yaml → pnpm, yarn.lock → yarn,
 *      package-lock.json → npm
 *   4. fallback: npm install (with a warning)
 */
function detectPackageManager(pkgDir, configOverride) {
  const pkgJsonPath = path.join(pkgDir, 'package.json');
  if (fs.existsSync(pkgJsonPath)) {
    const pkgJson = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf8'));
    if (pkgJson.packageManager) {
      const name = pkgJson.packageManager.split('@')[0];
      if (['pnpm', 'yarn', 'npm'].includes(name)) return name;
    }
  }

  if (configOverride && ['pnpm', 'yarn', 'npm'].includes(configOverride)) {
    return configOverride;
  }

  if (fs.existsSync(path.join(pkgDir, 'pnpm-lock.yaml'))) return 'pnpm';
  if (fs.existsSync(path.join(pkgDir, 'yarn.lock'))) return 'yarn';
  if (fs.existsSync(path.join(pkgDir, 'package-lock.json'))) return 'npm';

  console.warn(`no lockfile found in ${pkgDir}, defaulting to 'npm install'`);
  return 'npm-loose';
}

function installAndCompile(pkgDir, pm) {
  const installCmd = {
    pnpm: ['pnpm', ['install', '--frozen-lockfile']],
    yarn: ['yarn', ['install', '--frozen-lockfile']],
    npm: ['npm', ['ci']],
    'npm-loose': ['npm', ['install']],
  }[pm];

  const compileCmd = {
    pnpm: ['pnpm', ['exec', 'hardhat', 'compile']],
    yarn: ['yarn', ['hardhat', 'compile']],
    npm: ['npx', ['hardhat', 'compile']],
    'npm-loose': ['npx', ['hardhat', 'compile']],
  }[pm];

  runOrFail(installCmd[0], installCmd[1], pkgDir);
  runOrFail(compileCmd[0], compileCmd[1], pkgDir);
}

function runOrFail(cmd, args, cwd) {
  console.log(`  $ ${cmd} ${args.join(' ')}  (in ${cwd})`);
  const result = spawnSync(cmd, args, { cwd, stdio: 'inherit', shell: false });
  if (result.error && result.error.code === 'ENOENT') {
    throw new Error(
      `"${cmd}" not found on PATH. If this is pnpm or yarn, run \`corepack enable\` once.`
    );
  }
  if (result.status !== 0) {
    throw new Error(`command failed (exit ${result.status}): ${cmd} ${args.join(' ')}`);
  }
}

module.exports = {
  addWorktree,
  removeWorktree,
  detectPackageManager,
  installAndCompile,
};
