# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(git zsh-autosuggestions history-substring-search zsh-syntax-highlighting)

source $ZSH/oh-my-zsh.sh

# uv shims
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# Primary, flow-independent SSH defense: clear SSH_AUTH_SOCK in every
# interactive shell. VS Code Dev Containers auto-injects this on every attach
# (no extension setting disables it; remote.SSH.enableAgentForwarding only
# governs Remote-SSH). This unset is the actual defense — it fires on every
# entry path (VS Code attach, profile.sh attach, docker exec). A repo
# devcontainer.json's remoteEnv would NOT help: Attach to Running Container
# ignores the repo devcontainer.json entirely, and macolima ships no such
# file. openssh-client is purged from the image so the socket is unusable
# anyway, but unset removes the tripwire signal too. Safe to remove if you
# ever want SSH back inside the container.
unset SSH_AUTH_SOCK

# Companion to the unset above: VS Code's Dev Containers attach flow also
# leaves a `/tmp/vscode-ssh-auth-<id>.sock` file behind on every attach,
# which the verify-sandbox tripwire flags even though the env is empty and
# openssh-client is absent. Wipe it on shell start so the tripwire is honest.
# `(N)` is zsh's null-glob qualifier — expands to empty (silently) when no
# match, instead of zsh's default "no matches found" error which `2>/dev/null`
# wouldn't catch (it comes from zsh itself, before `rm` runs, and triggers
# p10k's instant-prompt console-output warning on every attach).
rm -f /tmp/vscode-ssh-auth-*.sock(N) 2>/dev/null || true

# Pretty ls via lsd (requires MesloLGS NF on host terminal for icons)
alias ls="lsd -lah --group-dirs first"

[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
