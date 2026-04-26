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

# Defense-in-depth: clear SSH_AUTH_SOCK in every interactive shell. VS Code
# Dev Containers auto-injects this on every attach (no extension setting
# disables it; remote.SSH.enableAgentForwarding only governs Remote-SSH).
# devcontainer.json's remoteEnv already empties it for VS Code-spawned
# processes; this catches any other entry path (docker exec, attach without
# a devcontainer.json, future tooling). openssh-client is purged from the
# image so the socket is unusable anyway, but unset removes the tripwire
# signal too. Safe to remove if you ever want SSH back inside the container.
unset SSH_AUTH_SOCK

# Pretty ls via lsd (requires MesloLGS NF on host terminal for icons)
alias ls="lsd -lah --group-dirs first"

[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
