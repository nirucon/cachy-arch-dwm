#!/usr/bin/env bash
# =============================================================================
# dwm-setup-arch-cachy.sh
#
# Purpose
#   Install Nicklas' suckless/dwm setup on Arch Linux or CachyOS.
#
# Key design choices
#   - Suckless source tree lives in ~/.config/suckless
#   - Built binaries install to /usr/local/bin
#   - lookandfeel repo deploys into ~/.config, ~/.local/bin, ~/.local/share, ~/
#   - Supports both startx and SDDM style login-manager sessions
#   - Dry run support
#   - Verification adapts to the chosen session mode
#   - Package failures are reported at the end instead of killing the whole run
#
# Notes
#   - Run as your normal user, never as root.
#   - The script uses sudo only when needed.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------- USER CONFIG -----------------------------------

readonly SUCKLESS_REPO="https://github.com/nirucon/suckless"
readonly LOOKANDFEEL_REPO="https://github.com/nirucon/suckless_lookandfeel"
readonly LOOKANDFEEL_BRANCH="main"

readonly XDG_CONFIG_HOME_REAL="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly SUCKLESS_DIR="${XDG_CONFIG_HOME_REAL}/suckless"
readonly LOOKANDFEEL_DIR="$HOME/.cache/dwm-setup/lookandfeel"

readonly LOCAL_BIN="$HOME/.local/bin"
readonly LOCAL_SHARE="$HOME/.local/share"
readonly XDG_CONFIG_TARGET="$HOME/.config"
readonly XINITRC_DIR="$XDG_CONFIG_TARGET/xinitrc.d"
readonly DWM_CONFIG_DIR="$XDG_CONFIG_TARGET/dwm"
readonly XINITRC_FILE="$HOME/.xinitrc"

readonly INSTALL_PREFIX="/usr/local"
readonly INSTALL_BIN_DIR="${INSTALL_PREFIX}/bin"
readonly SESSION_WRAPPER="${INSTALL_BIN_DIR}/dwm-session"

# Use /usr/share/xsessions for the broadest DM compatibility.
readonly XSESSION_DIR="/usr/share/xsessions"
readonly SESSION_DESKTOP="${XSESSION_DIR}/dwm.desktop"

SUCKLESS_COMPONENTS=(
  dwm
  dmenu
  st
  slock
)

ENABLE_BACKUPS=1
DEFAULT_KEYBOARD_LAYOUT="se"
DEFAULT_BG="#111111"

# Dotfiles that should never be overwritten by the lookandfeel repo.
# These are managed separately or should remain distro/user owned.
PROTECTED_DOTFILES=(
  ".bashrc"
  ".bash_profile"
  ".zshrc"
  ".profile"
)

# Session mode:
#   auto   = always prepare startx, create SDDM/Xsession files only if a login manager exists
#   startx = only prepare startx
#   sddm   = prepare startx and require/create Xsession files
SESSION_MODE="auto"

# If 1, install sddm when SESSION_MODE=sddm and no login manager exists.
INSTALL_SDDM_IF_MISSING=0

# If 1, enable sddm after installation when it exists.
ENABLE_SDDM_SERVICE=0

PACMAN_BASE_DEPS=(
  base-devel git curl wget rsync unzip zip tar tree findutils coreutils grep sed
  gawk diffutils which file xdg-utils dbus xorg-server xorg-xinit xorg-xrandr
  xorg-xset xorg-xsetroot xorg-setxkbmap xorg-xrdb libx11 libxft libxinerama
  libxrandr libxext libxrender libxfixes freetype2 fontconfig imlib2 ttf-dejavu
  noto-fonts noto-fonts-emoji ttf-nerd-fonts-symbols-mono feh picom rofi dunst
  libnotify alacritty maim slop xclip brightnessctl playerctl pavucontrol
  pipewire pipewire-alsa pipewire-pulse wireplumber pcmanfm gvfs gvfs-mtp
  gvfs-gphoto2 gvfs-afc udisks2 udiskie blueman networkmanager
  nextcloud-client
)

# Add your extra normal pacman packages here.
PACMAN_OPTIONAL_APPS=(
  neovim ripgrep fd fzf jq btop fastfetch cmus mpv sxiv imagemagick gtk3 gtk4
  lxappearance fresh-editor gimp
)

# Add your extra paru/AUR packages here.
PARU_APPS=(
  xautolock
  ttf-jetbrains-mono-nerd
)

# ------------------------------ STYLING --------------------------------------

NC="\033[0m"; GRN="\033[1;32m"; RED="\033[1;31m"; YLW="\033[1;33m"
BLU="\033[1;34m"; CYN="\033[1;36m"; MAG="\033[1;35m"; BOLD="\033[1m"

say()   { printf "${BLU}[dwm-setup]${NC} %s\n" "$*"; }
step()  { printf "${MAG}[phase]${NC} %s\n" "$*"; }
ok()    { printf "${GRN}[ ok ]${NC} %s\n" "$*"; }
warn()  { printf "${YLW}[warn]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[fail]${NC} %s\n" "$*" >&2; }
info()  { printf "${CYN}[info]${NC} %s\n" "$*"; }
die()   { fail "$*"; exit 1; }

trap 'fail "Aborted at line $LINENO while running: ${BASH_COMMAND:-unknown}"' ERR

