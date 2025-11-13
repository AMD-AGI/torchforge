#!/usr/bin/env bash

set -euo pipefail

# Core locations and versions (override via environment variables if needed).
MINIFORGE_DIR=${MINIFORGE_DIR:-"$HOME/miniforge3"}
ENV_NAME=${ENV_NAME:-forge-env}
PYTHON_VERSION=${PYTHON_VERSION:-3.12}
WORKSPACE=${WORKSPACE:-"$HOME/forge-workspace"}
VLLM_REF=${VLLM_REF:-v0.10.0}
TORCHTITAN_REF=${TORCHTITAN_REF:-61c25f8d3bf1792f6c4b80417b9a1f5dd464deaf}
TORCHFORGE_REF=${TORCHFORGE_REF:-6b65eb416ae42930e5f7ce69a5b1cf59b8ee7862}
MONARCH_REF=${MONARCH_REF:-xinyu/rdma}
DEFAULT_USER=${SUDO_USER:-$(whoami)}
RENDER_USER=${RENDER_USER:-$DEFAULT_USER}
HF_TOKEN=${HF_TOKEN:-hf_your_token} # Edit here

# Target accelerators / build flags.
export VLLM_TARGET_DEVICE=${VLLM_TARGET_DEVICE:-rocm}
export PYTORCH_ROCM_ARCH=${PYTORCH_ROCM_ARCH:-gfx942}
export HYPERACTOR_CODEC_MAX_FRAME_LENGTH=${HYPERACTOR_CODEC_MAX_FRAME_LENGTH:-134217728}

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

run_in_dir() {
  local dir=$1
  shift
  log "($dir) $*"
  (cd "$dir" && "$@")
}

