#!/usr/bin/env bash
##############################################################################
# DeepGEMM installation script
##############################################################################

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd  )"
source ${SCRIPT_DIR}/common.sh

DEEPGEMM_SOURCE_DIR="/app/DeepGEMM"
DEEPGEMM_REPO_URL="https://github.com/deepseek-ai/DeepGEMM"

banner "Environment summary"
echo "Python version      : ${PYTHON_VERSION}"
echo "Virtualenv path     : ${VENV_PATH}"
echo "uv binary           : ${UV}"
echo "DeepGEMM repo       : ${DEEPGEMM_REPO_URL}"
echo "====================================================================="

# Dependencies
upip cuda-python

clone_or_update "${DEEPGEMM_REPO_URL}" "${DEEPGEMM_SOURCE_DIR}" "${DEEPGEMM_BRANCH:-}" "${DEEP_GEMM_COMMIT:-}"
pushd "${DEEPGEMM_SOURCE_DIR}" >/dev/null
git submodule update --init --recursive
"${PYTHON}" setup.py install
popd >/dev/null
