FROM node:12-alpine3.15
LABEL "repository"="https://github.com/Cavaler/github-tag-action"
LABEL "homepage"="https://github.com/Cavaler/github-tag-action"
LABEL "maintainer"="Pavel Kostromitinov"

COPY entrypoint.sh /entrypoint.sh

RUN apk update && apk add bash git curl jq && npm install -g semver

ENTRYPOINT ["/entrypoint.sh"]