ensure_miniforge() {
  if [ -d "$MINIFORGE_DIR" ]; then
    log "Found Miniforge at $MINIFORGE_DIR"
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      if ! command -v sudo >/dev/null 2>&1; then
        die "curl is missing and sudo is unavailable to install it."
      fi
      log "curl not found; installing via apt-get (sudo may prompt)"
      sudo apt-get update
      sudo apt-get install -y curl
    else
      die "curl is required to bootstrap Miniforge but automatic installation is unsupported on this system."
    fi
  fi

  local installer_name
  installer_name="Miniforge3-$(uname)-$(uname -m).sh"
  local installer_url
  installer_url="https://github.com/conda-forge/miniforge/releases/latest/download/${installer_name}"
  local installer_path="/tmp/${installer_name}"

  log "Miniforge not found; downloading $installer_url"
  curl -L -o "$installer_path" "$installer_url"
  chmod +x "$installer_path"

  log "Installing Miniforge into $MINIFORGE_DIR"
  bash "$installer_path" -b -p "$MINIFORGE_DIR"
  rm -f "$installer_path"

  if [ -f "$HOME/.bashrc" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.bashrc"
  fi
}

ensure_render_group() {
  local user=$RENDER_USER
  if ! id "$user" >/dev/null 2>&1; then
    die "User $user not found; set RENDER_USER=<name> if needed."
  fi

  local groups
  groups=$(id -nG "$user")
  local needs_change=0

  for group in render video; do
    if ! getent group "$group" >/dev/null 2>&1; then
      die "Required group '$group' does not exist on this system."
    fi
    if ! grep -qw "$group" <<<"$groups"; then
      needs_change=1
    fi
  done

  if [ "$needs_change" -eq 0 ]; then
    log "$user already belongs to render and video groups"
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    die "sudo is required to modify group membership for $user"
  fi

  log "Adding $user to render and video groups (sudo may prompt)"
  sudo usermod -aG render,video "$user"

  log "Spawning short-lived newgrp render shell to refresh membership"
  newgrp render <<'EOF'
echo "render group shell refreshed; exiting."
EOF
  log "Group changes recorded; open a new shell or run 'newgrp render' manually if needed."
}

activate_conda() {
  if [ -f "$MINIFORGE_DIR/etc/profile.d/conda.sh" ]; then
    # shellcheck disable=SC1090
    source "$MINIFORGE_DIR/etc/profile.d/conda.sh"
  else
    eval "$("$MINIFORGE_DIR/bin/conda" shell.bash hook)"
  fi

  if ! conda info --envs | awk '{print $1}' | grep -qx "$ENV_NAME"; then
    log "Creating conda environment $ENV_NAME (python=$PYTHON_VERSION)"
    conda create -y -n "$ENV_NAME" "python=$PYTHON_VERSION"
  else
    log "Found existing conda environment $ENV_NAME"
  fi

  log "Activating conda environment $ENV_NAME"
  conda activate "$ENV_NAME"
}

install_base_packages() {
  log "Installing libunwind via conda"
  conda install -y libunwind

  log "Upgrading pip/setuptools/wheel"
  python -m pip install -U pip setuptools wheel

  log "Installing uv"
  python -m pip install -U uv
}

setup_rust() {
  if ! command -v rustup >/dev/null 2>&1; then
    log "Installing rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  else
    log "rustup already installed"
  fi

  if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
  fi

  log "Ensuring nightly toolchain"
  rustup toolchain install nightly
  rustup default nightly
}

install_torch_stack() {
  log "Installing ROCm PyTorch stack via uv"
  uv pip install torch==2.9.0+rocm6.4 torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/rocm6.4 \
    --force-reinstall

  log "Adjusting ROCm shared library symlinks inside PyTorch"
  local torch_lib_dir
  torch_lib_dir=$(python - <<'PY'
import os
import torch
print(os.path.join(os.path.dirname(torch.__file__), "lib"))
PY
)

  local -a pairs=(
    "libamdhip64.so.6 libamdhip64.so"
    "libhsa-runtime64.so.1 libhsa-runtime64.so"
    "librccl.so.1 librccl.so"
    "librocprofiler-register.so.0 librocprofiler-register.so"
    "librocm_smi64.so.7 librocm_smi64.so"
    "libdrm.so.2 libdrm.so"
    "libdrm_amdgpu.so.1 libdrm_amdgpu.so"
  )

  local pair
  for pair in "${pairs[@]}"; do
    IFS=' ' read -r target link <<<"$pair"
    rm -f "$torch_lib_dir/$target"
    ln -s "$link" "$torch_lib_dir/$target"
  done
}

ensure_repo() {
  local repo_url=$1
  local dest=$2
  local ref=$3

  if [ ! -d "$dest/.git" ]; then
    log "Cloning $repo_url into $dest"
    git clone "$repo_url" "$dest"
  else
    log "Reusing existing repo at $dest"
  fi

  run_in_dir "$dest" git fetch origin
  run_in_dir "$dest" git fetch origin --tags
  run_in_dir "$dest" git checkout "$ref"

  local branch
  branch="HEAD"
  local branch_name
  if branch_name=$(cd "$dest" && git rev-parse --abbrev-ref HEAD 2>/dev/null); then
    branch="$branch_name"
  fi
  if [ "$branch" != "HEAD" ]; then
    run_in_dir "$dest" git pull --ff-only origin "$branch"
  fi
}

setup_vllm() {
  local dest="$WORKSPACE/vllm"
  ensure_repo https://github.com/vllm-project/vllm.git "$dest" "$VLLM_REF"

  run_in_dir "$dest" python -m pip install -r requirements/rocm.txt
  python -m pip install --upgrade "cmake>=3.27" ninja
  python -m pip install amdsmi==6.4.2

  log "Installing vLLM in editable mode (ROCm)"
  run_in_dir "$dest" python -m pip install -e . --no-build-isolation
}

setup_torchtitan() {
  local dest="$WORKSPACE/torchtitan"
  ensure_repo https://github.com/pytorch/torchtitan.git "$dest" "$TORCHTITAN_REF"

  run_in_dir "$dest" python -m pip install -r requirements.txt
  run_in_dir "$dest" python -m pip install -e .
}

setup_torchforge() {
  local dest="$WORKSPACE/torchforge"
  ensure_repo https://github.com/meta-pytorch/torchforge.git "$dest" "$TORCHFORGE_REF"

  run_in_dir "$dest" python -m pip install -e ".[dev]"
  python -m pip uninstall -y torchmonarch || true
}

setup_monarch() {
  local dest="$WORKSPACE/monarch"
  ensure_repo https://github.com/AMD-AGI/monarch.git "$dest" "$MONARCH_REF"

  run_in_dir "$dest" uv pip install -r build-requirements.txt
  if ! ulimit -n 2048; then
    log "Unable to raise open file limit to 2048, continuing anyway"
  fi
  run_in_dir "$dest" env LIBRARY_PATH="$CONDA_PREFIX/lib" uv pip install --no-build-isolation -e .
}

install_torchstore() {
  log "Installing torchstore==0.1.2"
  python -m pip install torchstore==0.1.2
}

patch_torchtitan_engine() {
  local file="$WORKSPACE/torchtitan/torchtitan/experiments/forge/engine.py"
  if [ ! -f "$file" ]; then
    log "Skipping torchtitan patch (missing $file)"
    return
  fi

  log "Ensuring determinism call includes distinct_seed_mesh_dims in $(realpath "$file")"
  TORCHTITAN_ENGINE="$file" python <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["TORCHTITAN_ENGINE"]).resolve()
text = path.read_text()
if "dist_utils.set_determinism" not in text:
    raise SystemExit(f"dist_utils.set_determinism call not found in {path}")
if "distinct_seed_mesh_dims=" in text:
    raise SystemExit(0)

lines = text.splitlines()
call_idx = next(
    (i for i, line in enumerate(lines) if "dist_utils.set_determinism" in line), None
)
if call_idx is None:
    raise SystemExit(f"Unable to locate call site in {path}")

job_line = None
close_idx = None
for i in range(call_idx, len(lines)):
    if "job_config.debug" in lines[i]:
        job_line = i
    if lines[i].strip().startswith(")") and i > call_idx:
        close_idx = i
        break

if job_line is None or close_idx is None:
    raise SystemExit(f"Unexpected formatting around set_determinism call in {path}")

indent = re.match(r"(\s*)", lines[job_line]).group(1)
lines.insert(job_line + 1, f'{indent}distinct_seed_mesh_dims=["pp"],')

new_text = "\n".join(lines)
if not new_text.endswith("\n"):
    new_text += "\n"
path.write_text(new_text)
PY
}

