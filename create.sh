source bootstrap.env
. utils.sh


# set out conjur-oss namespace
oc new-project $CONJUR_NAMESPACE_NAME
oc config set-context $(oc config current-context) --namespace="$CONJUR_NAMESPACE_NAME" > /dev/null

# create our service account in our namespace
oc create serviceaccount $CONJUR_SERVICEACCOUNT_NAME -n $CONJUR_NAMESPACE_NAME

# create secret for docker
oc create secret docker-registry $SECRET_NAME --docker-server=$DOCKER_REGISTRY_PATH --docker-username=_ --docker-password=$(oc whoami -t) --docker-email=_

# Why are we deleteing this clusterrole? 
oc delete --ignore-not-found clusterrole conjur-authenticator-$CONJUR_NAMESPACE_NAME

# Grant default service account permissions it needs for authn-k8s to:
# 1) get + list pods (to verify pod names)
# 2) create + get pods/exec (to inject cert into app sidecar
sed -e "s#{{ CONJUR_NAMESPACE_NAME }}#$CONJUR_NAMESPACE_NAME#g" ./conjur-authenticator-role.yaml | oc apply -f -


# allow pods to run as root
oc adm policy add-scc-to-user anyuid "system:serviceaccount:$CONJUR_NAMESPACE_NAME:$CONJUR_SERVICEACCOUNT_NAME"


# Create resources
oc adm policy add-scc-to-user anyuid -z default # TODO: check why
oc adm policy add-scc-to-user anyuid -z conjur-cluster # TODO: check why

# Why do we set our namespace again?
oc config set-context $(oc config current-context) --namespace="$CONJUR_NAMESPACE_NAME" > /dev/null

# Create image pull secret
oc policy add-role-to-user system:image-puller "system:serviceaccount:$CONJUR_NAMESPACE_NAME:$CONJUR_SERVICEACCOUNT_NAME" -n=default
oc policy add-role-to-user system:image-puller "system:serviceaccount:$CONJUR_NAMESPACE_NAME:$CONJUR_SERVICEACCOUNT_NAME" -n=$CONJUR_NAMESPACE_NAME

# Configuring initial values
oc create secret generic conjur-data-key --from-literal=CONJUR_DATA_KEY=$(openssl rand -base64 32) --namespace=$CONJUR_NAMESPACE_NAME
postgres_password=$(openssl rand -base64 16)
oc create secret generic conjur-database-url --from-literal=DATABASE_URL=postgres://postgres:$postgres_password@conjur-postgres/postgres --namespace=$CONJUR_NAMESPACE_NAME
oc create secret generic postgres-admin-password --from-literal=POSTGRESQL_ADMIN_PASSWORD=$postgres_password --namespace=$CONJUR_NAMESPACE_NAME

platform_image() {
  echo "$DOCKER_REGISTRY_PATH/$CONJUR_NAMESPACE_NAME/$1:$CONJUR_NAMESPACE_NAME"
}

# Deploy our postgres database as a pod
postgres_image=$(platform_image "postgres")
sed -e "s#{{ IMAGE_PULL_POLICY }}#$IMAGE_PULL_POLICY#g" "./conjur-postgres.yaml" | sed -e "s#{{ POSTGRES_IMAGE }}#$postgres_image#g" | oc create -f -

# Deploy conjur pod
conjur_image=$(platform_image "conjur")
nginx_image=$(platform_image "nginx")

# Log into docker
sudo docker login --username=admin --password=$(oc whoami -t) $DOCKER_REGISTRY_PATH

# Push conjur image to openshift repo
sudo docker pull cyberark/conjur
imageId=$(sudo docker images | grep "docker.io/cyberark/conjur " | awk '{print $3}')
sudo docker tag $imageId $conjur_image
sudo docker push $conjur_image

# Push nginx image to openshift repo
cd nginx_base
sudo docker build -t $nginx_image .
sudo docker push $nginx_image
cd ..

sed -e "s#{{ CONJUR_IMAGE }}#$conjur_image#g" "./conjur-cluster.yaml" |
  sed -e "s#{{ NGINX_IMAGE }}#$nginx_image#g" |
  sed -e "s#{{ CONJUR_DATA_KEY }}#$(openssl rand -base64 32)#g" |
  sed -e "s#{{ CONJUR_ACCOUNT }}#$CONJUR_ACCOUNT#g" |
  sed -e "s#{{ IMAGE_PULL_POLICY }}#$IMAGE_PULL_POLICY#g" |
  oc create -f -

# Deploy conjur cli pod
cli_app_image=$(platform_image conjur-cli)
sed -e "s#{{ CLI_IMAGE }}#$cli_app_image#g" "./conjur-cli.yaml" |
  sed -e "s#{{ IMAGE_PULL_POLICY }}#$IMAGE_PULL_POLICY#g" |
  oc create -f -

function wait_for_it() {
  local timeout=$1
  local spacer=2
  shift

  if ! [ $timeout = '-1' ]; then
    local times_to_run=$((timeout / spacer))

    echo "Waiting for '$@' up to $timeout s"
    for i in $(seq $times_to_run); do
      eval $@ > /dev/null && echo 'Success!' && break
      echo -n .
      sleep $spacer
    done

    eval $@
  else
    echo "Waiting for '$@' forever"

    while ! eval $@ > /dev/null; do
      echo -n .
      sleep $spacer
    done
    echo 'Success!'
  fi
}

echo "Waiting for Conjur pod to launch..."
wait_for_it 300 "oc describe po conjur-cluster | grep State: | grep -c Running | grep -q 2"
echo "Waiting for Conjur cli pod to launch..."
wait_for_it 300 "oc describe po conjur-cli | grep State: | grep -c Running | grep -q 1"
echo "Waiting for postgres pod to launch..."
wait_for_it 300 "oc describe po conjur-postgres | grep State: | grep -c Running | grep -q 1"


sleep 15

echo "Conjur created."


# Setup Conjur
echo "Creating admin account."

conjur_pod=$(oc get pods | grep conjur-cluster | cut -f 1 -d ' ')
conjur_admin_api_key=$(oc exec $conjur_pod -c conjur conjurctl account create $CONJUR_ACCOUNT | grep "API key for admin" | cut -f 5 -d ' ')
echo "Admin API key: $conjur_admin_api_key"

sleep 60

# Setup Conjur CLI
echo "Changing admin password."

conjur_cli_pod=$(oc get pods | grep conjur-cli | cut -f 1 -d ' ')
oc exec $conjur_cli_pod -- bash -c "yes yes | conjur init -a $CONJUR_ACCOUNT -u https://conjur-cluster"
sleep 10
oc exec $conjur_cli_pod -- conjur authn login -u admin -p $conjur_admin_api_key
sleep 5
oc exec $conjur_cli_pod -- conjur user update_password -p Cyberark1