# ------------------------------- FLAGS ---------------------------------------

DRY_RUN=0
DO_VERIFY_ONLY=0
RUN_POST_VERIFY=1
JOBS="$(nproc 2>/dev/null || echo 2)"
SKIP_PARU=0
SKIP_LOOKANDFEEL=0
SKIP_SUCKLESS=0
SKIP_PACKAGES=0
SKIP_SESSION=0

# Summary tracking
FAILED_PACMAN_PKGS=()
FAILED_AUR_PKGS=()
FALLBACK_PACMAN_TO_AUR=()
FALLBACK_AUR_TO_PACMAN=()
SKIPPED_ITEMS=()

DISTRO_ID="unknown"
DISTRO_PRETTY="unknown"
PROFILE="unknown"
LOGIN_MANAGER="none"
EFFECTIVE_SESSION_MODE="auto"

usage() {
  cat <<EOF
${BOLD}dwm-setup-arch-cachy.sh${NC}

Install your dwm/suckless setup on an existing Arch Linux or CachyOS system.

USAGE:
  ./dwm-setup-arch-cachy.sh [options]

OPTIONS:
  --dry-run, --dryrun, -n   Show what would happen, but do not change anything
  --verify                  Only verify installation status, then exit
  --no-post-verify          Skip automatic verification after a real install
  --jobs N                  Build with N parallel jobs (default: nproc)
  --skip-paru               Do not install AUR packages via paru
  --skip-lookandfeel        Skip deployment of lookandfeel repo files
  --skip-suckless           Skip building/installing suckless components
  --skip-packages           Skip package installation
  --skip-session            Skip session/startx setup
  --session-mode MODE       auto, startx, or sddm
  -h, --help                Show this help

SESSION MODE:
  auto   Always prepares startx. Creates dwm.desktop + session wrapper only if
         a login manager is detected, or if sddm gets installed by the script.
  startx Prepares only ~/.xinitrc and ~/.config/xinitrc.d hooks.
  sddm   Prepares startx and also requires Xsession files for display managers.

PACKAGE LISTS TO EDIT IN THE SCRIPT:
  - PACMAN_OPTIONAL_APPS
  - PARU_APPS
  - SUCKLESS_COMPONENTS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|--dryrun|-n) DRY_RUN=1; shift ;;
    --verify) DO_VERIFY_ONLY=1; shift ;;
    --no-post-verify) RUN_POST_VERIFY=0; shift ;;
    --jobs) shift; JOBS="${1:-}"; [[ -n "$JOBS" ]] || die "--jobs requires a value"; shift ;;
    --skip-paru) SKIP_PARU=1; shift ;;
    --skip-lookandfeel) SKIP_LOOKANDFEEL=1; shift ;;
    --skip-suckless) SKIP_SUCKLESS=1; shift ;;
    --skip-packages) SKIP_PACKAGES=1; shift ;;
    --skip-session) SKIP_SESSION=1; shift ;;
    --session-mode)
      shift
      SESSION_MODE="${1:-}"
      [[ "$SESSION_MODE" =~ ^(auto|startx|sddm)$ ]] || die "--session-mode must be auto, startx, or sddm"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ ${EUID:-$(id -u)} -ne 0 ]] || die "Do not run this script as root. Run it as your normal user."

# ---------------------------- GENERIC HELPERS --------------------------------

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] $*"
  else
    "$@"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

need_cmd_unless_dry_run() {
  local cmd="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "Found command for dry-run: $cmd"
    else
      warn "Command not present locally, but dry-run can continue: $cmd"
    fi
  else
    need_cmd "$cmd"
  fi
}

record_unique() {
  local arr_name="$1" value="$2"
  eval "local current=(\"\${${arr_name}[@]-}\")"
  local item
  for item in "${current[@]}"; do
    [[ "$item" == "$value" ]] && return 0
  done
  eval "${arr_name}+=(\"\$value\")"
}

ensure_dir() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] mkdir -p $*"
  else
    mkdir -p "$@"
  fi
}

backup_file_if_needed() {
  local target="$1"
  [[ "$ENABLE_BACKUPS" -eq 1 ]] || return 0
  [[ -e "$target" ]] || return 0

  local ts backup
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="${target}.bak.${ts}"
  run cp -a "$target" "$backup"
  info "Backup created: $backup"
}

install_text_via_sudo() {
  local mode="$1" target="$2" content="$3"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] install text to $target (mode $mode)"
    return 0
  fi

  sudo install -d "$(dirname "$target")"
  printf '%s\n' "$content" | sudo tee "$target" >/dev/null
  sudo chmod "$mode" "$target"
}

copy_file_with_backup() {
  local src="$1" dst="$2" mode="${3:-644}"
  [[ -f "$src" ]] || { warn "Missing file: $src"; return 0; }

  if [[ -e "$dst" ]] && ! cmp -s "$src" "$dst"; then
    backup_file_if_needed "$dst"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] install -Dm${mode} $src $dst"
  else
    install -Dm"$mode" "$src" "$dst"
  fi
}

copy_dir_without_delete() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || { warn "Missing directory: $src"; return 0; }
  ensure_dir "$dst"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] rsync -a $src/ $dst/"
    return 0
  fi

  need_cmd rsync
  rsync -a "$src/" "$dst/"
}

