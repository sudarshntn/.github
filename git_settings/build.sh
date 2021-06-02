#!/usr/bin/env bash
#
# Copyright : IBM Corporation 2017, 2020
#

set -o errexit
set -o nounset
set -o pipefail

# source common utilities
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")"/dockerinspect.sh

COMMIT=$GIT_COMMIT

#Set the branch
BRANCH=$GIT_BRANCH;

#If this is a PR then use the PR branch, if PR branch is empty then build it
if [ ! -z "$GIT_PULL_REQUEST" ] && [ "${GIT_PULL_REQUEST}" != "false" ]; then
  BRANCH=$GIT_PULL_REQUEST_BRANCH;
  # set BRANCH to PR-Number if Brach is empty
  if [ -z "$BRANCH" ]; then
    BRANCH="PR-${GIT_PULL_REQUEST}";
  fi
fi

#Set the tag, if master then latest otherwise default to branch name
TAG=`if [ "$BRANCH" == "master" ]; then echo "latest"; else echo $BRANCH ; fi`
#Set the branch commit build tag
BRANCH_COMMIT_BUILD_TAG=${BRANCH}-${COMMIT}-${GIT_BUILD_NUMBER}

# If this is a release, update tags to include add the latest tag
if [[ "${BRANCH}" =~ ^release$|^hotfix$|^release-2018.06.20$ ]]; then
  #if tag is blank get it.
  if [ -z "$GIT_TAG" ]; then
    GIT_TAG=$(git describe --abbrev=0 --tags)
  fi
  TAG_ORIG=${TAG}
  TAG=${TAG_ORIG}_${GIT_TAG}
  BRANCH_COMMIT_BUILD_TAG=${BRANCH}_${GIT_TAG}-${COMMIT}-${GIT_BUILD_NUMBER}
fi

#Build image (we only push master or release branch)
# Branch must be of the form:
#    master
#    release
#    hotfix
# or release-20##.##.## (where # is a digit)
#
AFAAS_REPO=$AFAAS_DOCKER_REGISTRY/$DOCKER_IMAGE_NAME
DOCKER_REPO=$DOCKER_IMAGE_NAME
# main registry
echo "Connecting to Artifactory Registry: $AFAAS_DOCKER_REGISTRY"
echo "$AFAAS_TOKEN" | docker login --username="$AFAAS_USER" --password-stdin "$AFAAS_DOCKER_REGISTRY"
# caching regisry
REMOTE_DOCKER_REGISTRY=${AFAAS_DOCKER_REGISTRY/-docker-local\./-docker-remote\.}
echo "Connecting to Artifactory Registry: $REMOTE_DOCKER_REGISTRY"
echo "$AFAAS_TOKEN" | docker login --username="$AFAAS_USER" --password-stdin "$REMOTE_DOCKER_REGISTRY" || true

TEST_ARGS=${BUILD_ARGS:-}
echo "Building Docker image: $DOCKER_REPO"
if [ -z "$TEST_ARGS" ]; then
  docker build -t $DOCKER_REPO .
else
  docker build $BUILD_ARGS -t $DOCKER_REPO .
fi

# inspect the image for leaked credentials
if [ "${GIT_BRANCH}" == "release-2020.08.19" ]; then
  echo "Skipping inspect image for release-2020.08.19"
elif [ "${GIT_BRANCH}" == "release-2020.06.24" ]; then
  echo "Skipping inspect image for release-2020.06.24"
else
  inspectImage "$DOCKER_REPO"
fi

