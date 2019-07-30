#!/bin/bash
set -euo pipefail

. utils.sh
source bootstrap.env

set_namespace default

oc login -u $OSHIFT_CLUSTER_ADMIN_USERNAME

if has_namespace $CONJUR_NAMESPACE_NAME; then
  oc delete namespace $CONJUR_NAMESPACE_NAME

  printf "Waiting for $CONJUR_NAMESPACE_NAME namespace deletion to complete"

  while : ; do
    printf "..."

    if has_namespace "$CONJUR_NAMESPACE_NAME"; then
      sleep 5
    else
      break
    fi
  done

  echo ""
fi

echo "$CONJUR_NAMESPACE_NAME namespace purged."