chmod_all_files_executable() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] chmod +x all files in $dir"
  else
    find "$dir" -maxdepth 1 -type f -exec chmod +x {} +
  fi
}

pacman_repo_has_pkg() { pacman -Si "$1" >/dev/null 2>&1; }
pkg_installed() { pacman -Q "$1" >/dev/null 2>&1; }
aur_available() { command -v paru >/dev/null 2>&1; }

append_managed_block() {
  local target="$1" start_marker="$2" end_marker="$3" block="$4"
  local tmp
  tmp="$(mktemp)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] update managed block in $target"
    rm -f "$tmp"
    return 0
  fi

  touch "$target"
  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { skip=1; next }
    $0 == end   { skip=0; next }
    !skip { print }
  ' "$target" > "$tmp"

  {
    cat "$tmp"
    [[ -s "$tmp" ]] && printf '\n'
    printf '%s\n' "$start_marker"
    printf '%s\n' "$block"
    printf '%s\n' "$end_marker"
  } > "$target"

  rm -f "$tmp"
}

# ---------------------------- DISTRO DETECTION -------------------------------

read_os_release() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"

  DISTRO_ID="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
  DISTRO_PRETTY="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"

  case "${DISTRO_ID,,}" in
    cachyos) PROFILE="cachyos" ;;
    arch) PROFILE="arch" ;;
    *)
      if grep -qi "cachyos" /etc/os-release; then
        PROFILE="cachyos"
      elif grep -qi "arch" /etc/os-release; then
        PROFILE="arch"
      else
        PROFILE="unsupported"
      fi
      ;;
  esac

  [[ "$PROFILE" != "unsupported" ]] || die "This script supports Arch Linux and CachyOS only. Detected: $DISTRO_PRETTY"
}

probe_login_manager() {
  if ! command -v systemctl >/dev/null 2>&1; then
    LOGIN_MANAGER="none"
    warn "systemctl not available; login manager detection skipped"
    return 0
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q '^sddm\.service'; then
    LOGIN_MANAGER="sddm"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^plasma-login-manager\.service'; then
    LOGIN_MANAGER="plasma-login-manager"
  else
    LOGIN_MANAGER="none"
  fi
}

derive_effective_session_mode() {
  EFFECTIVE_SESSION_MODE="$SESSION_MODE"

  if [[ "$SESSION_MODE" == "auto" ]]; then
    if [[ "$LOGIN_MANAGER" == "sddm" || "$LOGIN_MANAGER" == "plasma-login-manager" ]]; then
      EFFECTIVE_SESSION_MODE="sddm"
    else
      EFFECTIVE_SESSION_MODE="startx"
    fi
  fi
}

# ---------------------------- PACKAGE HANDLING -------------------------------

ensure_paru() {
  if command -v paru >/dev/null 2>&1; then
    ok "paru already installed"
    return 0
  fi

  step "Installing paru because AUR packages are requested"
  run sudo pacman -S --needed --noconfirm base-devel git

  if pacman_repo_has_pkg paru; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      say "[dry-run] sudo pacman -S --needed --noconfirm paru"
      info "Dry-run: skipping post-install verification of paru"
      return 0
    fi
    if sudo pacman -S --needed --noconfirm paru && command -v paru >/dev/null 2>&1; then
      ok "paru installed from pacman repository"
      return 0
    fi
    warn "paru installation via pacman failed; will try paru-bin from AUR"
  fi

  local tmp aur_dir rc=0
  tmp="$(mktemp -d)"
  aur_dir="$tmp/paru-bin"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] git clone https://aur.archlinux.org/paru-bin.git $aur_dir"
    say "[dry-run] (cd $aur_dir && makepkg -si --noconfirm)"
    info "Dry-run: skipping post-install verification of paru"
    rm -rf "$tmp"
    return 0
  fi

  if ! git clone https://aur.archlinux.org/paru-bin.git "$aur_dir"; then
    warn "Could not clone paru-bin"
    rc=1
  elif ! (cd "$aur_dir" && makepkg -si --noconfirm); then
    warn "Could not build/install paru-bin"
    rc=1
  fi

  rm -rf "$tmp"
  command -v paru >/dev/null 2>&1 && { ok "paru installed"; return 0; }
  return "${rc:-1}"
}

install_one_pacman_pkg() {
  local pkg="$1"

  if pkg_installed "$pkg"; then
    ok "Package already installed: $pkg"
    return 0
  fi

  if pacman_repo_has_pkg "$pkg"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      say "[dry-run] sudo pacman -S --needed --noconfirm $pkg"
      return 0
    fi
    if sudo pacman -S --needed --noconfirm "$pkg"; then
      ok "Installed via pacman: $pkg"
      return 0
    fi
    warn "pacman could not install: $pkg"
  else
    warn "Not found in pacman repos: $pkg"
  fi

  if [[ "$SKIP_PARU" -eq 0 ]]; then
    ensure_paru || true
    if aur_available; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        say "[dry-run] paru -S --needed --noconfirm $pkg"
        record_unique FALLBACK_PACMAN_TO_AUR "$pkg"
        return 0
      fi
      if paru -S --needed --noconfirm "$pkg"; then
        ok "Installed via paru fallback: $pkg"
        record_unique FALLBACK_PACMAN_TO_AUR "$pkg"
        return 0
      fi
      warn "paru fallback also failed: $pkg"
    else
      warn "paru is not available, cannot try AUR fallback for: $pkg"
    fi
  fi

  record_unique FAILED_PACMAN_PKGS "$pkg"
  return 0
}

