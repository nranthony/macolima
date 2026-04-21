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

# Pretty ls via lsd (requires MesloLGS NF on host terminal for icons)
alias ls="lsd -lah --group-dirs first"

[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