patch_torchstore_controller() {
  log "Making torchstore controller APIs async"
  python <<'PY'
import inspect
import re
from pathlib import Path

import torchstore.controller as controller

path = Path(inspect.getfile(controller)).resolve()
text = path.read_text()
names = [
    "get_controller_strategy",
    "locate_volumes",
    "notify_put",
    "keys",
    "notify_delete",
]
changed = False
for name in names:
    if f"async def {name}" in text:
        continue
    pattern = rf"(\n\s*)def {name}\("
    text, count = re.subn(pattern, r"\1async def " + name + "(", text, count=1)
    if count == 0:
        raise SystemExit(f"Could not locate definition for {name} in {path}")
    changed = True

if changed:
    path.write_text(text)
PY
}

huggingface_login() {
  log "Ensuring Hugging Face CLI is available"
  if ! command -v hf >/dev/null 2>&1; then
    python -m pip install -U "huggingface_hub[cli]"
  fi

  if command -v hf >/dev/null 2>&1; then
    if [ -n "${HF_TOKEN:-}" ]; then
      hf auth login --token "$HF_TOKEN"
    else
      hf auth login || log "hf auth login skipped (run manually later)"
    fi
  else
    log "hf CLI is still unavailable; install huggingface_hub manually to login"
  fi
}

main() {
  log "Workspace root: $WORKSPACE"
  log "HYPERACTOR_CODEC_MAX_FRAME_LENGTH set to $HYPERACTOR_CODEC_MAX_FRAME_LENGTH"
  ensure_miniforge
  ensure_render_group
  mkdir -p "$WORKSPACE"
  cd "$WORKSPACE"

  activate_conda
  install_base_packages
  setup_rust
  install_torch_stack
  setup_vllm
  setup_torchtitan
  install_torchstore
  setup_torchforge
  setup_monarch
  patch_torchtitan_engine
  patch_torchstore_controller
  huggingface_login

  log "Forge stack setup complete!"
}

main "$@"
