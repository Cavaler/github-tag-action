#!/bin/bash

set -o pipefail

# config
default_semvar_bump=${DEFAULT_BUMP:-minor}
with_v=${WITH_V:-false}
prefix=${PREFIX:-}
custom_tag=${CUSTOM_TAG}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
initial_version=${INITIAL_VERSION:-0.0.0}
bump_on_initial=${BUMP_ON_INITIAL:-true}
tag_context=${TAG_CONTEXT:-repo}
verbose=${VERBOSE:-true}
# since https://github.blog/2022-04-12-git-security-vulnerability-announced/ runner uses?
git config --global --add safe.directory /github/workspace

cd ${GITHUB_WORKSPACE}/${source}

# prefix with 'v'
if $with_v
then
	prefix="v$prefix"
fi

echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tPREFIX: ${prefix}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tBUMP_ON_INITIAL: ${bump_on_initial}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tVERBOSE: ${verbose}"

setOutput() {
    echo "${1}=${2}" >> "${GITHUB_OUTPUT}"
}

current_branch=$(git rev-parse --abbrev-ref HEAD)

# fetch tags
git fetch --tags
    
tagFmt="^$prefix([0-9]+\.[0-9]+\.[0-9]+)$"

# get latest tag that looks like a semver with prefix
case "$tag_context" in
    *repo*) 
        cur_tag="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "$tagFmt" | head -n 1)"
        if [ ! -z "$cur_tag" ]
        then
            cur_ver="$(echo $cur_tag | sed -n -r "s/$tagFmt/\1/p")"
            echo Tag: $cur_tag ver: $cur_ver
        else
            echo No tag found
        fi
        ;;
    *branch*) 
        cur_tag="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "$tagFmt" | head -n 1)"
        if [ ! -z "$cur_tag" ]
        then
            cur_ver="$(echo $cur_tag | sed -n -r "s/$tagFmt/\1/p")"
            echo Tag: $cur_tag ver: $cur_ver
        else
            echo No tag found
        fi
        ;;
    * ) echo "Unrecognised context"; exit 1;;
esac


# if there are none, start tags at INITIAL_VERSION which defaults to 0.0.0
if [ -z "$cur_tag" ]
then
    log=$(git log --pretty='%B')
    cur_ver="$initial_version"
    cur_tag="$prefix$cur_ver"
    if $bump_on_initial
    then
        echo "No tag found, setting version to $initial_version"
    else
        default_semvar_bump="none"
        echo "No tag found, setting version to $initial_version and no bump"
    fi
else
    log=$(git log $cur_tag..HEAD --pretty='%B')
    # get current commit hash for tag
    tag_commit=$(git rev-list -n 1 $cur_tag)
    echo "Tag is $cur_tag at $tag_commit"
fi

setOutput "cur_tag" "$cur_tag"
setOutput "cur_ver" "$cur_ver"

# get current commit hash
commit=$(git rev-parse HEAD)

if [ "$tag_commit" == "$commit" ]; then
    echo "No new commits since previous tag. Skipping..."
    setOutput "new_tag" "$cur_tag"
    setOutput "new_ver" "$cur_ver"
    exit 0
fi

# echo log if verbose is wanted
if $verbose
then
  echo $log
fi

case "$log" in
    *#major* ) new=$(semver -i major $cur_ver); part="major";;
    *#minor* ) new=$(semver -i minor $cur_ver); part="minor";;
    *#patch* ) new=$(semver -i patch $cur_ver); part="patch";;
    *#none* ) 
        echo "Default bump was set to none. Skipping..."
        setOutput "new_tag" "$cur_tag"
        setOutput "new_ver" "$cur_ver"
        exit 0
        ;;
    * ) 
        if [ "$default_semvar_bump" == "none" ]; then
            echo "Default bump was set to none. Skipping..."
            setOutput "new_tag" "$cur_tag"
            setOutput "new_ver" "$cur_ver"
            exit 0 
        else 
            new_ver=$(semver -i "${default_semvar_bump}" $cur_ver); part=$default_semvar_bump 
        fi 
        ;;
esac

new_tag="$prefix$new_ver"

if [ ! -z $custom_tag ]
then
    new_tag="$custom_tag"
fi

echo -e "Bumping tag ${cur_tag} with $part. New version ${new_ver}, tag ${new_tag}"

# set outputs
setOutput "new_ver" "$new_ver"
setOutput "new_tag" "$new_tag"
setOutput "part" "$part"

# use dry run to determine the next tag
if $dryrun
then
    exit 0
fi 

# create local git tag
git tag $new_tag

# push new tag ref to github
dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
full_name=$GITHUB_REPOSITORY
git_refs_url=$(jq .repository.git_refs_url $GITHUB_EVENT_PATH | tr -d '"' | sed 's/{\/sha}//g')

echo "$dt: **pushing tag $new_tag to repo $full_name"

git_refs_response=$(
curl -s -X POST $git_refs_url \
-H "Authorization: token $GITHUB_TOKEN" \
-d @- << EOF

{
  "ref": "refs/tags/$new_tag",
  "sha": "$commit"
}
EOF
)

git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

echo "::debug::${git_refs_response}"
if [ "${git_ref_posted}" = "refs/tags/${new_tag}" ]; then
  exit 0
else
  echo "::error::Tag was not created properly."
  exit 1
fi