install_one_aur_pkg() {
  local pkg="$1"

  if pkg_installed "$pkg"; then
    ok "Package already installed: $pkg"
    return 0
  fi

  if pacman_repo_has_pkg "$pkg"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      say "[dry-run] sudo pacman -S --needed --noconfirm $pkg"
      record_unique FALLBACK_AUR_TO_PACMAN "$pkg"
      return 0
    fi
    if sudo pacman -S --needed --noconfirm "$pkg"; then
      ok "Installed via pacman fallback: $pkg"
      record_unique FALLBACK_AUR_TO_PACMAN "$pkg"
      return 0
    fi
    warn "pacman fallback failed for AUR-listed package: $pkg"
  fi

  ensure_paru || true
  if aur_available; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      say "[dry-run] paru -S --needed --noconfirm $pkg"
      return 0
    fi
    if paru -S --needed --noconfirm "$pkg"; then
      ok "Installed via paru: $pkg"
      return 0
    fi
    warn "paru could not install: $pkg"
  else
    warn "paru is not available, cannot install AUR package: $pkg"
  fi

  record_unique FAILED_AUR_PKGS "$pkg"
  return 0
}

print_install_summary() {
  printf "\n${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"
  printf "${BOLD}  Installation summary${NC}\n"
  printf "${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"

  if (( ${#FALLBACK_PACMAN_TO_AUR[@]} > 0 )); then
    warn "These pacman-listed packages were instead installed via paru/AUR:"
    printf '  - %s\n' "${FALLBACK_PACMAN_TO_AUR[@]}"
  fi
  if (( ${#FALLBACK_AUR_TO_PACMAN[@]} > 0 )); then
    warn "These AUR-listed packages were instead installed via pacman:"
    printf '  - %s\n' "${FALLBACK_AUR_TO_PACMAN[@]}"
  fi
  if (( ${#FAILED_PACMAN_PKGS[@]} > 0 )); then
    fail "These pacman-listed packages could not be installed:"
    printf '  - %s\n' "${FAILED_PACMAN_PKGS[@]}"
  fi
  if (( ${#FAILED_AUR_PKGS[@]} > 0 )); then
    fail "These AUR-listed packages could not be installed:"
    printf '  - %s\n' "${FAILED_AUR_PKGS[@]}"
  fi

  if (( ${#FAILED_PACMAN_PKGS[@]} == 0 && ${#FAILED_AUR_PKGS[@]} == 0 )); then
    ok "No unresolved package installation problems were recorded"
  else
    warn "The script continued, but you should review the missing packages above"
  fi
}

phase_packages() {
  [[ "$SKIP_PACKAGES" -eq 0 ]] || { warn "Skipping package installation"; return 0; }

  step "Installing packages"
  say "Profile detected: $PROFILE ($DISTRO_PRETTY)"

  local pacman_all=() pkg
  pacman_all+=("${PACMAN_BASE_DEPS[@]}")
  pacman_all+=("${PACMAN_OPTIONAL_APPS[@]}")

  if [[ "$EFFECTIVE_SESSION_MODE" == "sddm" && "$INSTALL_SDDM_IF_MISSING" -eq 1 && "$LOGIN_MANAGER" == "none" ]]; then
    pacman_all+=(sddm)
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] sudo pacman -Syu --noconfirm"
  else
    if ! sudo pacman -Syu --noconfirm; then
      warn "Full pacman upgrade failed; continuing anyway"
      record_unique SKIPPED_ITEMS "pacman full upgrade failed"
    fi
  fi

  say "Installing pacman-listed packages one by one (${#pacman_all[@]} total)"
  for pkg in "${pacman_all[@]}"; do
    install_one_pacman_pkg "$pkg"
  done

  if [[ "$SKIP_PARU" -eq 1 ]]; then
    warn "Skipping paru/AUR package installation by request"
  elif (( ${#PARU_APPS[@]} > 0 )); then
    say "Installing AUR-listed packages one by one (${#PARU_APPS[@]} total)"
    for pkg in "${PARU_APPS[@]}"; do
      install_one_aur_pkg "$pkg"
    done
  else
    info "No AUR packages defined; skipping paru phase"
  fi

  if [[ "$ENABLE_SDDM_SERVICE" -eq 1 ]]; then
    if pkg_installed sddm; then
      run sudo systemctl enable sddm.service
      ok "SDDM enabled"
    else
      warn "ENABLE_SDDM_SERVICE=1 but sddm is not installed"
    fi
  fi
}

# ---------------------------- REPO SYNC / BUILD ------------------------------

git_sync() {
  local url="$1" dir="$2" branch="${3:-}"

  if [[ -d "$dir/.git" ]]; then
    say "Updating repo: $dir"
    run git -C "$dir" fetch --all --prune
    [[ -n "$branch" ]] && run git -C "$dir" checkout "$branch"
    run git -C "$dir" pull --ff-only
  else
    ensure_dir "$(dirname "$dir")"
    say "Cloning repo: $url"
    if [[ -n "$branch" ]]; then
      run git clone --branch "$branch" "$url" "$dir"
    else
      run git clone "$url" "$dir"
    fi
  fi
}

phase_suckless() {
  [[ "$SKIP_SUCKLESS" -eq 0 ]] || { warn "Skipping suckless build/install"; return 0; }

  step "Syncing and building suckless components"
  git_sync "$SUCKLESS_REPO" "$SUCKLESS_DIR"

  local comp comp_dir
  for comp in "${SUCKLESS_COMPONENTS[@]}"; do
    comp_dir="$SUCKLESS_DIR/$comp"
    if [[ ! -d "$comp_dir" ]]; then
      warn "Component missing in repo: $comp"
      continue
    fi

    say "Building $comp from $comp_dir"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      say "[dry-run] make -C $comp_dir clean"
      say "[dry-run] make -C $comp_dir -j$JOBS"
      say "[dry-run] sudo make -C $comp_dir PREFIX=$INSTALL_PREFIX install"
    else
      make -C "$comp_dir" clean
      make -C "$comp_dir" -j"$JOBS"
      sudo make -C "$comp_dir" PREFIX="$INSTALL_PREFIX" install
    fi

    ok "$comp installed"
  done
}

is_protected_dotfile() {
  local name="${1##*/}"
  local item
  for item in "${PROTECTED_DOTFILES[@]}"; do
    [[ "$name" == "$item" ]] && return 0
  done
  return 1
}

# ---------------------------- LOOKANDFEEL DEPLOY -----------------------------

phase_lookandfeel() {
  [[ "$SKIP_LOOKANDFEEL" -eq 0 ]] || { warn "Skipping lookandfeel deployment"; return 0; }

  step "Syncing and deploying lookandfeel repo"
  git_sync "$LOOKANDFEEL_REPO" "$LOOKANDFEEL_DIR" "$LOOKANDFEEL_BRANCH"

  local repo="$LOOKANDFEEL_DIR" local_name name target dst src srcdir bash_profile profile_line

  ensure_dir "$LOCAL_BIN" "$LOCAL_SHARE" "$XDG_CONFIG_TARGET"

  if [[ "$DRY_RUN" -eq 1 && ! -d "$repo" ]]; then
    info "Dry-run: lookandfeel repo is not present locally yet, so repository contents cannot be inspected in this run"
    say "[dry-run] ensure PATH line exists in $HOME/.bash_profile"
    return 0
  fi

  if [[ -d "$repo/dotfiles" ]]; then
    say "Deploying dotfiles from $repo/dotfiles"
    while IFS= read -r -d '' src; do
      local_name="$(basename "$src")"
      if is_protected_dotfile "$local_name"; then
        info "Protected dotfile skipped: ~/$local_name"
        continue
      fi
      copy_file_with_backup "$src" "$HOME/$local_name" 644
    done < <(find "$repo/dotfiles" -mindepth 1 -maxdepth 1 -type f -print0)
    ok "Dotfiles deployed"
  else
    warn "No dotfiles directory found in lookandfeel repo"
  fi

  if [[ -d "$repo/config" ]]; then
    say "Deploying ~/.config content"
    while IFS= read -r -d '' srcdir; do
      name="$(basename "$srcdir")"
      target="$XDG_CONFIG_TARGET/$name"
      ensure_dir "$target"
      copy_dir_without_delete "$srcdir" "$target"
      ok "~/.config/$name updated"
    done < <(find "$repo/config" -mindepth 1 -maxdepth 1 -type d -print0)
  else
    warn "No config directory found in lookandfeel repo"
  fi

  if [[ -d "$repo/local/bin" ]]; then
    say "Deploying scripts to ~/.local/bin"
    while IFS= read -r -d '' src; do
      dst="$LOCAL_BIN/$(basename "$src")"
      copy_file_with_backup "$src" "$dst" 755
    done < <(find "$repo/local/bin" -mindepth 1 -maxdepth 1 -type f -print0)
    chmod_all_files_executable "$LOCAL_BIN"
    ok "~/.local/bin updated and scripts made executable"
  else
    warn "No local/bin directory found in lookandfeel repo"
  fi

  if [[ -d "$repo/local/share" ]]; then
    say "Deploying ~/.local/share content"
    copy_dir_without_delete "$repo/local/share" "$LOCAL_SHARE"
    ok "~/.local/share updated"
  else
    warn "No local/share directory found in lookandfeel repo"
  fi

  bash_profile="$HOME/.bash_profile"
  profile_line='export PATH="$HOME/.local/bin:$PATH"'
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] ensure PATH line exists in $bash_profile"
  else
    touch "$bash_profile"
    if ! grep -qxF "$profile_line" "$bash_profile"; then
      printf '%s\n' "$profile_line" >> "$bash_profile"
      ok "Added ~/.local/bin to PATH in ~/.bash_profile"
    else
      info "~/.local/bin already present in ~/.bash_profile"
    fi
  fi
}

# ---------------------------- STARTX / SESSION -------------------------------

build_xinitrc_content() {
  cat <<'EOF'
#!/usr/bin/env bash
# Managed by dwm-setup-arch-cachy.sh

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm

[[ -r "$HOME/.profile" ]] && . "$HOME/.profile"
[[ -r "$HOME/.bash_profile" ]] && . "$HOME/.bash_profile"
[[ -r "$HOME/.bashrc" ]] && . "$HOME/.bashrc"

if command -v xrdb >/dev/null 2>&1 && [[ -r "$HOME/.Xresources" ]]; then
  xrdb -merge "$HOME/.Xresources"
fi

for f in "$HOME/.config/xinitrc.d/"*.sh; do
  [[ -r "$f" ]] && . "$f"
done

exec dwm
EOF
}

build_session_wrapper_content() {
  cat <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm

[[ -r "\$HOME/.profile" ]] && . "\$HOME/.profile"
[[ -r "\$HOME/.bash_profile" ]] && . "\$HOME/.bash_profile"
[[ -r "\$HOME/.bashrc" ]] && . "\$HOME/.bashrc"

if command -v xrdb >/dev/null 2>&1 && [[ -r "\$HOME/.Xresources" ]]; then
  xrdb -merge "\$HOME/.Xresources"
fi

if [[ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v dbus-run-session >/dev/null 2>&1 && [[ "\${1:-}" != "--dbus-started" ]]; then
  exec dbus-run-session "\$0" --dbus-started "\$@"
fi

[[ "\${1:-}" == "--dbus-started" ]] && shift || true

for f in "\$HOME/.config/xinitrc.d/"*.sh; do
  [[ -r "\$f" ]] && . "\$f"
done

exec dwm
EOF
}

build_session_desktop_content() {
  cat <<EOF
[Desktop Entry]
Name=dwm
Comment=Dynamic window manager
Exec=$SESSION_WRAPPER
TryExec=dwm
Type=Application
DesktopNames=dwm
EOF
}

write_user_hook_if_missing() {
  local path="$1" content="$2"
  if [[ -e "$path" ]]; then
    info "Hook already exists, keeping your version: $path"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] would create hook $path"
    return 0
  fi
  printf '%s\n' "$content" > "$path"
  chmod +x "$path"
  ok "Created hook: $path"
}

phase_startx_and_hooks() {
  step "Preparing startx files and modular xinit hooks"

  ensure_dir "$XINITRC_DIR" "$DWM_CONFIG_DIR"

  append_managed_block \
    "$XINITRC_FILE" \
    "# >>> NIRUCON DWM STARTX BLOCK >>>" \
    "# <<< NIRUCON DWM STARTX BLOCK <<<" \
    "$(build_xinitrc_content)"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    chmod +x "$XINITRC_FILE" 2>/dev/null || true
  fi
  ok "Prepared $XINITRC_FILE"

  write_user_hook_if_missing "$XINITRC_DIR/10-env.sh" '#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm
command -v setxkbmap >/dev/null 2>&1 && setxkbmap se
command -v xsetroot >/dev/null 2>&1 && xsetroot -solid "#111111"
'

  write_user_hook_if_missing "$XINITRC_DIR/20-lookandfeel.sh" '#!/usr/bin/env bash
command -v dunst >/dev/null 2>&1 && ! pgrep -x dunst >/dev/null 2>&1 && dunst &
if command -v picom >/dev/null 2>&1 && ! pgrep -x picom >/dev/null 2>&1; then
  if [[ -f "$HOME/.config/picom/picom.conf" ]]; then
    picom --config "$HOME/.config/picom/picom.conf" --daemon 2>/dev/null || true
  else
    picom --daemon 2>/dev/null || true
  fi
fi
command -v blueman-applet >/dev/null 2>&1 && ! pgrep -x blueman-applet >/dev/null 2>&1 && blueman-applet &
command -v udiskie >/dev/null 2>&1 && ! pgrep -x udiskie >/dev/null 2>&1 && udiskie --tray &
command -v nextcloud >/dev/null 2>&1 && ! pgrep -x nextcloud >/dev/null 2>&1 && nextcloud --background &
'

  write_user_hook_if_missing "$XINITRC_DIR/30-wallpaper.sh" '#!/usr/bin/env bash
if [[ -x "$HOME/.local/bin/wallrotate.sh" ]]; then
  "$HOME/.local/bin/wallrotate.sh" &
elif [[ -x "$HOME/.local/bin/wallpaperchange.sh" ]]; then
  "$HOME/.local/bin/wallpaperchange.sh" &
elif command -v feh >/dev/null 2>&1 && [[ -d "$HOME/Wallpapers" ]]; then
  feh --randomize --bg-fill "$HOME/Wallpapers" &
fi
'

  write_user_hook_if_missing "$XINITRC_DIR/40-statusbar.sh" '#!/usr/bin/env bash
if [[ -x "$HOME/.local/bin/dwm-status.sh" ]]; then
  "$HOME/.local/bin/dwm-status.sh" &
elif command -v slstatus >/dev/null 2>&1 && ! pgrep -x slstatus >/dev/null 2>&1; then
  slstatus &
fi
'

  write_user_hook_if_missing "$XINITRC_DIR/50-lock.sh" '#!/usr/bin/env bash
command -v xautolock >/dev/null 2>&1 && command -v slock >/dev/null 2>&1 && ! pgrep -x xautolock >/dev/null 2>&1 && xautolock -time 10 -locker slock &
'

  write_user_hook_if_missing "$XINITRC_DIR/90-local.sh" '#!/usr/bin/env bash
# Add your own per-machine startup commands here.
# Examples:
# nm-applet &
# syncthingtray &
# pasystray &
'

  if [[ ! -e "$DWM_CONFIG_DIR/autostart-local.sh" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      say "[dry-run] would create $DWM_CONFIG_DIR/autostart-local.sh"
    else
      cat > "$DWM_CONFIG_DIR/autostart-local.sh" <<'EOF'
#!/usr/bin/env bash
# Optional extra startup commands for your dwm session.
EOF
      chmod +x "$DWM_CONFIG_DIR/autostart-local.sh"
      ok "Created $DWM_CONFIG_DIR/autostart-local.sh"
    fi
  fi
}

phase_session() {
  [[ "$SKIP_SESSION" -eq 0 ]] || { warn "Skipping session/startx setup"; return 0; }

  phase_startx_and_hooks

  if [[ "$EFFECTIVE_SESSION_MODE" != "sddm" ]]; then
    info "Session mode is $EFFECTIVE_SESSION_MODE, so no display-manager Xsession files are required"
    return 0
  fi

  step "Creating display-manager-compatible dwm session"
  install_text_via_sudo 755 "$SESSION_WRAPPER" "$(build_session_wrapper_content)"
  install_text_via_sudo 644 "$SESSION_DESKTOP" "$(build_session_desktop_content)"
  ok "Session wrapper created: $SESSION_WRAPPER"
  ok "Desktop session file created: $SESSION_DESKTOP"
}

# ------------------------------- VERIFY --------------------------------------

phase_verify() {
  local failures=0 warnings=0 comp

  chk_cmd() {
    local cmd="$1" label="${2:-$1}"
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "$label found at $(command -v "$cmd")"
    else
      fail "$label not found"
      ((failures++)) || true
    fi
  }

  chk_file() {
    local path="$1" label="${2:-$1}"
    if [[ -f "$path" ]]; then
      ok "$label exists"
    else
      fail "$label missing"
      ((failures++)) || true
    fi
  }

  chk_dir() {
    local path="$1" label="${2:-$1}"
    if [[ -d "$path" ]]; then
      ok "$label exists"
    else
      fail "$label missing"
      ((failures++)) || true
    fi
  }

  chk_exec_file() {
    local path="$1" label="${2:-$1}"
    if [[ -x "$path" ]]; then
      ok "$label is executable"
    else
      fail "$label missing or not executable"
      ((failures++)) || true
    fi
  }

  chk_readable_file() {
    local path="$1" label="${2:-$1}"
    if [[ -r "$path" && -f "$path" ]]; then
      ok "$label exists and is readable"
    else
      fail "$label missing or not readable"
      ((failures++)) || true
    fi
  }

  chk_pkg() {
    local pkg="$1"
    if pacman -Q "$pkg" >/dev/null 2>&1; then
      ok "Package installed: $pkg"
    else
      warn "Package missing: $pkg"
      ((warnings++)) || true
    fi
  }

  chk_file_or_warn() {
    local path="$1" label="$2"
    if [[ -f "$path" ]]; then
      ok "$label exists"
    else
      warn "$label missing"
      ((warnings++)) || true
    fi
  }

  chk_exec_or_warn() {
    local path="$1" label="$2"
    if [[ -x "$path" ]]; then
      ok "$label is executable"
    else
      warn "$label missing or not executable"
      ((warnings++)) || true
    fi
  }

  chk_readable_or_warn() {
    local path="$1" label="$2"
    if [[ -r "$path" && -f "$path" ]]; then
      ok "$label exists and is readable"
    else
      warn "$label missing or not readable"
      ((warnings++)) || true
    fi
  }

  printf "\n${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"
  printf "${BOLD}  Verification${NC}\n"
  printf "${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"

  info "Distro profile: $PROFILE ($DISTRO_PRETTY)"
  info "Login manager detected: $LOGIN_MANAGER"
  info "Requested session mode: $SESSION_MODE"
  info "Effective session mode: $EFFECTIVE_SESSION_MODE"

  echo
  info "Commands"
  chk_cmd dwm
  chk_cmd dmenu
  chk_cmd st
  chk_cmd slock
  chk_cmd git
  chk_cmd picom
  chk_cmd rofi
  chk_cmd dunst
  chk_cmd alacritty

  echo
  info "Source trees and user directories"
  chk_dir "$SUCKLESS_DIR" "Suckless source root"
  for comp in "${SUCKLESS_COMPONENTS[@]}"; do
    chk_dir "$SUCKLESS_DIR/$comp" "Suckless component: $comp"
  done
  chk_dir "$LOCAL_BIN" "~/.local/bin"
  chk_dir "$XDG_CONFIG_TARGET" "~/.config"
  chk_dir "$XINITRC_DIR" "~/.config/xinitrc.d"

  echo
  info "startx files and hooks"
  chk_readable_file "$XINITRC_FILE" "~/.xinitrc"
  chk_readable_or_warn "$XINITRC_DIR/10-env.sh" "10-env.sh"
  chk_readable_or_warn "$XINITRC_DIR/20-lookandfeel.sh" "20-lookandfeel.sh"
  chk_readable_or_warn "$XINITRC_DIR/30-wallpaper.sh" "30-wallpaper.sh"
  chk_readable_or_warn "$XINITRC_DIR/40-statusbar.sh" "40-statusbar.sh"
  chk_readable_or_warn "$XINITRC_DIR/50-lock.sh" "50-lock.sh"
  chk_readable_or_warn "$XINITRC_DIR/90-local.sh" "90-local.sh"

  echo
  info "Display-manager session files"
  if [[ "$EFFECTIVE_SESSION_MODE" == "sddm" ]]; then
    chk_file "$SESSION_DESKTOP" "X session desktop file"
    chk_exec_file "$SESSION_WRAPPER" "Session wrapper"
  else
    chk_file_or_warn "$SESSION_DESKTOP" "X session desktop file"
    chk_exec_or_warn "$SESSION_WRAPPER" "Session wrapper"
  fi

  echo
  info "Lookandfeel helper scripts"
  [[ -x "$LOCAL_BIN/dwm-status.sh" ]] && ok "dwm-status.sh executable" || { warn "dwm-status.sh not found or not executable"; ((warnings++)) || true; }
  [[ -x "$LOCAL_BIN/wallrotate.sh" ]] && ok "wallrotate.sh executable" || { warn "wallrotate.sh not found or not executable"; ((warnings++)) || true; }

  echo
  info "Selected packages"
  chk_pkg xorg-server
  chk_pkg xorg-xinit
  chk_pkg networkmanager
  chk_pkg picom
  chk_pkg rofi
  chk_pkg dunst

  echo
  printf "${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"
  if (( failures == 0 )); then
    if (( warnings == 0 )); then
      ok "Verification passed with no issues"
    else
      warn "Verification passed with $warnings warning(s)"
    fi
  else
    fail "Verification failed with $failures error(s) and $warnings warning(s)"
    return 1
  fi
  printf "${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"
}

# ------------------------------ PREFLIGHT ------------------------------------

preflight() {
  need_cmd bash
  need_cmd git
  need_cmd sudo
  need_cmd pacman
  need_cmd find

  [[ "$DO_VERIFY_ONLY" -eq 1 || "$SKIP_SUCKLESS" -eq 1 ]] || need_cmd_unless_dry_run make
  [[ "$DO_VERIFY_ONLY" -eq 1 || "$SKIP_LOOKANDFEEL" -eq 1 ]] || need_cmd_unless_dry_run rsync

  read_os_release
  probe_login_manager
  derive_effective_session_mode

  info "Detected distro: $DISTRO_PRETTY"
  info "Profile: $PROFILE"
  info "Detected login manager: $LOGIN_MANAGER"
  info "Requested session mode: $SESSION_MODE"
  info "Effective session mode: $EFFECTIVE_SESSION_MODE"

  if [[ "$PROFILE" == "cachyos" ]]; then
    info "CachyOS detected — the script will focus on adding your dwm setup without broad system changes."
  else
    info "Vanilla Arch detected — the script will install the same focused dwm requirements here as well."
  fi
}

print_banner() {
  printf "\n${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"
  printf "${BOLD}  NIRUCON dwm setup for Arch Linux / CachyOS${NC}\n"
  printf "${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"
  printf "  Suckless source dir : %s\n" "$SUCKLESS_DIR"
  printf "  Lookandfeel cache   : %s\n" "$LOOKANDFEEL_DIR"
  printf "  Install prefix      : %s\n" "$INSTALL_PREFIX"
  printf "  Session mode        : %s (effective: %s)\n" "$SESSION_MODE" "$EFFECTIVE_SESSION_MODE"
  printf "  Dry run             : %s\n" "$( [[ $DRY_RUN -eq 1 ]] && echo yes || echo no )"
  printf "\n"
  printf "  This script will:\n"
  printf "    1. Detect distro profile and session mode\n"
  printf "    2. Install needed packages\n"
  printf "    3. Sync your repos\n"
  printf "    4. Build and install dwm, dmenu, st, slock\n"
  printf "    5. Copy lookandfeel files into ~/.config, ~/.local, and ~\n"
  printf "       while protecting shell dotfiles like .bashrc\n"
  printf "    6. Prepare startx and modular xinit hooks\n"
  printf "    7. Create display-manager files when needed\n"
  printf "    8. Verify the result after a real install\n\n"
  printf "  To add more apps later, edit:\n"
  printf "    - PACMAN_OPTIONAL_APPS\n"
  printf "    - PARU_APPS\n\n"
}

main() {
  preflight

  if [[ "$DO_VERIFY_ONLY" -eq 1 ]]; then
    phase_verify
    return $?
  fi

  print_banner

  phase_packages
  phase_suckless
  phase_lookandfeel
  phase_session

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf "\n${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"
    printf "${BOLD}  Dry-run summary${NC}\n"
    printf "${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"
    info "Dry-run completed. No files were created and no packages were installed."
    info "Run the script without --dry-run to apply changes, then use --verify afterwards if you want a post-install check."
  else
    phase_verify
  fi

  print_install_summary

  printf "\n${GRN}Done.${NC}\n"
  if [[ "$EFFECTIVE_SESSION_MODE" == "sddm" ]]; then
    printf "Choose ${BOLD}dwm${NC} from your login manager session menu at the next login.\n"
  else
    printf "Start dwm with ${BOLD}startx${NC} from a TTY, or rerun with ${BOLD}--session-mode sddm${NC} on a machine where you want a display-manager session.\n"
  fi
}

main "$@"
