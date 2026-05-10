# Numerai profile — setup seed for the next agent

Drop this into the numerai project repo (or hand it to the next agent as context). Tier-1-only model: rely on Numerai's platform-side controls; no separate execution machine, no scripted stake ops.

## Why Tier 1 is enough for Numerai

The single architectural fact that lets us skip the heavier tiers:

> **There is no Numerai API method to withdraw or transfer NMR off the platform.** Withdrawals are web-UI-only. A leaked API key cannot drain the wallet to an attacker address.

Worst-case from a leaked submit-only key: someone uploads garbage predictions for one of your models. Numerai caps payout/burn at ±5% of stake per round, and stake release has a 1-month lockup. Bounded, recoverable.

So the security posture reduces to: **issue narrowly-scoped keys, self-custody what's not actively staked, enable 2FA**.

## Account-side steps (do these first, on the Numerai website)

1. **2FA on your Numerai account** — settings → security. Non-API attack path; bypasses everything else if your password leaks.
2. **Revoke any all-scopes API key.** Account → Custom API Keys → revoke.
3. **Generate two scoped keys:**
   - `numerai-agent-submit` — scope: `upload_submission` only. This goes in the macolima profile env.
   - `numerai-stake-mgmt` — scopes: `stake-get`, `stake-increase`, `stake-decrease`, `stake-drain`. **Stays in your password manager.** Only used from your Mac browser / a local REPL when you're consciously managing stake.
4. **Self-custody check.** Wallet page → withdraw the portion of NMR you're *not* actively staking to a hardware-wallet address (Ledger/Trezor). Numerai's custodial wallet should hold "stake working capital" only.

Auth format (for reference): `Authorization: Token <PUBLIC_ID>$<SECRET_KEY>`. Both halves come from the API key creation page; the secret is shown once.

## macolima profile setup

```bash
# 1. Create the profile workspace dir
mkdir -p /Volumes/DataDrive/repo/numerai

# 2. Place the submit-only key in the profile state dir, NOT in the repo
mkdir -p /Volumes/DataDrive/.claude-colima/profiles/numerai
cat > /Volumes/DataDrive/.claude-colima/profiles/numerai/secrets.env <<'EOF'
NUMERAI_PUBLIC_ID=<from-numerai-website>
NUMERAI_SECRET_KEY=<from-numerai-website>
EOF
chmod 600 /Volumes/DataDrive/.claude-colima/profiles/numerai/secrets.env

# 3. Bring up the profile
scripts/setup.sh numerai --name "Your Name" --email "you@example.com"
```

The `secrets.env` lands in the agent's environment because `docker-compose.yml` already loads `profiles/<p>/db.env` via `env_file:`. **Required compose change** (one-time, in the macolima repo): add a second `env_file:` entry on the `claude-agent` service:

```yaml
env_file:
  - path: /Volumes/DataDrive/.claude-colima/profiles/${PROFILE}/db.env
    required: false
  - path: /Volumes/DataDrive/.claude-colima/profiles/${PROFILE}/secrets.env
    required: false
```

The agent never sees `secrets.env` on the filesystem (it's not bind-mounted into `/workspace`); only the env vars surface inside the container.

## Sanity check (run inside the profile)

```bash
scripts/profile.sh numerai exec python -c "
import numerapi
n = numerapi.NumerAPI()
print('user ok:', bool(n.get_user()))
try:
    n.stake_set('your-model-name', 0.0)
    print('STAKE WORKS — your key is over-scoped, regenerate as upload_submission only')
except Exception as e:
    print('stake denied (correct):', type(e).__name__)
"
```

`get_user()` should succeed (key is valid). `stake_set()` should fail with a permissions error. If `stake_set` succeeds, your key has stake scope — revoke and regenerate as submit-only.

## Operational rules

- **Stake changes happen in the browser**, not in the agent loop. Cost: 30 seconds per change, you're not doing it daily.
- **The submit-only key can stay in env** for the lifetime of the profile. Worst-case leak = bounded harm (one round of bad submissions, ≤5% of stake).
- **Rotate the submit key** if anything weird happens: forum advice you didn't ask for showing up in an MCP server, an unexpected commit, an attached repo you didn't recognize. Rotation is cheap (revoke + regenerate + edit `secrets.env` + `--recreate`).
- **NMR off the sandbox.** Anything beyond the working stake amount lives on hardware. The custodial wallet is for amounts you'll re-stake within ~1 month.
- **No private keys, ever, in any profile.** Hardware wallet for any signing.

## What NOT to do

- ❌ Don't use a single all-scopes API key. The submit/stake split is the whole point.
- ❌ Don't put the stake-mgmt key in the profile env "for convenience."
- ❌ Don't paste seed phrases or self-custody private keys anywhere near the sandbox.
- ❌ Don't run autonomous mode for any script that touches `numerapi.stake_*`. Submit-only autonomous is fine.

## Reference

- Numerai Staking Docs: https://docs.numer.ai/numerai-tournament/staking
- Custom API Keys: Account → Custom API Keys on numer.ai
- numerapi Python lib: https://numerapi.readthedocs.io/
- Forum (long-form research, public, WebFetch-able): https://forum.numer.ai/
