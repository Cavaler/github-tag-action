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
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tVERBOSE: ${verbose}"

current_branch=$(git rev-parse --abbrev-ref HEAD)

# fetch tags
git fetch --tags
    
tagFmt="^$prefix([0-9]+\.[0-9]+\.[0-9]+)$"

# get latest tag that looks like a semver with prefix
case "$tag_context" in
    *repo*) 
        tag="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "$tagFmt" | head -n 1)"
        if [ ! -z "$tag" ]
        then
            tagver="$(echo $tag | sed -n -r "s/$tagFmt/\1/p")"
            echo Tag: $tag ver: $tagver
        else
            echo No tag found
        fi
        ;;
    *branch*) 
        tag="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "$tagFmt" | head -n 1)"
        if [ ! -z "$tag" ]
        then
            tagver="$(echo $tag | sed -n -r "s/$tagFmt/\1/p")"
            echo Tag: $tag ver: $tagver
        else
            echo No tag found
        fi
        ;;
    * ) echo "Unrecognised context"; exit 1;;
esac


# if there are none, start tags at INITIAL_VERSION which defaults to 0.0.0
if [ -z "$tag" ]
then
    echo "Zero tag"
    log=$(git log --pretty='%B')
    tagver="$initial_version"
else
    log=$(git log $tag..HEAD --pretty='%B')
    # get current commit hash for tag
    tag_commit=$(git rev-list -n 1 $tag)
    echo "Tag is $tag at $tag_commit"
fi

# get current commit hash
commit=$(git rev-parse HEAD)

if [ "$tag_commit" == "$commit" ]; then
    echo "No new commits since previous tag. Skipping..."
    echo ::set-output name=tag::$tag
    exit 0
fi

# echo log if verbose is wanted
if $verbose
then
  echo $log
fi

case "$log" in
    *#major* ) new=$(semver -i major $tagver); part="major";;
    *#minor* ) new=$(semver -i minor $tagver); part="minor";;
    *#patch* ) new=$(semver -i patch $tagver); part="patch";;
    *#none* ) 
        echo "Default bump was set to none. Skipping..."; echo ::set-output name=new_tag::$tag; echo ::set-output name=tag::$tag; exit 0;;
    * ) 
        if [ "$default_semvar_bump" == "none" ]; then
            echo "Default bump was set to none. Skipping..."; echo ::set-output name=new_tag::$tag; echo ::set-output name=tag::$tag; exit 0 
        else 
            new=$(semver -i "${default_semvar_bump}" $tagver); part=$default_semvar_bump 
        fi 
        ;;
esac

echo $part

new="$prefix$new"

if [ ! -z $custom_tag ]
then
    new="$custom_tag"
fi

echo -e "Bumping tag ${tag}. New tag ${new}"

# set outputs
echo ::set-output name=new_tag::$new
echo ::set-output name=part::$part

# use dry run to determine the next tag
if $dryrun
then
    echo ::set-output name=tag::$tag
    exit 0
fi 

echo ::set-output name=tag::$new

# create local git tag
git tag $new

# push new tag ref to github
dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
full_name=$GITHUB_REPOSITORY
git_refs_url=$(jq .repository.git_refs_url $GITHUB_EVENT_PATH | tr -d '"' | sed 's/{\/sha}//g')

echo "$dt: **pushing tag $new to repo $full_name"

git_refs_response=$(
curl -s -X POST $git_refs_url \
-H "Authorization: token $GITHUB_TOKEN" \
-d @- << EOF

{
  "ref": "refs/tags/$new",
  "sha": "$commit"
}
EOF
)

git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

echo "::debug::${git_refs_response}"
if [ "${git_ref_posted}" = "refs/tags/${new}" ]; then
  exit 0
else
  echo "::error::Tag was not created properly."
  exit 1
fi
