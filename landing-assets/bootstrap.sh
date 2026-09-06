#!/bin/bash
# Sabr SI — Download & Install (hardened)
# Usage: curl -sL http://2.25.174.126:8500/landing-assets/bootstrap.sh | bash
#
# Does ALL non-interactive work: download brain, extract, install system deps,
# create venv, install python deps, VERIFY imports. Then hands off to ./setup.sh.
#
# NOTE: intentionally NO `set -e`. We handle errors explicitly and report the
# REAL reason on failure instead of dying silently mid-pipe.

G='\033[38;5;39m'; C='\033[38;5;45m'; Y='\033[0;33m'; R='\033[0;31m'; P='\033[38;5;213m'; N='\033[0m'
say(){ echo -e "$@"; }
# ROLLBACK PAST THE SWAP POINT.
# The staging design (below) correctly restores the previous install if the
# extraction or the swap itself fails. But everything AFTER the swap — venv
# creation, the core pip install, the import-verify gate — just printed an
# error and exited, leaving the customer with a half-built tree at
# ~/leon-brain while their real, working install sat abandoned under a
# dot-prefixed directory they were never told to look for. A reinstall to fix
# a small problem could therefore cost them the working SI, which is the exact
# outcome the staging design exists to prevent. die() now undoes the swap.
ROLLBACK_ARMED=""
BACKUP_DIR=""
INSTALL_DIR_FOR_ROLLBACK=""
disarm_rollback(){ ROLLBACK_ARMED=""; }
restore_previous_install(){
  [ "$ROLLBACK_ARMED" = "1" ] || return 0
  [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] || return 0
  local failed="${INSTALL_DIR_FOR_ROLLBACK}.failed.$$"
  say ""
  say "${Y}Putting your previous SI back...${N}"
  # Keep the broken tree rather than deleting it — it is the only evidence of
  # what went wrong, and deleting things on a failure path is how installers
  # earn their reputation.
  if [ -d "$INSTALL_DIR_FOR_ROLLBACK" ] && ! mv "$INSTALL_DIR_FOR_ROLLBACK" "$failed" 2>/dev/null; then
    say "${R}[!!]${N} Could not move the failed install aside; your previous one is safe at:"
    say "     $BACKUP_DIR"
    return 0
  fi
  if mv "$BACKUP_DIR" "$INSTALL_DIR_FOR_ROLLBACK" 2>/dev/null; then
    ROLLBACK_ARMED=""
    say "${G}[OK]${N} Your previous SI has been restored, with its memories intact."
    say "     Nothing you had was lost. The failed attempt is kept at $failed"
  else
    say "${R}[!!]${N} Automatic restore did not work. Your previous SI is intact here:"
    say "     $BACKUP_DIR"
    say "     Rename that directory to $INSTALL_DIR_FOR_ROLLBACK to get it back."
  fi
}
die(){ spin_stop 2>/dev/null; say "${R}[FAILED]${N} $1"; [ -n "$2" ] && { say "${Y}--- details ---${N}"; echo "$2" | tail -12; }; restore_previous_install; exit 1; }

# Package-manager detection for Linux. Every dependency step below used to
# hardcode apt-get and simply do nothing — no error, no warning, just a
# silent no-op — on any distro that doesn't have it (Fedora/RHEL/CentOS via
# dnf or yum, Arch/Manjaro via pacman, openSUSE via zypper). That silence is
# the real defect: the customer gets no packages and no explanation, then
# hits a confusing failure several steps later (venv creation, or a pip
# build against a missing header) with nothing pointing back at the cause.
PKG_MGR=""
detect_pkg_mgr(){
  if   command -v apt-get &>/dev/null; then PKG_MGR="apt"
  elif command -v dnf     &>/dev/null; then PKG_MGR="dnf"
  elif command -v yum     &>/dev/null; then PKG_MGR="yum"
  elif command -v pacman  &>/dev/null; then PKG_MGR="pacman"
  elif command -v zypper  &>/dev/null; then PKG_MGR="zypper"
  else PKG_MGR=""
  fi
}
[ "$(uname)" = "Linux" ] && detect_pkg_mgr

# Pink bouncing progress bar that runs while a slow step works
TTY=0; [ -t 1 ] && TTY=1
SPIN_PID=""
spin_start(){
  [ "$TTY" != 1 ] && { say "$1"; return; }
  ( w=24; pos=0; dir=1
    while :; do
      bar=""
      for ((i=0;i<w;i++)); do [ $i -eq $pos ] && bar="${bar}█" || bar="${bar}·"; done
      printf "\r   ${P}[%b]${N} %s" "$bar" "$1"
      pos=$((pos+dir)); [ $pos -ge $((w-1)) ] && dir=-1; [ $pos -le 0 ] && dir=1
      sleep 0.05
    done ) & SPIN_PID=$!
}
spin_stop(){
  [ -n "$SPIN_PID" ] && { kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null; }
  SPIN_PID=""; [ "$TTY" = 1 ] && printf "\r\033[K"
}

# Portable timeout wrapper. GNU coreutils' `timeout` does not exist on a
# stock Mac (Homebrew's version is `gtimeout`, and a fresh Mac has no
# Homebrew yet — that's the machine this function exists for), so this backs
# a deadline with a plain background watchdog instead: run CMD, race a
# `sleep $secs` against it, and if the sleep wins, kill CMD (and its direct
# children — Homebrew's installer forks curl/tar, and a bare `kill` on the
# parent alone leaves those running with nothing left to report to).
# Homebrew already bit us once by hanging silently mid-install with only a
# spinner on screen; every blocking Homebrew call below is wrapped in this
# rather than trusting it to finish.
# --- private per-run log directory -------------------------------------
# These logs used to be hardcoded as $LEON_LOGDIR/pip.log, $LEON_LOGDIR/venv.log,
# etc. Predictable, unprefixed paths in a world-writable sticky directory
# are two bugs at once:
#   1. The SECOND account on a machine cannot install. The first run's files
#      are owned by the first user, and on any kernel with
#      fs.protected_regular=2 (default on modern distros) the redirect is
#      refused with "Permission denied" — even for root. The install then
#      dies reporting "pip install failed", which is not what happened, so
#      the owner debugs the wrong thing.
#   2. Anyone on the box can pre-place a symlink at that name and have the
#      installer write through it as whoever is installing.
# Both disappear by writing into a private directory made fresh per run.
LEON_LOGDIR="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/.sabr-logs-$$")"
mkdir -p "$LEON_LOGDIR" 2>/dev/null || true
chmod 700 "$LEON_LOGDIR" 2>/dev/null || true

run_timeout(){
  local secs="$1"; shift
  # A killed multi-step script (Homebrew's install.sh is one) can still run
  # a few more lines after its child dies and exit "cleanly" before our
  # direct signal reaches it — racing the exit code. A flag file the
  # watchdog writes at the moment it actually intervenes removes the race:
  # the return value is 124 (the same convention GNU `timeout` uses)
  # whenever we killed it, full stop, whatever the command's own exit code
  # happened to be.
  local flag; flag="$(mktemp 2>/dev/null || echo "/tmp/.sabr_timeout_flag_$$")"
  rm -f "$flag"
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      : > "$flag" 2>/dev/null
      pkill -TERM -P "$cmd_pid" 2>/dev/null
      kill -TERM "$cmd_pid" 2>/dev/null
      sleep 2
      pkill -KILL -P "$cmd_pid" 2>/dev/null
      kill -KILL "$cmd_pid" 2>/dev/null
    fi
  ) & local watchdog_pid=$!
  wait "$cmd_pid" 2>/dev/null; local rc=$?
  kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null
  [ -e "$flag" ] && rc=124
  rm -f "$flag"
  return $rc
}

