#!/usr/bin/env bash

# exit on errors
set -e

# Script will check out the Demisto content repo and then generate documentation based upon the checkout

SCRIPT_DIR=$(dirname ${BASH_SOURCE})
CURRENT_DIR=`pwd`
if [[ "${SCRIPT_DIR}" != /* ]]; then
    SCRIPT_DIR="${CURRENT_DIR}/${SCRIPT_DIR}"
fi

export GIT_LFS_SKIP_SMUDGE=1

if [[ -n "$CONTENT_REPO_DIR" ]]; then
    CONTENT_GIT_DIR=$CONTENT_REPO_DIR
    echo "============== Local manual DEV MODE detected. ==================="
    echo "Using following directory for content repo: $CONTENT_GIT_DIR. As CONTENT_REPO_DIR env var is set."
    echo "================================="
else
    CONTENT_GIT_DIR=${SCRIPT_DIR}/.content
    if [[ -n "${NETLIFY}" ]]; then
        echo "Netlify env data:"
        echo "BRANCH=${BRANCH}"
        echo "HEAD=${HEAD}"
        echo "COMMIT_REF=${COMMIT_REF}"
        echo "PULL_REQUEST=${PULL_REQUEST}"
        echo "REVIEW_ID=${REVIEW_ID}"
        echo "DEPLOY_PRIME_URL=${DEPLOY_PRIME_URL}"
        echo "DEPLOY_URL=${DEPLOY_URL}"
        echo "CPU QUOTA"
        cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us || echo "CPU Quota not available"
        echo "CPU COUNT"
        nproc || echo "nproc not available"
        echo "MEMORY LIMIT (bytes)"
        cat /sys/fs/cgroup/memory/memory.limit_in_bytes || echo "Memory limit not available"
        echo "SWAP+MEMORY LIMIT (bytes)"
        cat /sys/fs/cgroup/memory/memory.memsw.limit_in_bytes || echo "Memory+Swap limit not available"
    fi
    if [[ -n "${NETLIFY}" && -n "${HEAD}" ]]; then
        CURRENT_BRANCH="${HEAD}"
    elif [[ -n "${CIRCLE_BRANCH}" ]]; then
        CURRENT_BRANCH=${CIRCLE_BRANCH}
    else
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    fi

    echo "==== current branch: ${CURRENT_BRANCH} ===="

    CONTENT_GIT_URL="https://github.com/demisto/content.git"
    CONTENT_BRANCH="master"
    REQUIRE_BRANCH=false
    if [ -n "${INCOMING_HOOK_BODY}" ]; then
        echo "INCOMING_HOOK_BODY=${INCOMING_HOOK_BODY}"
        INCOMING_HOOK_JSON=$(echo "${INCOMING_HOOK_BODY}" | python3 -c "import sys, urllib.parse as p; print(p.unquote(sys.stdin.read()));")
        hook_url=$(echo "${INCOMING_HOOK_JSON}" | jq -r .giturl)
        if [[ -n "${hook_url}" && "${hook_url}" != "null" ]]; then
            CONTENT_GIT_URL="${hook_url}"
        fi
        hook_branch=$(echo "${INCOMING_HOOK_JSON}" | jq -r .branch)
        if [[ -n "${hook_branch}" && "${hook_branch}" != "null" ]]; then
            CONTENT_BRANCH="${hook_branch}"
            REQUIRE_BRANCH=true
        fi    
    fi

    echo "==== content git url: ${CONTENT_GIT_URL} branch: ${CONTENT_BRANCH} ===="

    if [[ -d ${CONTENT_GIT_DIR} && $(cd ${CONTENT_GIT_DIR}; git remote get-url origin) != "${CONTENT_GIT_URL}" ]]; then
        echo "Deleting dir: ${CONTENT_GIT_DIR} as remote url dooesn't match ${CONTENT_GIT_URL} ..."
        rm -rf "${CONTENT_GIT_DIR}"
    fi

    if [ -n "${NETLIFY}" ]; then
        if [[ -d ${CONTENT_GIT_DIR} ]]; then
            echo "Content git dir cached size: $(du -sh ${CONTENT_GIT_DIR})"
            echo "Deleting cached content dir..."
            rm -rf "${CONTENT_GIT_DIR}"
        fi
        echo "Setting git config"
        git config --global user.email "netlifybuild@demisto.com"
        git config --global user.name "Netlify Dev Docs Build"
    fi

    if [ ! -d ${CONTENT_GIT_DIR} ]; then
        echo "Cloning content to dir: ${CONTENT_GIT_DIR} ..."
        git clone ${CONTENT_GIT_URL} ${CONTENT_GIT_DIR}
    else
        echo "Content dir: ${CONTENT_GIT_DIR} exists. Skipped clone."
        if [ -z "${CONTENT_REPO_SKIP_PULL}"]; then        
            echo "Doing pull..."
            (cd ${CONTENT_GIT_DIR}; git pull)
        fi
    fi
    cd ${CONTENT_GIT_DIR}
    if [[ "$CONTENT_BRANCH" != "master" ]] && (git branch -a | grep "remotes/origin/${CONTENT_BRANCH}$"); then
        echo "found remote branch: '$CONTENT_BRANCH' will use it for generating docs"
        git checkout $CONTENT_BRANCH
    else
        if [[ "${REQUIRE_BRANCH}" == "true" ]]; then
            echo "ERROR: couldn't find $CONTENT_BRANCH on remote. Aborting..."
            exit 2
        fi
        echo "Using content master to generate build"
        CONTENT_BRANCH=master
        git checkout master
        # you can use an old hash to try to see if bulid passes when there is a failure.
        # git checkout b11f4cfe4a3bf567656ef021f3d8f1bf66bcb9f6
    fi
    echo "Git log:"
    git --no-pager log -1 --no-decorate --no-color | head -10
fi

echo "Content git dir [${CONTENT_GIT_DIR}] size: $(du -sh ${CONTENT_GIT_DIR})"

cd ${SCRIPT_DIR}

if [[ ( "$PULL_REQUEST" == "true" || -n "$CI_PULL_REQUEST" ) && "$CONTENT_BRANCH" == "master" ]]; then
    echo "Checking if only doc files where modified and we can do a limited preview build..."
    if [ -n "$CIRCLE_COMPARE_URL" ]; then
        DIFF_COMPARE=$(echo "$CIRCLE_COMPARE_URL" | sed 's:^.*/compare/::g')    
        if [ -z "${DIFF_COMPARE}" ]; then
            echo "Failed: extracting diff compare from CIRCLE_COMPARE_URL: ${CIRCLE_COMPARE_URL}"            
        else
            DIFF_FILES=$(git diff --name-only $DIFF_COMPARE --)
        fi
    fi
    if [[ -z "$DIFF_FILES" && -z "$CONTENT_DOC_NO_FETCH" ]]; then
        git remote get-url origin || git remote add origin https://github.com/demisto/content-docs.git
        git remote -v
        git fetch origin
        echo "HEAD ref $(git rev-parse HEAD). remotes/origin/master ref: $(git rev-parse remotes/origin/master)"
        DIFF_FILES=$(git diff --name-only  remotes/origin/master...HEAD --)  # so we fail on errors if there is a problem
    fi
    echo -e "Modified files:\n$DIFF_FILES\n-----------"    
    echo "$DIFF_FILES" | grep -v -E '^docs/|^content-repo/extra-docs/|^static/|^sidebars.js' || MAX_FILES=20    
    if [ -n "$MAX_FILES" ]; then
        echo "MAX_FILES set to: $MAX_FILES"
        export MAX_FILES
    fi

    echo "$DIFF_FILES" | grep -v -E '^src/pages/marketplace/|^genMarketplace.js|^plopfile.js|^static/|^sidebars.js' || MAX_PACKS=20
    if [ -n "MAX_PACKS" ]; then
        echo "MAX_PACKS set to: $MAX_PACKS"
        export MAX_PACKS
    fi
fi

BUCKET_DIR="${SCRIPT_DIR}/.content-bucket"
if  [[ ! -d "$BUCKET_DIR" ]]; then
    echo "Copying bucket docs content to: $BUCKET_DIR"
    mkdir "${BUCKET_DIR}"
    gsutil -m cp -r gs://marketplace-dist/content/docs/Packs/ "${BUCKET_DIR}"
else
    echo "Skipping copying bucket data as dir: $BUCKET_DIR already exists"
    echo "If you want to re-copy, delete the dir: $BUCKET_DIR"
fi

TARGET_DIR=${SCRIPT_DIR}/../docs/reference
REL_IMGS_DIR=${SCRIPT_DIR}/../docs/doc_imgs/reference/relative
echo "Deleting and creating dirs: ${TARGET_DIR} and ${REL_IMGS_DIR}"
rm -rf ${TARGET_DIR}/integrations
rm -rf ${TARGET_DIR}/playbooks
rm -rf ${TARGET_DIR}/scripts
rm -rf ${REL_IMGS_DIR}
mkdir ${TARGET_DIR}/integrations
mkdir ${TARGET_DIR}/playbooks
mkdir ${TARGET_DIR}/scripts
mkdir ${REL_IMGS_DIR}

echo "Copying CommonServerPython.py, demistomock.py, approved_tags.json and approved_usecases.json"
cp ${CONTENT_GIT_DIR}/Packs/Base/Scripts/CommonServerPython/CommonServerPython.py .
cp ${CONTENT_GIT_DIR}/Tests/demistomock/demistomock.py .
cp ${CONTENT_GIT_DIR}/Tests/Marketplace/approved_tags.json .
cp ${CONTENT_GIT_DIR}/Tests/Marketplace/approved_usecases.json .

ARTICLES_DIR=${SCRIPT_DIR}/extra-docs/articles
DEMISTO_CLASS_OVERVIEW="All Python integrations and scripts have available as part of the runtime the \`demisto\` class object. The object exposes a series of API methods which are used to retrieve and send data to the Cortex XSOAR Server.

:::note
The \`demisto\` class is a low level API. For many operations we provide a simpler and more robust API as part of the  [Common Server Functions](https://xsoar.pan.dev/docs/integrations/code-conventions#common-server-functions).
:::"
DEMISTO_CLASS_DOCS_CMD=("./gen_pydocs.py" "-d" "${ARTICLES_DIR}" "-i" "demisto-class" "-t" "'Demisto Class'" "-m" "demisto" "-p" "demisto." "-o" "'${DEMISTO_CLASS_OVERVIEW}'")
mv demistomock.py demisto.py

if [ -z "${NETLIFY}" ]; then
    echo "Not running in netlify. Using pipenv"
    echo "Installing pipenv..."
    pipenv install
    echo "Generating Demisto class docs..."
    pipenv run "${DEMISTO_CLASS_DOCS_CMD[@]}"
    mv demisto.py demistomock.py
    echo "Generating docs..."
    pipenv run ./gendocs.py -t "${TARGET_DIR}" -d "${CONTENT_GIT_DIR}"
else
    echo "Generating Demisto class docs..."
    eval "${DEMISTO_CLASS_DOCS_CMD[@]}"
    mv demisto.py demistomock.py
    echo "Generating docs..."
    ./gendocs.py -t "${TARGET_DIR}" -d "${CONTENT_GIT_DIR}"
fi