if [ "${GIT_PULL_REQUEST}" == "false" ] && [[ "${BRANCH}" =~ ^citi2019.09.19$|^master$|^premaster$|^release$|^hotfix$|^release-20[[:digit:]][[:digit:]].[[:digit:]][[:digit:]].[[:digit:]][[:digit:]]$ ]]; then
  #Tag with default latest or PR branch
  echo "Set tag: $AFAAS_REPO:$TAG"
  docker tag $DOCKER_REPO $AFAAS_REPO:$TAG
  #Tag with branch, git commit and build_number
  echo "Set tag: $AFAAS_REPO:${BRANCH_COMMIT_BUILD_TAG}"
  docker tag $DOCKER_REPO $AFAAS_REPO:$BRANCH_COMMIT_BUILD_TAG

  echo "############## Docker Push ##############"
  docker push $AFAAS_REPO

  # update pipeline (we use the branch commit build tag)
  $(dirname $0)/pipeline.py $BRANCH $DOCKER_IMAGE_NAME $AFAAS_REPO:$BRANCH_COMMIT_BUILD_TAG
  # PIPELINEV2=${PIPELINEV2:-}
  # echo "PIPELINEV2 IS: ${PIPELINEV2}"
  # if [ "${PIPELINEV2}" == "true" ]; then
    # echo "PIPELINEV2 is set to true, proceed with V2 update"
   if [ "${BRANCH}" != "citi2019.09.19" ]; then
        $(dirname $0)/pipelinev2.py $BRANCH $DOCKER_IMAGE_NAME $AFAAS_REPO:$BRANCH_COMMIT_BUILD_TAG
   fi

   echo "############## Image Reaper ##############"
   python -m pip install requests >/dev/null || true  # install deps for the reaper
   "$(dirname "$0")"/imagereaper.py "$BRANCH" "$DOCKER_IMAGE_NAME" 10 || true

else
  echo "Not a master or release branch, skip Docker build push."
fi

# Disabling Clair scans temporarily #DEVOPS-15063
exit 0

# Clair vulnerability scans
if [ -n "$GIT_PULL_REQUEST" ] && [ "${GIT_PULL_REQUEST}" != "false" ] && [ "${GIT_SECURE_ENV_VARS}" == "true" ]; then
  START=$(date +%s)
  TAG=$GIT_BUILD_NUMBER
  CLAIR_OUTPUT="High"
  CLAIR_THRESHOLD="10"
  CLAIR_IMAGE_NAME="clair-vulnerability-scanner"
  KLAR_TRACE=""
  echo "Pushing docker $CLAIR_DOCKER_REGISTRY/$DOCKER_REPO:$TAG to artifactory"
  docker pull "$AFAAS_DOCKER_REGISTRY"/"$CLAIR_IMAGE_NAME"
  docker login -u "$AFAAS_USER" -p "$AFAAS_TOKEN" "$CLAIR_DOCKER_REGISTRY"
  docker tag "$DOCKER_REPO" "$CLAIR_DOCKER_REGISTRY"/"$DOCKER_REPO":"$TAG"
  docker push "$CLAIR_DOCKER_REGISTRY"/"$DOCKER_REPO":"$TAG"
  echo "Running Clair scans"

  docker run --rm -it --privileged=true \
  --name "$CLAIR_IMAGE_NAME" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e "USER=root" \
  -e CLAIR_ADDR="$CLAIR_ADDR" \
  -e CLAIR_OUTPUT="$CLAIR_OUTPUT" \
  -e CLAIR_THRESHOLD="$CLAIR_THRESHOLD" \
  -e DOCKER_USER="$AFAAS_USER" \
  -e DOCKER_PASSWORD="$AFAAS_TOKEN" \
  -e KLAR_TRACE="$KLAR_TRACE" \
  -e CLAIR_DOCKER_IMAGE="$CLAIR_DOCKER_REGISTRY"/"$DOCKER_REPO":"$TAG" \
  "$AFAAS_DOCKER_REGISTRY"/"$CLAIR_IMAGE_NAME" > "output.json"

  CLAIR_REGISTRY_SHORTNAME="$(cut -d'.' -f1 <<<"$CLAIR_DOCKER_REGISTRY")"
  echo "Cleaning the Repo"
  curl -u"$AFAAS_USER":"$AFAAS_TOKEN" \
  -X DELETE "https://na.artifactory.swg-devops.com/artifactory/$CLAIR_REGISTRY_SHORTNAME/$DOCKER_REPO/$TAG"

  END=$(date +%s)
  DIFF=$(( END - START ))
  echo "It took $DIFF seconds to complete scan"

  if ! vulnerabilities=$(jq -r '.Vulnerabilities[]' output.json)
  then
    cat output.json
    echo "Failed to scan vulnerabilities...Fix the issues to complete scan"
    exit 2
  elif [[ -n $vulnerabilities ]]; then
    echo "Found vulnerabilities..."
    echo "$vulnerabilities"
    exit 3
  else
    echo "Scan completed successfully..No issues found..."
  fi
else
  echo "Ignoring clair vulnerability scans as it's not a pull request(PR)"
fi