# ── Branded intro (animated only on a real terminal) ──
TTY=0; [ -t 1 ] && TTY=1
banner(){
  local logo=(
"   ███████╗ █████╗ ██████╗ ██████╗ "
"   ██╔════╝██╔══██╗██╔══██╗██╔══██╗"
"   ███████╗███████║██████╔╝██████╔╝"
"   ╚════██║██╔══██║██╔══██╗██╔══██╗"
"   ███████║██║  ██║██████╔╝██║  ██║"
"   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝"
  )
  echo ""
  for line in "${logo[@]}"; do
    say "${C}${line}${N}"; [ "$TTY" = 1 ] && sleep 0.06
  done
  echo ""
  local tag="   S Y N T H E T I C   I N T E L L I G E N C E   P L A T F O R M"
  if [ "$TTY" = 1 ]; then
    printf "\033[2m"
    for ((i=0;i<${#tag};i++)); do printf "%s" "${tag:$i:1}"; sleep 0.012; done
    printf "\033[0m\n"
  else
    say "\033[2m${tag}\033[0m"
  fi
  # The holdco name here is VENDOR BRANDING on the installer banner, the same
  # class as "Dean Sabr" in LICENSE — a customer is supposed to see who they
  # bought from. It is not a project the SI thinks it owns. The marker must
  # sit on the offending line itself; gate 11 filters line by line.
  say "\033[2m   a Sabr company · 47 Industries\033[0m"  # owner-string-ok
  echo ""
}
banner

OS="$(uname)"
ARCH="$(uname -m)"

# ── Release pin ────────────────────────────────────────────────
# The digest of the release this script installs, pinned HERE and nowhere
# else. This script reaches the customer over HTTPS with its own HTTPS
# sidecar, so it is the trust anchor; a digest fetched from beside the
# tarball would only prove the payload arrived intact from whoever sent
# it, which is not the same as proving we sent it. Written by
# build_release.sh — never edit by hand, and never fetch it at runtime.
EXPECTED_RELEASE_SHA256="cad8a21d3e93ad8f521a8599629daece98cf3142c4ecdc655c67f432a2f63bfb"

# -- macOS bootstrap (runs FIRST, before we need Python) --
# A fresh Mac has no compiler, no Homebrew, and often no real python3. This
# block is self-healing and arch-aware: it detects Apple Silicon vs Intel on
# its own (uname -m), so the user never has to know or say which chip it is.
brew_prefix(){
  if [ "$ARCH" = "arm64" ]; then echo "/opt/homebrew"; else echo "/usr/local"; fi
}
ensure_brew_on_path(){
  local bp; bp="$(brew_prefix)"
  [ -x "$bp/bin/brew" ] && eval "$("$bp/bin/brew" shellenv)" 2>/dev/null
  command -v brew &>/dev/null
}
if [ "$OS" = "Darwin" ]; then
  MACH_TYPE="Intel"
  [ "$ARCH" = "arm64" ] && MACH_TYPE="Apple Silicon (arm64)" || MACH_TYPE="Intel (x86_64)"
  say "${C}Detected macOS on $MACH_TYPE -- configuring automatically.${N}"

  # Check for terminal access EARLY. macOS interactive steps need a real terminal.
  if ! [ -e /dev/tty ] || ! ( : </dev/tty ) 2>/dev/null; then
    die "No interactive terminal available." \
        "This installer must run in a real Terminal window on your Mac (not piped). Run:
    curl -sL https://sabr-technologies-production.up.railway.app/landing-assets/bootstrap.sh | bash
directly in Terminal.app, not through a proxy or script runner."
  fi

  # 1) Xcode Command Line Tools -- trigger install then WAIT (no re-run).
  if ! xcode-select -p &>/dev/null; then
    say "Installing Xcode Command Line Tools..."
    say "${Y}A popup will appear on your Mac. Click Install, then wait for it to finish.${N}"
    say "${Y}This can take several minutes.${N}"
    xcode-select --install </dev/tty >/dev/null 2>&1 || true
    spin_start "Waiting for Xcode tools to finish installing..."
    for i in $(seq 1 240); do
      xcode-select -p &>/dev/null && break
      sleep 5
    done
    spin_stop
    if ! xcode-select -p &>/dev/null; then
      die "Xcode Command Line Tools did not finish installing (timeout after 20 minutes)." \
          "Either: the install was cancelled, or your Mac is very slow.
Try again: xcode-select --install
Click Install when prompted, wait for it to finish, then re-run this installer."
    fi
  fi
  say "${G}[OK]${N} Xcode Command Line Tools"

  # 2) Homebrew -- auto-install if missing, load onto PATH for THIS shell.
  #    Homebrew's installer needs working sudo. Piped through curl|bash it runs
  #    non-interactively and will NOT prompt, so it dies with "Need sudo access".
  #    Fix: prime the sudo credential ONCE against the real terminal, keep it
  #    warm, then let the installer run unattended.
  if ! ensure_brew_on_path; then
    say ""
    say "${Y}Homebrew needs your Mac login password once.${N}"
    say "${Y}Type it at the prompt below (it stays hidden as you type) and press Return.${N}"
    if ! sudo -v </dev/tty >/dev/null 2>&1; then
      die "Could not get admin (sudo) access." \
          "This Mac user must be an Administrator. Log in as an admin user, or in System Settings > Users & Groups make this account an Administrator, then re-run the installer."
    fi
    # keep the sudo timestamp fresh while Homebrew installs.
    # BOUNDED: 60 iterations x 45s = 45 min hard ceiling, so this can never
    # become an immortal background loop if the install below wedges.
    ( for _k in $(seq 1 60); do sudo -n true 2>/dev/null; sleep 45; done ) &
    SUDO_KEEP=$!

    # Fetch the Homebrew installer to disk FIRST, with real timeouts, so a
    # stalled network fails loudly instead of hanging on a static line forever.
    #   --connect-timeout 20 : bound the handshake
    #   --max-time 300       : bound the whole transfer (script is small; 5 min is generous)
    #   --retry 2            : survive a transient blip without user action
    spin_start "Downloading Homebrew installer..."
    if ! curl -fsSL --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 3 \
         https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
         -o $LEON_LOGDIR/brew_install.sh 2>$LEON_LOGDIR/brew_dl.log; then
      spin_stop
      [ -n "$SUDO_KEEP" ] && { kill "$SUDO_KEEP" 2>/dev/null; SUDO_KEEP=""; }
      die "Could not download the Homebrew installer." \
          "Your internet connection timed out or is blocking raw.githubusercontent.com. Check your connection (or a VPN/firewall) and re-run the installer. $(tail -5 $LEON_LOGDIR/brew_dl.log 2>/dev/null)"
    fi
    spin_stop
    [ -s $LEON_LOGDIR/brew_install.sh ] || {
      [ -n "$SUDO_KEEP" ] && { kill "$SUDO_KEEP" 2>/dev/null; SUDO_KEEP=""; }
      die "The Homebrew installer downloaded empty." "Re-run the installer; if it keeps happening your network is intercepting the download."
    }

    # Spinner so the customer always sees motion, never a frozen static line.
    # 10-minute hard ceiling via run_timeout: this step hung indefinitely once
    # before with nothing but the spinner on screen to show for it.
    spin_start "Installing Homebrew (this can take a few minutes)..."
    run_timeout 600 env NONINTERACTIVE=1 /bin/bash $LEON_LOGDIR/brew_install.sh \
      </dev/null >$LEON_LOGDIR/brew.log 2>&1
    BREW_RC=$?
    spin_stop
    [ -n "$SUDO_KEEP" ] && { kill "$SUDO_KEEP" 2>/dev/null; SUDO_KEEP=""; }

    if [ $BREW_RC -eq 124 ]; then
      die "Homebrew install timed out after 10 minutes — it stalled instead of finishing." \
          "This is usually a slow/blocked network partway through the install, or an
installer prompt with nothing to answer it. Re-run on a faster or more open
connection. $(tail -20 $LEON_LOGDIR/brew.log 2>/dev/null)"
    fi
    if [ $BREW_RC -ne 0 ]; then
      die "Homebrew install failed." "$(tail -20 $LEON_LOGDIR/brew.log 2>/dev/null)"
    fi

    # Force brew path setup in THIS shell so we can verify it immediately
    ensure_brew_on_path || die "Homebrew installed but not on PATH." "Expected at $(brew_prefix)/bin/brew"

    # Verify Homebrew actually works
    if ! brew --version >/dev/null 2>&1; then
      die "Homebrew installed but not executable." "Try running: eval \$(/opt/homebrew/bin/brew shellenv) && brew --version"
    fi
  fi
  say "${G}[OK]${N} Homebrew (${ARCH} at $(brew_prefix))"

  # 3) Python 3 -- brew-install if the Mac has none that MEETS THE FLOOR.
  #
  # P0 FIX 2026-08-10 — this dead-ended every stock Mac.
  # The old condition was `! command -v python3 || ! python3 -c 'import sys'`,
  # i.e. "is there a python3 at all". Stock macOS 13/14/15 plus the Xcode
  # Command Line Tools we install ~100 lines above ships /usr/bin/python3 =
  # 3.9.6. It exists and it imports, so this whole block was SKIPPED. Then the
  # candidate scan below found nothing at or above the 3.11 floor, the
  # auto-install remediation is gated to Linux, and the script died telling the
  # customer to go run `brew install python@3.12` by hand — on a machine where
  # it had ALREADY installed Homebrew and could have just done it. Handing
  # someone homework one command short of the finish line.
  #
  # Test the FLOOR, not mere existence. Written inline rather than calling
  # py_meets_floor() because that helper is not defined until later in the file
  # and moving it risks the Linux path, which currently works.
  _mac_py_ok=""
  for _c in python3.13 python3.12 python3.11 python3; do
    command -v "$_c" &>/dev/null || continue
    "$_c" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3,11) else 1)' &>/dev/null \
      && { _mac_py_ok="$_c"; break; }
  done
  if [ -z "$_mac_py_ok" ]; then
    say "Installing Python 3.12 via Homebrew..."
    spin_start "Installing Python 3.12..."
    # PINNED. `brew install python3` tracks newest and would hand us 3.14 —
    # the exact trap the PY_PREFERRED=(13,12,11) ordering elsewhere exists to
    # avoid, since our wheels are not all built for it yet.
    run_timeout 300 brew install python@3.12 </dev/null >$LEON_LOGDIR/pybrew.log 2>&1
    PYBREW_RC=$?
    spin_stop
    if [ $PYBREW_RC -eq 124 ]; then
      die "Installing Python 3 via Homebrew timed out after 5 minutes." \
          "This is usually a slow or blocked network. Re-run the installer, or
run \`brew install python3\` yourself first. $(tail -20 $LEON_LOGDIR/pybrew.log 2>/dev/null)"
    fi
    if [ $PYBREW_RC -ne 0 ]; then
      die "Homebrew could not install Python 3." "$(tail -20 $LEON_LOGDIR/pybrew.log 2>/dev/null)"
    fi
    # Re-add Homebrew to PATH in case Homebrew added new paths
    ensure_brew_on_path
    # Verify Python can actually be used — AT THE FLOOR.
    # The old check was `python3 -c 'import sys'`, which stock macOS 3.9.6
    # passes. So brew could fail to provide a qualifying interpreter and this
    # gate would still go green, moving the failure hundreds of lines
    # downstream into a confusing venv or wheel error. Same defect shape as
    # the one directly above: verifying presence instead of the property we
    # actually require. `brew install python@3.12` puts python3.12 in the brew
    # prefix, so look for it by name and not just as bare `python3`.
    _mac_py_ok=""
    for _c in python3.12 python3.13 python3.11 python3; do
      command -v "$_c" &>/dev/null || continue
      "$_c" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3,11) else 1)' &>/dev/null \
        && { _mac_py_ok="$_c"; break; }
    done
    if [ -z "$_mac_py_ok" ]; then
      die "Homebrew finished but no Python 3.11+ is on PATH." \
          "Check: $(brew_prefix)/bin/python3.12 --version
If that works, your PATH is missing $(brew_prefix)/bin — run: eval \$($(brew_prefix)/bin/brew shellenv)"
    fi
    say "${G}[OK]${N} Python ($_mac_py_ok)"
  fi
fi

# ── Find Python ────────────────────────────────────────────────────────
# The floor is 3.11 (derived — see the B11 note further down: numpy and scipy
# both set Requires-Python >=3.11).
#
# B12 — PROVEN ON A CLEAN UBUNTU 22.04 CONTAINER, 2026-08-10. The old code
# had two separate defects that combined into a hard dead end on the most
# widely deployed Linux there is:
#
#   1. Discovery only ever tried `python3` and `python`. A box whose default
#      python3 is 3.10 but which ALREADY has python3.11 installed alongside
#      it — extremely common — was declared hopeless while a qualifying
#      interpreter sat on PATH the whole time. False negative, zero reason.
#   2. When the version was too old we printed homework instead of installing,
#      breaking the same "install it, don't assign homework" courtesy the Mac
#      brew path extends. Worse, the homework was WRONG: it said
#      `apt-get install -y python3.13 python3.13-venv`, and 22.04 has no such
#      package. Verified: "E: Unable to locate package python3.13". The
#      customer follows our instructions, the command errors, and they are
#      stuck with no path forward — while python3.11, which satisfies us
#      completely, is one apt-get away in their default repos.
#
# So: scan for a qualifying interpreter newest-first, and if none exists try
# to INSTALL one (newest available wins), then re-scan. Only then give up —
# and give up with advice derived from what this machine actually offers.
PY_FLOOR_MAJOR=3
PY_FLOOR_MINOR=11
PY_CANDIDATES="python3.14 python3.13 python3.12 python3.11 python3 python"

py_meets_floor(){
  command -v "$1" &>/dev/null || return 1
  "$1" -c "import sys; sys.exit(0 if sys.version_info[:2] >= ($PY_FLOOR_MAJOR,$PY_FLOOR_MINOR) else 1)" &>/dev/null
}
find_best_python(){
  local c
  for c in $PY_CANDIDATES; do py_meets_floor "$c" && { echo "$c"; return 0; }; done
  return 1
}
# Newest python actually present, qualifying or not — only used to report an
# honest "you have X, we need Y" if every install attempt fails.
find_any_python(){
  local c
  for c in $PY_CANDIDATES; do command -v "$c" &>/dev/null && { echo "$c"; return 0; }; done
  return 1
}

PY="$(find_best_python || true)"

# ── Auto-install a qualifying Python if none is present ────────────────
if [ -z "$PY" ] && [ "$OS" = "Linux" ] && [ -n "$PKG_MGR" ]; then
  PKG_SUDO=""
  [ "$(id -u)" != "0" ] && command -v sudo &>/dev/null && PKG_SUDO="sudo"
  EXISTING_PY="$(find_any_python || true)"
  if [ -n "$EXISTING_PY" ]; then
    EXISTING_VER=$("$EXISTING_PY" -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
    say "Python $EXISTING_VER is below the ${PY_FLOOR_MAJOR}.${PY_FLOOR_MINOR} floor — installing a newer one via $PKG_MGR..."
  else
    say "Python 3 not found — installing it via $PKG_MGR..."
  fi
  : >$LEON_LOGDIR/pyapt.log
  case "$PKG_MGR" in
    apt)
      PY_APT_OPTS="-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"
      $PKG_SUDO apt-get $PY_APT_OPTS update -qq </dev/null 2>/dev/null
      # Newest first. apt-cache policy is checked before attempting so a
      # missing package is a silent skip, not a wall of scary red errors.
      for v in 3.14 3.13 3.12 3.11; do
        apt-cache policy "python$v" 2>/dev/null | grep -q 'Candidate: [^(]' || continue
        say "  trying python$v..."
        $PKG_SUDO env DEBIAN_FRONTEND=noninteractive apt-get $PY_APT_OPTS install -y \
            "python$v" "python$v-venv" </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
        py_meets_floor "python$v" && break
      done
      # Last resort on older Ubuntu (20.04 ships nothing >= 3.11 at all):
      # deadsnakes. Tolerated failure — no network, no PPA support, fine.
      if ! find_best_python >/dev/null 2>&1 && [ -r /etc/os-release ] && grep -qi ubuntu /etc/os-release; then
        say "  no qualifying python in the default repos — trying the deadsnakes PPA..."
        $PKG_SUDO env DEBIAN_FRONTEND=noninteractive apt-get $PY_APT_OPTS install -y \
            software-properties-common </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
        $PKG_SUDO env DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:deadsnakes/ppa \
            </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
        $PKG_SUDO apt-get $PY_APT_OPTS update -qq </dev/null 2>/dev/null
        for v in 3.13 3.12 3.11; do
          apt-cache policy "python$v" 2>/dev/null | grep -q 'Candidate: [^(]' || continue
          $PKG_SUDO env DEBIAN_FRONTEND=noninteractive apt-get $PY_APT_OPTS install -y \
              "python$v" "python$v-venv" "python$v-distutils" </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
          py_meets_floor "python$v" && break
        done
      fi
      # Ensure pip machinery exists for whichever one we landed on.
      $PKG_SUDO env DEBIAN_FRONTEND=noninteractive apt-get $PY_APT_OPTS install -y \
          python3-pip </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
      ;;
    dnf)
      for v in 3.14 3.13 3.12 3.11; do
        $PKG_SUDO dnf install -y "python$v" </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
        py_meets_floor "python$v" && break
      done
      $PKG_SUDO dnf install -y python3-pip </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
      ;;
    yum)
      for v in 3.12 3.11; do
        $PKG_SUDO yum install -y "python$v" </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
        py_meets_floor "python$v" && break
      done
      $PKG_SUDO yum install -y python3-pip </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
      ;;
    pacman)
      # Arch is rolling — plain `python` is always current.
      $PKG_SUDO pacman -Sy --noconfirm python python-pip </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
      ;;
    zypper)
      for v in 313 312 311; do
        $PKG_SUDO zypper --non-interactive install "python$v" "python$v-devel" </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
        py_meets_floor "python${v:0:1}.${v:1}" && break
      done
      $PKG_SUDO zypper --non-interactive install python3-pip </dev/null >>$LEON_LOGDIR/pyapt.log 2>&1 || true
      ;;
  esac
  PY="$(find_best_python || true)"
fi

# ── Nothing qualifying, and we could not install one ───────────────────
# Advice is DERIVED from this machine, never hardcoded. The previous
# hardcoded "install python3.13" was a dead end on Ubuntu 22.04.
if [ -z "$PY" ]; then
  HAVE_PY="$(find_any_python || true)"
  if [ -n "$HAVE_PY" ]; then
    HAVE_VER=$("$HAVE_PY" -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
    WHAT="Python $HAVE_VER is too old — the SI needs ${PY_FLOOR_MAJOR}.${PY_FLOOR_MINOR} or newer."
  else
    WHAT="Python 3 not found, and the automatic install did not succeed."
  fi
  # Ask the package manager what it can actually give us.
  SUGGEST=""
  case "$PKG_MGR" in
    apt)
      for v in 3.14 3.13 3.12 3.11; do
        if apt-cache policy "python$v" 2>/dev/null | grep -q 'Candidate: [^(]'; then
          SUGGEST="sudo apt-get install -y python$v python$v-venv"; break
        fi
      done
      [ -z "$SUGGEST" ] && SUGGEST="sudo add-apt-repository -y ppa:deadsnakes/ppa && sudo apt-get update && sudo apt-get install -y python3.12 python3.12-venv"
      ;;
    dnf)    SUGGEST="sudo dnf install -y python3.12" ;;
    yum)    SUGGEST="sudo yum install -y python3.12" ;;
    pacman) SUGGEST="sudo pacman -S python python-pip" ;;
    zypper) SUGGEST="sudo zypper install python312" ;;
  esac
  if [ "$OS" = "Darwin" ]; then SUGGEST="brew install python@3.12"; fi
  die "$WHAT" "  numpy and scipy both require Python >= ${PY_FLOOR_MAJOR}.${PY_FLOOR_MINOR}. Installing on anything
  older fails partway through pip with a build error that never names the
  real cause, so we stop here instead.

  On THIS machine, run:
      ${SUGGEST:-install Python 3.12 or newer from https://python.org/downloads/}
  Then re-run this installer.

  Log:   $LEON_LOGDIR/pyapt.log"
fi

PYVER=$("$PY" -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')
say "${G}[OK]${N} Python $PYVER ($PY)"

# ── Disk space preflight ──────────────────────────────────────────────
# The python stack (numpy/scipy/faster-whisper/ctranslate2) needs ~1.5GB.
# On a near-full disk pip dies mid-compile with a cryptic error that looks
# like a code bug. Catch it up front with a clean, honest message instead.
AVAIL_KB=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt 2000000 ]; then
  die "Not enough free disk space (need ~2GB, have $((AVAIL_KB/1024))MB free in $HOME)." \
      "Free up some space, then re-run this installer."
fi

# ── Minimum Python version — B11 ──────────────────────────────────────
# 3.11, and it is derived, not chosen. Requires-Python read from installed
# dist metadata on a working system:
#     numpy  2.4.6   >=3.11   <- binding
#     scipy  1.17.1  >=3.11   <- binding
#     fastapi, uvicorn, requests, aiohttp, Pillow, dotenv, multipart >=3.10
#     anthropic, pydantic, faster-whisper, mss                       >=3.9
# numpy and scipy set the floor. This check previously enforced 3.9, which
# let an install start on 3.9 or 3.10 and then die deep in a pip build with
# an error that never names the cause — the failure this check exists to
# prevent. The source itself does not need 3.11: no match statements and no
# bare PEP-604 unions outside modules with 'from __future__ import
# annotations'. It is a dependency fact, not a syntax fact.
#
# B12: the enforcement AND the remediation now both live in the "Find Python"
# section above, which selects newest-qualifying-first and installs one if
# none exists. $PY cannot reach this line without meeting the floor. What is
# left here is a cheap assertion so that if anyone ever reorders these blocks,
# it fails loudly here instead of dying deep inside a pip build. It must never
# grow hardcoded install advice again — that is exactly what dead-ended
# Ubuntu 22.04 (it told customers to install python3.13, which does not exist
# in 22.04's repos, while python3.11 sat right there).
if ! "$PY" -c "import sys; sys.exit(0 if sys.version_info[:2] >= ($PY_FLOOR_MAJOR,$PY_FLOOR_MINOR) else 1)"; then
  die "Internal: selected interpreter $PY is $PYVER, below the ${PY_FLOOR_MAJOR}.${PY_FLOOR_MINOR} floor." \
      "This is a bug in the installer's Python selection, not a problem with your machine.
  Please send this line to support along with $LEON_LOGDIR/pyapt.log"
fi

# ── Privilege helper (root => no sudo; else sudo only if usable) ──
SUDO=""
if [ "$(id -u)" != "0" ]; then
  if command -v sudo &>/dev/null; then SUDO="sudo"; fi
fi

# ── System deps (any of apt / dnf / yum / pacman / zypper) ──
# Package NAMES differ per distro family even when the underlying library is
# the same one (portaudio19-dev on Debian is portaudio-devel on Fedora and
# just portaudio on Arch), so this is a real per-manager list, not one list
# reused with a different install command. The apt list is battle-tested
# against the 47 OS family in production; the dnf/pacman/zypper lists are
# the correct package names for each distro's own repos but have NOT been
# run against a live Fedora/Arch/openSUSE box from this environment — flag
# that when reporting on this fix, don't claim it as proven the way the apt
# path is.
if [ "$OS" = "Linux" ] && [ -n "$PKG_MGR" ]; then
  say ""
  say "Installing system packages via $PKG_MGR (python3-venv, etc.)..."
  # Retries + timeouts on apt specifically: a stalled mirror otherwise hangs
  # this step forever with zero feedback (observed live — a dead route to
  # archive.ubuntu.com froze the installer mid-download with no error).
  DEPS_OK=1
  case "$PKG_MGR" in
    apt)
      APT_OPTS="-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"
      $SUDO apt-get $APT_OPTS update -qq </dev/null 2>/dev/null
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get $APT_OPTS install -y \
            python3-venv python3-full python3-pip xdotool wmctrl tmux \
            portaudio19-dev libsndfile1 ffmpeg </dev/null >$LEON_LOGDIR/apt.log 2>&1 || DEPS_OK=0
      ;;
    dnf)
      $SUDO dnf install -y python3-pip xdotool wmctrl tmux \
            portaudio-devel libsndfile ffmpeg </dev/null >$LEON_LOGDIR/apt.log 2>&1 || DEPS_OK=0
      ;;
    yum)
      $SUDO yum install -y python3-pip xdotool wmctrl tmux \
            portaudio-devel libsndfile ffmpeg </dev/null >$LEON_LOGDIR/apt.log 2>&1 || DEPS_OK=0
      ;;
    pacman)
      $SUDO pacman -Sy --noconfirm xdotool wmctrl tmux \
            portaudio libsndfile ffmpeg </dev/null >$LEON_LOGDIR/apt.log 2>&1 || DEPS_OK=0
      ;;
    zypper)
      $SUDO zypper --non-interactive install xdotool wmctrl tmux \
            portaudio-devel libsndfile-devel ffmpeg </dev/null >$LEON_LOGDIR/apt.log 2>&1 || DEPS_OK=0
      ;;
  esac
  if [ "$DEPS_OK" = 1 ]; then
    say "${G}[OK]${N} System deps"
  else
    say "${Y}[WARN]${N} $PKG_MGR could not install venv tooling (no sudo password / offline)."
    say "        If venv creation fails below, install these yourself then re-run:"
    case "$PKG_MGR" in
      apt)    say "          sudo apt-get update && sudo apt-get install -y python3-venv python3-full python3-pip" ;;
      dnf)    say "          sudo dnf install -y python3-pip" ;;
      yum)    say "          sudo yum install -y python3-pip" ;;
      pacman) say "          sudo pacman -S python-pip" ;;
      zypper) say "          sudo zypper install python3-pip" ;;
    esac
  fi
elif [ "$OS" = "Linux" ]; then
  say "${Y}[WARN]${N} No known package manager found (apt-get/dnf/yum/pacman/zypper) — skipping system"
  say "        packages (tmux, xdotool, wmctrl, ffmpeg). Install them with your distro's tool if"
  say "        venv creation or voice features fail below."
fi

# -- macOS: audio + tmux deps (Xcode/Homebrew/Python handled above) --
if [ "$OS" = "Darwin" ]; then
  ensure_brew_on_path
  BP="$(brew_prefix)"

  if ! find "$BP" /usr/local -name "portaudio.h" 2>/dev/null | grep -q .; then
    if command -v brew &>/dev/null; then
      say "Installing PortAudio (for voice I/O)..."
      # Best-effort and non-fatal on failure, but a WEDGE here still stalls
      # the whole install (nothing after this line runs until it returns) —
      # so it gets the same 5-minute ceiling as every other brew step.
      spin_start "Installing PortAudio..."
      run_timeout 300 brew install portaudio </dev/null >$LEON_LOGDIR/portaudio.log 2>&1
      PORTAUDIO_RC=$?
      spin_stop
      if [ $PORTAUDIO_RC -eq 0 ]; then
        say "${G}[OK]${N} PortAudio"
      elif [ $PORTAUDIO_RC -eq 124 ]; then
        say "${Y}[WARN]${N} PortAudio install timed out after 5 minutes (optional) -- voice will still work with software synthesis."
      else
        say "${Y}[WARN]${N} PortAudio install failed (optional) -- voice will still work with software synthesis."
      fi
    fi
  else
    say "${G}[OK]${N} PortAudio (already present)"
  fi

  if ! command -v tmux &>/dev/null; then
    if command -v brew &>/dev/null; then
      say "Installing tmux (for background sessions)..."
      spin_start "Installing tmux..."
      run_timeout 300 brew install tmux </dev/null >$LEON_LOGDIR/tmux.log 2>&1
      TMUX_RC=$?
      spin_stop
      if [ $TMUX_RC -eq 0 ]; then
        say "${G}[OK]${N} tmux"
      elif [ $TMUX_RC -eq 124 ]; then
        say "${Y}[WARN]${N} tmux install timed out after 5 minutes (optional) -- use './start.sh' instead of background mode."
      else
        say "${Y}[WARN]${N} tmux install failed (optional) -- use './start.sh' instead of background mode."
      fi
    fi
  else
    say "${G}[OK]${N} tmux (already present)"
  fi

  say ""
  say "${C}macOS setup complete:${N}"
  say "  Architecture: $MACH_TYPE"
  say "  Python: $(python3 --version 2>&1)"
  say "  Homebrew: $(brew --version 2>&1 | head -1)"
  say ""
fi

# ── Download ──
say ""
say "Downloading brain..."
INSTALL_DIR="$HOME/leon-brain"
cd "$HOME" || die "Cannot cd to HOME ($HOME)"
# TLS ONLY. There used to be a third entry here —
# http://2.25.174.126:8500/... — and because the list is tried in order with
# no floor, a network that merely blocked the two TLS hosts would quietly
# downgrade the install to an 80MB mind arriving unencrypted from a bare IP.
# The digest pinned below always made that safe from substitution, but safe
# is not the same as acceptable, and a corporate network that blocks bare-IP
# HTTP outright would have failed the install anyway, at the very last step
# and for a reason no customer could read. So the entry is gone and the loop
# refuses any non-TLS URL: a hard, early, legible failure instead of a
# silent downgrade.
#
# Both remaining mirrors were verified serving the real artifact on
# 2026-08-05, against the local release file:
#   sabrtechnologies.com  80828470 bytes, sha256 fded70ed… — byte-identical
#                         to EXPECTED_RELEASE_SHA256 below
#   railway               gzip, same artifact (the older comment here claimed
#                         Railway 404s for this path; that is no longer true)
DL_URLS=(
  "https://sabrtechnologies.com/landing-assets/leon-brain-release.tar.gz"
  "https://sabr-technologies-production.up.railway.app/landing-assets/leon-brain-release.tar.gz"
)
# A tarball may arrive from any source above; it is trusted only if it
# matches the digest pinned in THIS script. Transport and integrity are two
# separate guarantees and this script now insists on both: TLS says the bytes
# were not read or rewritten in flight, the digest says they are the bytes we
# published. There is deliberately NO degrade path for either — an integrity
# check that can be skipped is not one, and refusing to install is honest
# where installing-while-unable-to-verify is not.
if [ -z "$EXPECTED_RELEASE_SHA256" ]; then
  die "This installer has no release digest pinned, so it cannot verify what it downloads." \
      "That means the installer itself was built wrong or edited. Please re-download it:
    curl -fsSL https://sabrtechnologies.com/landing-assets/bootstrap.sh -o bootstrap.sh
and check with Sabr before running anything."
fi
DL_OK=""
VERIFY_FAILED=""
NON_TLS_SKIPPED=""
for DL_URL in "${DL_URLS[@]}"; do
  # Refused, not demoted to last place. This is the guard that keeps the
  # removed bare-IP entry from creeping back in during a hurried edit: a
  # non-TLS source is never tried, however few sources remain.
  case "$DL_URL" in
    https://*) ;;
    *)
      say "  ${Y}refusing a source that is not HTTPS: ${DL_URL}${N}"
      NON_TLS_SKIPPED="1"
      continue
      ;;
  esac
  # Start each SOURCE from clean bytes. Resuming across sources would splice
  # two different servers' halves together; the digest would catch it, but only
  # after another full download's worth of the customer's time.
  rm -f leon-brain.tar.gz
  for attempt in 1 2 3; do
    # --connect-timeout bounds only the handshake; --max-time bounds the WHOLE
    # transfer, and --speed-limit/--speed-time aborts a connection that is alive
    # but trickling (dead peer, throttled mirror) instead of hanging forever.
    #
    # RESUME on retries. Without -C - every retry restarted ~80MB from zero, so
    # a customer on a genuinely slow or flaky line could burn six full attempts
    # and still never finish — not because the network was blocked, but because
    # all partial progress was thrown away each time. Attempt 1 is always fresh;
    # 2 and 3 continue whatever landed, and the pinned digest still has the
    # final say on the assembled file, so a bad resume cannot install anything.
    RESUME=""
    if [ "$attempt" -gt 1 ] && [ -s leon-brain.tar.gz ]; then
      RESUME="-C -"
      say "  ${D}resuming from $(wc -c < leon-brain.tar.gz) bytes already downloaded${N}"
    fi
    if curl -fsSL --connect-timeout 10 --max-time 900 \
         --speed-limit 1024 --speed-time 60 $RESUME "$DL_URL" -o leon-brain.tar.gz \
       && [ -f leon-brain.tar.gz ] && [ "$(wc -c < leon-brain.tar.gz)" -ge 1000 ]; then
      GOT="$( (sha256sum leon-brain.tar.gz 2>/dev/null || shasum -a 256 leon-brain.tar.gz 2>/dev/null) | awk '{print $1}')"
      if [ -z "$GOT" ]; then
        rm -f leon-brain.tar.gz
        die "This machine has no sha256 tool, so the download cannot be verified." \
            "Install coreutils (Linux: apt install coreutils) or use a Mac/Linux box with shasum, then re-run."
      fi
      if [ "$GOT" = "$EXPECTED_RELEASE_SHA256" ]; then
        say "${G}[OK]${N} Download verified against the pinned release digest."
        DL_OK="1"; break
      fi
      say "  ${Y}digest mismatch from this source — discarding and trying the next...${N}"
      VERIFY_FAILED="1"
      rm -f leon-brain.tar.gz
      break
    fi
    CURL_RC=$?
    # "Download failed" is a dead end for a non-technical owner. curl already
    # knows WHICH layer broke; say so, because the fix is completely different
    # for a DNS failure, a corporate TLS-intercepting proxy, and a hotel
    # captive portal — and all three used to print the same useless sentence.
    case "$CURL_RC" in
      6)  DL_HINT="the name sabrtechnologies.com could not be resolved — this is DNS, not us. On a hotel or cafe network, open a browser first and accept the wifi sign-in page, then re-run." ;;
      7)  DL_HINT="the connection was refused or blocked — a firewall or network policy is likely stopping outbound HTTPS." ;;
      35|51|58|59|60|77|83)
          DL_HINT="the secure connection could not be verified. On a company network this usually means a proxy is inspecting HTTPS traffic; ask IT to allow sabrtechnologies.com or install the company certificate." ;;
      28) DL_HINT="the download timed out or stalled — the connection is alive but too slow to finish." ;;
      *)  DL_HINT="" ;;
    esac
    if [ -n "$DL_HINT" ]; then
      say "  ${Y}attempt $attempt failed: ${DL_HINT}${N}"
    else
      say "  ${Y}source unreachable, attempt $attempt — retrying...${N}"
    fi
    sleep 2
  done
  [ -n "$DL_OK" ] && break
done
if [ -z "$DL_OK" ]; then
  if [ -n "$VERIFY_FAILED" ]; then
    # Tell the two causes apart instead of blaming both on tampering. A copy of
    # this script downloaded before the last release still pins the OLD digest,
    # so a PERFECTLY HEALTHY mirror fails verification and the customer was told
    # to email Dean. Reproduced end to end 2026-08-10: a bootstrap.sh saved
    # minutes earlier dead-ended on "contact dean before retrying" purely
    # because a newer release had shipped in between. The published sidecar
    # settles it — if the mirror advertises a digest different from the one
    # pinned here, this script is simply out of date and re-fetching fixes it.
    # NOTE ON THE TRUST MODEL (see the release-pin block above): this fetch
    # happens only AFTER verification has already failed and nothing will be
    # installed. The sidecar is used purely to word the error correctly; it can
    # never cause bytes to be accepted, so the pin remains the only anchor.
    LIVE_SHA=""
    for u in "${DL_URLS[@]}"; do
      LIVE_SHA=$(curl -fsSL --max-time 20 "$u.sha256" 2>/dev/null \
                 | tr -d '\r' | awk '{print $1}' | head -1)
      [ -n "$LIVE_SHA" ] && break
    done
    if [ -n "$LIVE_SHA" ] && [ "$LIVE_SHA" != "$EXPECTED_RELEASE_SHA256" ]; then
      die "This installer is out of date — a newer release shipped after you downloaded it." \
          "Nothing was installed, and nothing is wrong with your machine or the
download. This copy of the installer pins an older release than the one now
published, so the digest check correctly refused it.

Fetch a fresh installer and run it again:

    curl -fsSL https://sabrtechnologies.com/landing-assets/bootstrap.sh -o bootstrap.sh && bash bootstrap.sh

  this installer expects: $EXPECTED_RELEASE_SHA256
  currently published:    $LIVE_SHA"
    fi
    die "The downloaded brain did not match the digest this installer expects, so nothing was installed." \
        "The published digest agrees with this installer, but the bytes that arrived
do not match either of them — so this is a corrupted or interfered-with
download, not a version mismatch. It will not be run.
Expected: $EXPECTED_RELEASE_SHA256
Please contact dean@sabrtechnologies.com before retrying."
  fi
  if [ -n "$NON_TLS_SKIPPED" ]; then
    die "Download failed: no HTTPS source answered." \
        "One or more sources in this installer are plain HTTP and were refused
rather than used — the brain is not delivered over an unencrypted link.
Tried: ${DL_URLS[*]}
If you are on a network that blocks outbound HTTPS to sabrtechnologies.com,
download the release on another connection, or contact
dean@sabrtechnologies.com."
  fi
  die "Download failed from all sources." "tried: ${DL_URLS[*]}
Both sources are HTTPS and neither answered. Check your connection, or
contact dean@sabrtechnologies.com if this keeps happening."
fi
# ── Stop any previously-installed SI before replacing it ──────────────
# Reinstalling over a still-running brain leaves the old process holding
# port 8000, so the fresh one can't bind and it looks like "nothing happens".
# Kill the old instance + its dashboard tmux session first. Scoped to THIS
# install's venv interpreter so unrelated python processes are never touched.
if [ -d "$INSTALL_DIR" ]; then
  say "Stopping previous SI (if running)..."
  pkill -f "$INSTALL_DIR/.venv/bin/python" 2>/dev/null || true
  tmux kill-session -t leon 2>/dev/null || true
  # NOT a blind `fuser -k 8000/tcp`. That kills whatever holds port 8000 on the
  # owner's machine — their own dev server, someone else's app — and an
  # installer that terminates unrelated software is a defect, not a cleanup.
  # Only kill a listener we can prove is this install's own interpreter.
  if command -v lsof >/dev/null 2>&1; then
    for _pid in $(lsof -t -iTCP:8000 -sTCP:LISTEN 2>/dev/null); do
      _exe=$(readlink -f "/proc/$_pid/exe" 2>/dev/null || true)
      case "$_exe" in
        "$INSTALL_DIR"/*) kill "$_pid" 2>/dev/null || true ;;
      esac
    done
  fi
  sleep 1
fi
# ── B4: VALIDATE THEN SWAP. Never delete-then-hope. ───────────────────
# This used to be `rm -rf leon-brain` followed by `tar xzf`. The delete ran
# AFTER the download but BEFORE extraction, pip, or any verification — so any
# failure past that line left the owner with nothing, and took .env (dashboard
# key, SI name, owner name) and brain_state/ (everything the SI has learned)
# with it. Reinstalling to FIX a problem was the act that destroyed the
# instance, and the second install is exactly when that bites.
#
# Now: extract beside the old one, prove the payload is real, carry the
# identity across, swap, and keep the previous tree until the new one has been
# stood up. Nothing is removed until something better exists.
STAGE_DIR="$HOME/.leon-brain-staging.$$"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" || die "Cannot create staging dir ($STAGE_DIR)"
tar xzf leon-brain.tar.gz -C "$STAGE_DIR" || {
  rm -rf "$STAGE_DIR"
  die "Extraction failed (corrupt tarball?) — your existing install is untouched."
}
# The tarball's top level is leon-brain/. Prove it before trusting it.
if [ ! -d "$STAGE_DIR/leon-brain" ] || [ ! -f "$STAGE_DIR/leon-brain/run.py" ]; then
  rm -rf "$STAGE_DIR"
  die "Extracted tree is not a brain (no run.py) — refusing to replace a working install."
fi

if [ -d "$INSTALL_DIR" ]; then
  # Carry identity and memory forward BEFORE the swap. Losing these is losing
  # the instance: .env holds the dashboard key and the SI's name, brain_state/
  # holds everything it remembers.
  for keep in .env brain_state; do
    if [ -e "$INSTALL_DIR/$keep" ]; then
      cp -a "$INSTALL_DIR/$keep" "$STAGE_DIR/leon-brain/" 2>/dev/null \
        && say "  ${G}kept${N} $keep" \
        || say "  ${Y}[WARN]${N} could not carry $keep forward"
    fi
  done
  # ── Purge legacy owner seeds from the memory we just carried forward ──
  # The carry-forward above is what makes the owner-seed leak permanent:
  # releases before 2026-08-18 wrote his personal facts into every
  # knowledge.db (core_fact_seed / dean_bio_seed / client_seed v1) plus
  # brain_state/core_facts.md, knowledge_store marks those sources durable so
  # they never decay, and this loop hands them to the next install. So a
  # customer reinstalling TO FIX the SI that dreams about things they have
  # never owned was carrying the cause across with them.
  #
  # Runs on the STAGED copy, before the swap: if it goes wrong the original
  # brain_state is still untouched at $INSTALL_DIR and the rollback path
  # below restores it. The module is stdlib-only and gates itself on
  # brain/origin.py (owner_facts.py absent == shipped build == client), which
  # resolves from the staged tree because we cd into it. The si_name check is
  # the second belt: bootstrap only ever knows the SI's name from the .env it
  # just carried over.
  if [ -f "$STAGE_DIR/leon-brain/brain/purge_owner_seeds.py" ] && [ -n "${PY:-}" ]; then
    _SI_NAME_CARRIED="$(grep -E '^LEON_SI_NAME=' "$STAGE_DIR/leon-brain/.env" 2>/dev/null \
                        | tail -1 | cut -d= -f2- | tr -d '"'"'"'[:space:]')"
    if [ "$(printf '%s' "$_SI_NAME_CARRIED" | tr 'A-Z' 'a-z')" != "leon" ]; then
      ( cd "$STAGE_DIR/leon-brain" && "$PY" -m brain.purge_owner_seeds ) 2>/dev/null \
        || say "  ${Y}[WARN]${N} owner-seed purge skipped (non-fatal)"
    fi
  fi
  BACKUP_DIR="$HOME/.leon-brain-previous.$$"
  rm -rf "$BACKUP_DIR"
  mv "$INSTALL_DIR" "$BACKUP_DIR" || {
    rm -rf "$STAGE_DIR"
    die "Could not move the existing install aside — nothing changed."
  }
fi

if ! mv "$STAGE_DIR/leon-brain" "$INSTALL_DIR"; then
  # Swap failed. Put the old one back rather than leaving the user with none.
  [ -n "$BACKUP_DIR" ] && mv "$BACKUP_DIR" "$INSTALL_DIR" 2>/dev/null
  rm -rf "$STAGE_DIR"
  die "Could not install the new tree — the previous install was restored."
fi
rm -rf "$STAGE_DIR"
rm -f leon-brain.tar.gz
# The swap is done. From here on, any die() must undo it.
INSTALL_DIR_FOR_ROLLBACK="$INSTALL_DIR"
[ -n "$BACKUP_DIR" ] && ROLLBACK_ARMED="1"
if [ -n "$BACKUP_DIR" ]; then
  say "${G}[OK]${N} Previous install kept at $BACKUP_DIR"
  say "     Delete it once the new one is confirmed working."
fi
# Stamp WHICH release this is. Nothing in the installed tree recorded it, so
# neither the SI, the owner, nor a support conversation could answer "what
# version are you running?" — which is also why nothing could ever tell that an
# update existed. The digest is already verified at this point, so this is a
# fact, not a claim. auto_update.py reads this file.
{
  echo "release_sha256=$EXPECTED_RELEASE_SHA256"
  echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
} > "$INSTALL_DIR/.sabr-release" 2>/dev/null || true

say "${G}[OK]${N} Installed to ~/leon-brain/"
cd "$INSTALL_DIR" || die "Install dir missing after swap"

# Bind the dashboard to loopback on customer machines (audit SI-SEC-006).
# run.py falls back to 0.0.0.0 — a server assumption; on a laptop that is a
# LAN-exposed dashboard plus a firewall prompt a non-technical owner should
# never see. Only add it when absent so an owner's own setting wins.
if ! grep -qE '^LEON_HOST=' .env 2>/dev/null; then
  echo "LEON_HOST=127.0.0.1" >> .env
fi

# ── Tenant identity ────────────────────────────────────────────
# A buyer's install command carries these as an env prefix:
#   curl -fsSL .../bootstrap.sh | SABR_TENANT_TOKEN=... SABR_LEASE_VERIFY_KEY=... bash
# (a piped bash never sees a ?t= query string — the env prefix is the only
# channel that survives the pipe). The verify key is an Ed25519 PUBLIC key:
# safe in shell history and email by construction. THE LEASE IS NOT AN AUTH
# TOKEN — nothing here authenticates against it; it exists so the SI can
# narrate its own condition offline.
if [ -n "${SABR_TENANT_TOKEN:-}" ]; then
  # Replace, never append: a re-install with a new token must not leave two
  # SABR_TENANT_TOKEN lines whose winner depends on the reader — that coin
  # flip would land during exactly the re-install a confused customer runs
  # when something already went wrong.
  if [ -f .env ]; then
    grep -v -e '^SABR_TENANT_TOKEN=' -e '^SABR_LEASE_VERIFY_KEY=' .env > .env.tmp 2>/dev/null || true
    mv .env.tmp .env
  fi
  {
    echo "SABR_TENANT_TOKEN=${SABR_TENANT_TOKEN}"
    [ -n "${SABR_LEASE_VERIFY_KEY:-}" ] && echo "SABR_LEASE_VERIFY_KEY=${SABR_LEASE_VERIFY_KEY}"
  } >> .env
  chmod 600 .env 2>/dev/null || true
  say "${G}[OK]${N} Install registered to your account."
elif [ "${SABR_PAID_INSTALL:-}" = "1" ]; then
  # A paid command always carries a token; if it's gone, the command was
  # mangled in transit and installing unlinked would give a paying customer
  # a mind that doesn't know it belongs to them. Fatal, with the recovery.
  die "This is a purchased install, but its account token is missing — the
command was probably split or edited when copied. Re-copy the ENTIRE
one-line command from your welcome email (it includes
SABR_TENANT_TOKEN=...). Lost the email? Write dean@sabrtechnologies.com
and it can be re-sent."
else
  say ""
  say "${C}NOTE:${N} no tenant token was provided, so this mind has no link to a"
  say "Sabr account. It will install and run, and it will know this about"
  say "itself. If you PURCHASED an SI, don't use the bare command from the"
  say "website — copy the personal install command from your welcome email"
  say "(it starts with curl and includes SABR_TENANT_TOKEN=...). Lost it?"
  say "Email dean@sabrtechnologies.com and it can be re-sent."
  say ""
fi

# ── Privacy scrub ──────────────────────────────────────────────
# Durable on every install: remove Dean's private notes and internal dev
# docs so a client machine never carries his personal life on disk. The
# brain already refuses to load these for client SIs; this clears the raw
# files too. Runs every install, so it survives any tarball rebuild.
# ONE manifest, every path (2026-09-02): scrub_list.txt ships at the tree root
# and is the same list install_client.py and the GUI installer apply.
# "!client-only" entries are load-bearing for the owner's own SI, so they go
# only when this is a customer install (a tenant token, or a carried-over
# .env naming a different SI).
_SCRUB_CLIENT=""
if [ -n "${SABR_TENANT_TOKEN:-}" ]; then _SCRUB_CLIENT="1"; fi
_SCRUB_NAME="$(grep -E '^LEON_SI_NAME=' .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"'[:space:]' | tr 'A-Z' 'a-z')"
if [ -n "$_SCRUB_NAME" ] && [ "$_SCRUB_NAME" != "leon" ]; then _SCRUB_CLIENT="1"; fi
if [ -f scrub_list.txt ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%%$'\r'}"
    case "$_line" in ''|'#'*) continue ;; esac
    case "$_line" in
      '!client-only '*) [ -n "$_SCRUB_CLIENT" ] || continue; _line="${_line#!client-only }" ;;
    esac
    case "$_line" in /*|*..*) continue ;; esac   # never leave the tree
    rm -rf -- "./$_line" 2>/dev/null || true
  done < scrub_list.txt
else
  # Tarball older than the manifest: the irreducible minimum.
  rm -f leon_notes.txt brain/owner_facts.py 2>/dev/null || true
fi

# ── Create venv (the PEP 668-safe path) ──
say ""
say "Creating environment..."
rm -rf .venv
"$PY" -m venv .venv >$LEON_LOGDIR/venv.log 2>&1
VPYTHON=""
if   [ -x .venv/bin/python3 ];        then VPYTHON="$PWD/.venv/bin/python3"
elif [ -x .venv/bin/python  ];        then VPYTHON="$PWD/.venv/bin/python"
elif [ -x .venv/Scripts/python.exe ]; then VPYTHON="$PWD/.venv/Scripts/python.exe"
fi

PIPFLAGS=""
if [ -z "$VPYTHON" ]; then
  # venv genuinely could not be built. Fall back to system python but stay
  # PEP 668-safe so pip does not hard-abort (this is what killed the old script).
  say "${Y}[WARN]${N} venv unavailable — using system Python with --break-system-packages."
  say "        (Cleaner fix: sudo apt-get install -y python3-venv && re-run.)"
  VPYTHON="$PY"
  PIPFLAGS="--break-system-packages --user"
else
  say "${G}[OK]${N} Virtual environment"
fi

# ── Install Python deps (with REAL error handling, no silent death) ──
say ""
spin_start "Installing packages (1-2 minutes)..."
"$VPYTHON" -m pip install $PIPFLAGS --quiet --upgrade pip >$LEON_LOGDIR/pip.log 2>&1
# CORE deps — the brain CANNOT think or serve without these. If any fail,
# the install is genuinely unusable, so we die with the real reason.
# B12: EXACT pins. Every version below was resolved with importlib.metadata
# from the interpreter actually running a healthy brain — not PyPI latest,
# not guessed. Unpinned, a breaking release of any one of these silently
# breaks every new install worldwide with no change on our side.
# pyperclip and screeninfo stay unpinned: they are NOT installed on the
# reference system, so there is no observed version to pin, and neither is
# imported anywhere in brain/, server/ or sensory/ (0 hits for `import`).
"$VPYTHON" -m pip install $PIPFLAGS --quiet \
      numpy==2.4.6 scipy==1.17.1 fastapi==0.136.3 "uvicorn[standard]==0.49.0" \
      websockets==10.4 python-multipart==0.0.32 python-dotenv==1.2.2 \
      Pillow==12.2.0 mss==10.2.0 psutil==7.2.2 anthropic==0.105.2 \
      requests==2.34.2 aiohttp==3.14.1 \
      pyperclip screeninfo >>$LEON_LOGDIR/pip.log 2>&1
PIP_RC=$?
spin_stop
[ $PIP_RC -ne 0 ] && die "pip install failed." "$(cat $LEON_LOGDIR/pip.log)"
# VOICE / AUDIO deps — BEST EFFORT. pyaudio needs portaudio headers and often
# can't compile on a bare box; deepgram/elevenlabs are only used when the client
# adds a key. None are hard-imported by the brain, so a failure here must NEVER
# brick the install — the SI still boots, thinks, and talks via the free voice.
# WHY pyaudio IS ON ITS OWN LINE (do not merge it back in):
# pip resolves and BUILDS every package in one invocation before it installs
# ANY of them. pyaudio is the only source-build in this list — it compiles
# against portaudio.h. When that build fails (the normal case on a Mac without
# the header, and on any bare box), pip exits before installing the whole
# batch, so sounddevice, pyttsx3, vosk and webrtcvad silently never land
# either. `|| true` hides it: install reports success and the SI is mute with
# no wake word. Reproduced 2026-08-10: `pip install pyperclip <bad-pkg>` ->
# rc=1 and pyperclip NOT installed. One line per failure domain from here on.
spin_start "Installing voice & audio (optional)..."
"$VPYTHON" -m pip install $PIPFLAGS --quiet \
      pyttsx3 faster-whisper deepgram-sdk elevenlabs \
      sounddevice soundfile \
      vosk webrtcvad >>$LEON_LOGDIR/pip.log 2>&1 || true

# networkx, own line (one failure domain per line — see the note above).
# Optional: without it the brainweb exporter falls back from Louvain to label
# propagation — works, just visibly worse clustering. Pure-python wheel,
# installs everywhere; unpinned so pip picks the newest the venv's Python
# supports (3.5+ needs py3.11, older pythons resolve to an older networkx).
"$VPYTHON" -m pip install $PIPFLAGS --quiet networkx >>$LEON_LOGDIR/pip.log 2>&1 || true

# pyaudio, isolated, and told where Homebrew put the header. The probe above
# already installed portaudio via brew; without these flags the compiler still
# never finds it on Apple Silicon (/opt/homebrew, not /usr/local).
if [ "$OS" = "Darwin" ] && command -v brew &>/dev/null; then
  _BP="$(brew_prefix)"
  CPPFLAGS="-I${_BP}/include${CPPFLAGS:+ $CPPFLAGS}" \
  LDFLAGS="-L${_BP}/lib${LDFLAGS:+ $LDFLAGS}" \
  "$VPYTHON" -m pip install $PIPFLAGS --quiet pyaudio >>$LEON_LOGDIR/pip.log 2>&1 || true
else
  "$VPYTHON" -m pip install $PIPFLAGS --quiet pyaudio >>$LEON_LOGDIR/pip.log 2>&1 || true
fi
# vosk + webrtcvad power the "always listening" wake-word loop (say "hey <name>").
# Default wake backend is Vosk; its ~40MB model auto-downloads on first use.
# Without these, toggling always-listening throws ModuleNotFoundError: vosk.
spin_stop
if [ "$OS" = "Darwin" ]; then
  # pyobjc-framework-Cocoa gives Foundation + AppKit, which pyttsx3's macOS
  # voice driver (NSSpeechSynthesizer) needs — without it the free fallback
  # voice fails to init and the SI goes silent on Mac. ApplicationServices
  # alone is NOT enough.
  "$VPYTHON" -m pip install $PIPFLAGS --quiet pyobjc-framework-ApplicationServices pyobjc-framework-Cocoa >>$LEON_LOGDIR/pip.log 2>&1 || true
fi
say "${G}[OK]${N} Packages installed"

# ── VERIFY: actually import the core deps. No lying that it worked. ──
say ""
say "Verifying install..."
# EVERY package the CORE install line declares, not a subset. Until 2026-08-11
# this imported 6 of the 14 and skipped uvicorn — which run.py imports to serve
# the dashboard at all. So pip could exit 0 with a uvicorn that does not import
# (missing shared lib, ABI mismatch — the exact failure this script already
# documents for pyaudio), the installer printed the green banner, and the user
# discovered it later as ModuleNotFoundError when nothing would start. A gate
# captioned "no lying that it worked" has to check what it claims to check.
# Pillow imports as PIL and python-multipart as multipart — import NAMES here,
# never distribution names, or the gate fails on a perfectly good install.
if ! "$VPYTHON" -c "import numpy, scipy, fastapi, uvicorn, websockets, multipart, dotenv, PIL, mss, psutil, anthropic, requests, aiohttp" >$LEON_LOGDIR/verify.log 2>&1; then
  die "Core imports failed after install — environment is not usable." "$(cat $LEON_LOGDIR/verify.log)"
fi
say "${G}[OK]${N} Core dependencies verified"
# The new tree is proven usable, so it is no longer something to roll back
# FROM — rolling back past this point would throw away a good install over a
# cosmetic later failure. The previous install stays on disk until the owner
# confirms and deletes it.
disarm_rollback
# Voice is optional — report it honestly but never fail on it.
if "$VPYTHON" -c "import elevenlabs, deepgram" >/dev/null 2>&1; then
  say "${G}[OK]${N} Premium voice stack ready (ElevenLabs + Deepgram)"
else
  say "${Y}[i]${N} Premium voice stack not installed — SI will use the free built-in voice."
fi

# ── Helper scripts (bake in the resolved python path) ──
printf '#!/bin/bash\ncd "$(dirname "$0")"\nexec "%s" install_client.py\n' "$VPYTHON" > setup.sh
chmod +x setup.sh
printf '#!/bin/bash\ncd "$(dirname "$0")"\nexec "%s" run.py "$@"\n' "$VPYTHON" > start.sh
chmod +x start.sh
say "${G}[OK]${N} Helper scripts created"

# ── VOICE GATE: the SI needs a language model or it installs MUTE ──────
# Hard-learned: the brain, memory, neural sim and dashboard can all come up
# perfectly and the SI still cannot say a single word, because nothing in
# this installer ever guaranteed the `claude` CLI exists and is logged in.
# That produced an SI that answered "give me a second" forever. We check it
# here, out loud, BEFORE handing off — non-fatal (the install is still good)
# but never silent.
say ""
say "Checking language connection..."
CLAUDE_BIN=""
for c in "$(command -v claude 2>/dev/null)" \
         "$HOME/.local/bin/claude" \
         "$HOME/.claude/local/claude" \
         "/usr/local/bin/claude" \
         "/opt/homebrew/bin/claude"; do
  [ -n "$c" ] && [ -x "$c" ] && { CLAUDE_BIN="$c"; break; }
done

if [ -z "$CLAUDE_BIN" ] && command -v npm >/dev/null 2>&1; then
  say "  Installing the Claude CLI (one time)..."
  if run_timeout 300 npm install -g @anthropic-ai/claude-code >$LEON_LOGDIR/claude_npm.log 2>&1; then
    CLAUDE_BIN="$(command -v claude 2>/dev/null)"
    [ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"
  fi
fi

VOICE_OK=0
if [ -n "$CLAUDE_BIN" ]; then
  # Only a real end-to-end reply proves it. Presence of the binary, or of a
  # credentials file, proves nothing — both were true while the SI was mute.
  if run_timeout 90 "$CLAUDE_BIN" -p "reply with the single word: ready" \
       >$LEON_LOGDIR/claude_probe.log 2>&1 \
     && grep -qi 'ready' $LEON_LOGDIR/claude_probe.log; then
    VOICE_OK=1
  fi
fi

if [ "$VOICE_OK" = "1" ]; then
  say "${G}[OK]${N} Language connection live — your SI can speak."
else
  say ""
  say "${Y}================================================${N}"
  say "${Y}  ACTION NEEDED — your SI cannot talk yet${N}"
  say "${Y}================================================${N}"
  if [ -z "$CLAUDE_BIN" ]; then
    say "  The Claude CLI is not installed. Install Node.js, then run:"
    say "    ${C}npm install -g @anthropic-ai/claude-code${N}"
    say "  ...and then:  ${C}claude${N}   (sign in when it asks)"
  else
    say "  Found the Claude CLI at:"
    say "    ${C}$CLAUDE_BIN${N}"
    say "  ...but it is not signed in yet. Run this once and sign in:"
    say ""
    say "    ${C}claude${N}"
    say ""
    say "  Everything else installed fine. Your SI will have memory, senses"
    say "  and a dashboard — it just stays silent until this is done."
  fi
  say "${Y}================================================${N}"
  say ""
fi

# ── Hand off to setup — run it RIGHT NOW, zero copy-paste ──────────────
# bootstrap is normally run via `curl ... | bash`, so stdin is the pipe, not
# the keyboard — setup.sh (which asks 4 questions) would get EOF and die.
# We re-exec it bound to /dev/tty so it talks straight to the user's real
# terminal. No "now type this command" step. Only if there's genuinely no
# terminal (CI / headless) do we fall back to printing the one command.
say ""
say "${G}================================================${N}"
say "${G}  Brain installed. Starting setup...${N}"
say "${G}================================================${N}"
say ""
if [ -e /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
  exec ./setup.sh </dev/tty >/dev/tty 2>&1
else
  say "  No interactive terminal here. Finish setup with:"
  say ""
  say "    ${C}cd ~/leon-brain && ./setup.sh${N}"
  say ""
fi
