# -----------------------------------------------------------------------------
# Append to ~/.zshrc — tells Colima to store VM state on the external drive.
# -----------------------------------------------------------------------------
export COLIMA_HOME="/Volumes/DataDrive/.colima"
export LIMA_HOME="/Volumes/DataDrive/.colima/_lima"

# --- git commit identity for every sandbox profile ---------------------------
# profile.sh's ensure_state() seeds [user] into a new profile's
# config/git/config from these two on first `up`, so a profile created later
# gets a commit identity without anyone remembering to pass --name/--email.
# Without them a new profile silently has none, and the agent inside it only
# finds out when a commit fails.
export GIT_USER_NAME="Your Name"
export GIT_USER_EMAIL="you@users.noreply.github.com"
