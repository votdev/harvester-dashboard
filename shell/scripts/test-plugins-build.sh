#!/usr/bin/env bash

set -e

echo "Checking plugin build"

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$( cd $SCRIPT_DIR && cd ../.. & pwd)"
SHELL_DIR=$BASE_DIR/shell/

echo ${SCRIPT_DIR}

SKIP_SETUP="false"
SKIP_STANDALONE="false"

if [ "$1" == "-s" ]; then
  SKIP_SETUP="true"
fi

if [ $SKIP_SETUP == "false" ]; then
  set +e
  which verdaccio > /dev/null
  RET=$?
  set -e

  if [ $RET -ne 0 ]; then
    echo "Verdaccio not installed"
    npm install -g verdaccio@5.32.2
  fi

  set +e
  RUNNING=$(pgrep Verdaccio | wc -l | xargs)
  set -e

  if [ $RUNNING -eq 0 ]; then
    verdaccio > verdaccio.log &
    PID=$!

    echo "Verdaccio: $PID"

    sleep 10

    echo "Configuring Verdaccio user"

    # Remove existing admin if already there
    if [ -f ~/.config/verdaccio/htpasswd ]; then
      sed -i.bak -e '/^admin:/d' ~/.config/verdaccio/htpasswd
    fi

    curl -XPUT -H "Content-type: application/json" -d '{ "name": "admin", "password": "admin" }' 'http://localhost:4873/-/user/admin' > login.json
    TOKEN=$(jq -r .token login.json)
    rm login.json
    cat > ~/.npmrc << EOF
//127.0.0.1:4873/:_authToken="$TOKEN"
//localhost:4873/:_authToken="$TOKEN"
EOF
  else
    echo "Verdaccio is already running"
  fi
fi

if [ -d ~/.local/share/verdaccio/storage/@rancher ]; then 
  rm -rf ~/.local/share/verdaccio/storage/@rancher/*
else
  rm -rf ~/.config/verdaccio/storage/@rancher/*
fi

export YARN_REGISTRY=http://localhost:4873
export NUXT_TELEMETRY_DISABLED=1

# Remove test package from previous run, if present
rm -rf ${BASE_DIR}/pkg/test-pkg

# We need to patch the version number of the shell, otherwise if we are running
# with the currently published version, things will fail as those versions
# are already published and Verdaccio will check, since it is a read-through cache
sed -i.bak -e "s/\"version\": \"[0-9]*.[0-9]*.[0-9]*\",/\"version\": \"7.7.7\",/g" ${SHELL_DIR}/package.json
rm ${SHELL_DIR}/package.json.bak

# Same as above for Rancher Components
# We might have bumped the version number but its not published yet, so this will fail
sed -i.bak -e "s/\"version\": \"[0-9]*.[0-9]*.[0-9]*\",/\"version\": \"7.7.7\",/g" ${BASE_DIR}/pkg/rancher-components/package.json

# Publish shell
echo "Publishing shell packages to local registry"
yarn install
${SHELL_DIR}/scripts/publish-shell.sh

# Publish rancher components
yarn build:lib
yarn publish:lib

# We pipe into cat for cleaner logging - we need to set pipefail
# to ensure the build fails in these cases
set -o pipefail

if [ "${SKIP_STANDALONE}" == "false" ]; then
  DIR=$(mktemp -d)
  pushd $DIR > /dev/null

  echo "Using temporary directory ${DIR}"

  echo "Verifying app creator package"

  yarn create @rancher/app test-app
  pushd test-app
  yarn install

  echo "Building skeleton app"
  FORCE_COLOR=true yarn build | cat

  # Package creator
  echo "Verifying package creator package"
  yarn create @rancher/pkg test-pkg

  echo "Building test package"
  FORCE_COLOR=true yarn build-pkg test-pkg | cat

  # Add test list component to the test package
  # Validates rancher-components imports
  mkdir pkg/test-pkg/list
  cp ${SHELL_DIR}/list/catalog.cattle.io.clusterrepo.vue pkg/test-pkg/list

  FORCE_COLOR=true yarn build-pkg test-pkg | cat

  echo "Cleaning temporary dir"
  popd > /dev/null

  rm -rf ${DIR}
fi

pushd $BASE_DIR
pwd
ls

# Now try a plugin within the dashboard codebase
echo "Validating in-tree package"

yarn install

rm -rf ./pkg/test-pkg
yarn create @rancher/pkg test-pkg -t
cp ${SHELL_DIR}/list/catalog.cattle.io.clusterrepo.vue ./pkg/test-pkg/list
FORCE_COLOR=true yarn build-pkg test-pkg | cat
rm -rf ./pkg/test-pkg

echo "All done"
