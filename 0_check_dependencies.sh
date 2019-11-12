#!/bin/bash
set -eo pipefail

. utils.sh

check_env_var "CONJUR_NAMESPACE_NAME"

#TODO: add all required env vars