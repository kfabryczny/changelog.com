SHELL := bash# we want bash behaviour in all shell invocations

RED := $(shell tput setaf 1)
GREEN := $(shell tput setaf 2)
YELLOW := $(shell tput setaf 3)
BOLD := $(shell tput bold)
NORMAL := $(shell tput sgr0)

PLATFORM := $(shell uname)
ifneq ($(PLATFORM),Darwin)
ifneq ($(PLATFORM),Linux)
  $(warning $(RED)$(PLATFORM) is not supported$(NORMAL), only macOS and Linux are supported.)
  $(error $(BOLD)Please contribute support for your platform.$(NORMAL))
endif
endif

ifneq (4,$(firstword $(sort $(MAKE_VERSION) 4)))
  $(warning $(BOLD)$(RED)GNU Make v4 or newer is required$(NORMAL))
ifeq ($(PLATFORM),Darwin)
  $(info On macOS it can be installed with $(BOLD)brew install make$(NORMAL) and run as $(BOLD)gmake$(NORMAL))
endif
  $(error Please run with GNU Make v4 or newer)
endif

### VARS ###
#
export LC_ALL := en_US.UTF-8
export LANG := en_US.UTF-8

export BUILD_VERSION ?= $(shell date -u +'%Y-%m-%d.%H%M%S')

DOCKER_HOST ?= 2019.changelog.com
DOCKER_HOST_SSH_USER ?= core

### DEPS ###
#
CURL := /usr/bin/curl
DOCKER := $(firstword $(wildcard /usr/bin/docker /usr/local/bin/docker))
JQ := $(firstword $(wildcard /usr/bin/jq /usr/local/bin/jq))
LPASS := $(firstword $(wildcard /usr/bin/lpass /usr/local/bin/lpass))
TERRAFORM := $(firstword $(wildcard /usr/bin/terraform /usr/local/bin/terraform))

ifeq ($(PLATFORM),Darwin)
CASK := brew cask

$(DOCKER):
	@$(CASK) install docker

COMPOSE := $(DOCKER)-compose
$(COMPOSE):
	@[ -f $(COMPOSE) ] || (\
	  echo "Please install Docker via $(BOLD)brew cask docker$(NORMAL) so that $(BOLD)docker-compose$(NORMAL) will be managed in lock-step with Docker" && \
	  exit 1 \
	)

$(JQ):
	@brew install jq

$(LPASS):
	@brew install lastpass-cli

$(TERRAFORM):
	@brew install terraform
endif

ifeq ($(PLATFORM),Linux)
$(DOCKER):
	$(error $(RED)Please install $(BOLD)docker$(NORMAL))

COMPOSE := $(DOCKER)-compose
$(COMPOSE):
	$(error $(RED)Please install $(BOLD)docker-compose$(NORMAL))

$(JQ):
	$(error $(RED)Please install $(BOLD)jq$(NORMAL))

$(LPASS):
	$(error $(RED)Please install $(BOLD)lastpass$(NORMAL))

$(TERRAFORM):
	$(error $(RED)Please install $(BOLD)terraform$(NORMAL))
endif

$(CURL):
	$(error $(RED)Please install $(BOLD)curl$(NORMAL))

SECRETS := $(LPASS) ls "Shared-changelog/secrets"

TF := cd terraform && $(TERRAFORM)

### TARGETS ###
#
.DEFAULT_GOAL := help

.PHONY: add-secret
add-secret: $(LPASS) ## as  | Add secret to LastPass
ifndef SECRET
	@echo "$(RED)SECRET$(NORMAL) environment variable must be set to the name of the secret that will be added" && \
	echo "This value must be in upper-case, e.g. $(BOLD)SOME_SECRET$(NORMAL)" && \
	echo "This value must not match any of the existing secrets:" && \
	$(SECRETS) && \
	exit 1
endif
	@$(LPASS) add --notes "Shared-changelog/secrets/$(SECRET)"
.PHONY: as
as: add-secret

.PHONY: prevent-incompatible-deps-reaching-the-docker-image
prevent-incompatible-deps-reaching-the-docker-image:
	@rm -fr deps

.PHONY: build
build: $(COMPOSE) prevent-incompatible-deps-reaching-the-docker-image ## b   | Build changelog.com app container
	@$(COMPOSE) build
.PHONY: b
b: build

SEPARATOR := ----------------------------------------------------------------------------------
.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:+.*?## .*$$' $(MAKEFILE_LIST) | \
	awk 'BEGIN { FS = "[:#]" } ; { printf "$(SEPARATOR)\n\033[36m%-22s\033[0m %s\n", $$1, $$4 }' ; \
	echo $(SEPARATOR)

.PHONY: clean-docker
clean-docker: $(DOCKER) ## cd  | Clean all changelog artefacts from Docker
	@$(DOCKER) volume ls | awk '/changelog/ { system("$(DOCKER) volume rm " $$2) }' ; \
	$(DOCKER) images | awk '/changelog/ { system("$(DOCKER) image rm " $$1 ":" $$2) }'
.PHONY: cd
cd: clean-docker

.PHONY: configure-ci-secrets
configure-ci-secrets: $(LPASS) $(JQ) $(CURL) circle_token ## ccs | Configure CircleCI secrets
	@DOCKER_CREDENTIALS=$$($(LPASS) show --json 2219952586317097429) && \
	DOCKER_USER="$$($(JQ) --compact-output '.[] | {name: "DOCKER_USER", value: .username}' <<< $$DOCKER_CREDENTIALS)" && \
	DOCKER_PASS="$$($(JQ) --compact-output '.[] | {name: "DOCKER_PASS", value: .password}' <<< $$DOCKER_CREDENTIALS)" && \
	$(CURL) --silent --fail --request POST --header "Content-Type: application/json" -d "$$DOCKER_USER" "https://circleci.com/api/v1.1/project/github/thechangelog/changelog.com/envvar?circle-token=$(CIRCLE_TOKEN)" && \
	$(CURL) --silent --fail --request POST --header "Content-Type: application/json" -d "$$DOCKER_PASS" "https://circleci.com/api/v1.1/project/github/thechangelog/changelog.com/envvar?circle-token=$(CIRCLE_TOKEN)"
.PHONY: ccs
ccs: configure-ci-secrets

.PHONY: contrib
contrib: $(COMPOSE) prevent-incompatible-deps-reaching-the-docker-image ## c   | Contribute to changelog.com by running a local copy
	@bash -c "trap '$(COMPOSE) down' INT ; \
	  $(COMPOSE) up ; \
	  [[ $$? =~ 0|2 ]] || \
	    ( echo 'You might want to run $(BOLD)make build contrib$(NORMAL) if app dependencies have changed' && exit 1 )"
.PHONY: c
c: contrib

.PHONY: create-docker-secrets
create-docker-secrets: $(LPASS) ## cds | Create Docker secrets
	@$(SECRETS) | \
	awk '! /secrets\/? / { print($$1) }' | \
	while read -r secret ; do \
	  export secret_key="$$($(LPASS) show --name $$secret)" ; \
	  export secret_value="$$($(LPASS) show --notes $$secret)" ; \
	  echo "Creating $(BOLD)$(YELLOW)$$secret_key$(NORMAL) Docker secret..." ; \
	  echo "Prevent ssh from hijacking stdin: https://github.com/koalaman/shellcheck/wiki/SC2095" > /dev/null ; \
	  ssh $(DOCKER_HOST_SSH_USER)@$(DOCKER_HOST) "echo $$secret_value | docker secret create $$secret_key - || true" < /dev/null || exit 1 ; \
	done && \
	echo "$(BOLD)$(GREEN)All secrets are now setup as Docker secrets$(NORMAL)" && \
	echo "A Docker secret cannot be modified - it can only be removed and created again, with a different value" && \
	echo "A Docker secret can only be removed if it is not bound to a Docker service" && \
	echo "It might be easier to define a new secret, e.g. $(BOLD)ALGOLIA_API_KEY2$(NORMAL)"
.PHONY: cds
cds: create-docker-secrets

.PHONY: remove-docker-secrets
remove-docker-secrets: $(LPASS)
	@ssh $(DOCKER_HOST_SSH_USER)@$(DOCKER_HOST) "docker secret ls | awk '/ago/ { system(\"docker secret rm \" \$$1) }'"
.PHONY: rds
rds: remove-docker-secrets

.PHONY: env-secrets
env-secrets: postgres campaignmonitor github aws twitter app slack rollbar buffer coveralls algolia ## es  | Print secrets stored in LastPass as env vars
.PHONY: es
es: env-secrets

.PHONY: iaas
iaas: linode_token dnsimple_creds init validate apply ## i   | Provision IaaS infrastructure
.PHONY: i
i: iaas

.PHONY: init
init: $(TERRAFORM)
	@$(TF) init

.PHONY: validate
validate: $(TERRAFORM)
	@$(TF) validate

.PHONY: plan
plan: $(TERRAFORM)
	@$(TF) plan

.PHONY: apply
apply: $(TERRAFORM)
	@$(TF) apply

.PHONY: markdown
markdown: $(DOCKER) ## md  | Preview Markdown as it will appear on GitHub
	@$(DOCKER) run --interactive --tty --rm --name changelog_md \
	  --volume $(CURDIR):/data \
	  --volume $(HOME)/.grip:/.grip \
	  --expose 5000 --publish 5000:5000 \
	  mbentley/grip --context=. 0.0.0.0:5000
.PHONY: md
md: markdown


.PHONY: legacy-assets
legacy-assets: $(DOCKER)
	@echo "$(YELLOW)This is a secret target that is only meant to be executed if legacy assets are present locally$(NORMAL)" && \
	echo "$(YELLOW)If this runs with an incorrect $(BOLD)./nginx/www/wp-content$(NORMAL)$(YELLOW), the resulting Docker image will miss relevant files$(NORMAL)" && \
	read -rp "Are you sure that you want to continue? (y|n) " -n 1 && ([[ $$REPLY =~ ^[Yy]$$ ]] || exit) && \
	cd nginx && $(DOCKER) build --tag thechangelog/legacy_assets . --file Dockerfile.legacy_assets && \
	$(DOCKER) push thechangelog/legacy_assets

.PHONY: proxy
proxy: build-proxy publish-proxy ## p   | Builds & publishes thechangelog/proxy Docker image
.PHONY: p
p: proxy

.PHONY: build-proxy
build-proxy: $(DOCKER)
	@cd nginx && \
	$(DOCKER) build --tag thechangelog/proxy:$(BUILD_VERSION) --tag thechangelog/proxy:latest .

.PHONY: publish-proxy
publish-proxy: $(DOCKER)
	@$(DOCKER) push thechangelog/proxy:$(BUILD_VERSION) && \
	$(DOCKER) push thechangelog/proxy:latest

.PHONY: runtime
runtime: build-runtime publish-runtime ## r   | Builds & publishes thechangelog/runtime Docker image
.PHONY: r
r: runtime

.PHONY: build-runtime
build-runtime: $(DOCKER)
	@$(DOCKER) build --tag thechangelog/runtime:$(BUILD_VERSION) --tag thechangelog/runtime:latest --file docker/Dockerfile.runtime .

.PHONY: publish-runtime
publish-runtime: $(DOCKER)
	$(DOCKER) push thechangelog/runtime:$(BUILD_VERSION) && \
	$(DOCKER) push thechangelog/runtime:latest

.PHONY: secrets
secrets: $(LPASS) ## s   | List all LastPass secrets
	@$(SECRETS)
.PHONY: s
s: secrets

.PHONY: ssh
ssh: ## ssh | SSH into 2019.changelog.com host
	@ssh $(DOCKER_HOST_SSH_USER)@$(DOCKER_HOST)

.PHONY: test
test: $(COMPOSE) ## t   | Runs tests as they run on CircleCI
	@$(COMPOSE) run --rm -e MIX_ENV=test -e DB_URL=ecto://postgres@db:5432/changelog_test app mix test
.PHONY: t
t: test

define DIRENV

We like $(BOLD)https://direnv.net/$(NORMAL) to manage environment variables.
This is an $(BOLD).envrc$(NORMAL) template that you can use as a starting point:

    PATH_add script

    export CIRCLE_TOKEN=
    export TF_VAR_linode_token=
    export DNSIMPLE_ACCOUNT=
    export DNSIMPLE_TOKEN=

endef
export DIRENV
.PHONY: circle_token
circle_token:
ifndef CIRCLE_TOKEN
	@echo "$(RED)CIRCLE_TOKEN$(NORMAL) environment variable must be set\n" && \
	echo "Learn more about CircleCI API tokens $(BOLD)https://circleci.com/docs/2.0/managing-api-tokens/$(NORMAL) " && \
	echo "$$DIRENV" && \
	exit 1
endif

.PHONY: linode_token
linode_token:
ifndef TF_VAR_linode_token
	@echo "$(RED)TF_VAR_linode_token$(NORMAL) environment variable must be set" && \
	echo "Learn more about Linode API tokens $(BOLD)https://cloud.linode.com/profile/tokens$(NORMAL) " && \
	echo "$$DIRENV" && \
	exit 1
endif

.PHONY: dnsimple_creds
dnsimple_creds:
ifndef DNSIMPLE_ACCOUNT
	@echo "$(RED)DNSIMPLE_ACCOUNT$(NORMAL) environment variable must be set" && \
	echo "This will be the account's numerical ID, e.g. $(BOLD)00000$(NORMAL)" && \
	echo "$$DIRENV" && \
	exit 1
endif
ifndef DNSIMPLE_TOKEN
	@echo "$(RED)DNSIMPLE_TOKEN$(NORMAL) environment variable must be set" && \
	echo "Get a DNSimple user access token $(BOLD)https://dnsimple.com/user?account_id=$(DNSIMPLE_ACCOUNT)$(NORMAL) " && \
	echo "$$DIRENV" && \
	exit 1
endif

.PHONY: sync-secrets
sync-secrets: $(LPASS)
	@$(LPASS) sync

.PHONY: postgres
postgres: $(LPASS)
	@echo "export PG_DOTCOM_PASS=$$($(LPASS) show --notes 7298637973371173308)"
.PHONY: campaignmonitor
campaignmonitor: $(LPASS)
	@echo "export CM_SMTP_TOKEN=$$($(LPASS) show --notes 4518157498237793892)" && \
	echo "export CM_API_TOKEN=$$($(LPASS) show --notes 2172742429466797248)"
.PHONY: github
github: $(LPASS)
	@echo "export GITHUB_CLIENT_ID=$$($(LPASS) show --notes 6311620502443842879)" && \
	echo "export GITHUB_CLIENT_SECRET=$$($(LPASS) show --notes 6962532309857955032)" && \
	echo "export GITHUB_API_TOKEN=$$($(LPASS) show --notes 5059892376198418454)"
.PHONY: aws
aws: $(LPASS)
	@echo "export AWS_ACCESS_KEY_ID=$$($(LPASS) show --notes 5523519094417729320)" && \
	echo "export AWS_SECRET_ACCESS_KEY=$$($(LPASS) show --notes 1520570655547620905)"
.PHONY: twitter
twitter: $(LPASS)
	@echo "export TWITTER_CONSUMER_KEY=$$($(LPASS) show --notes 1932439368993537002)" && \
	echo "export TWITTER_CONSUMER_SECRET=$$($(LPASS) show --notes 5671723614506961548)"
.PHONY: app
app: $(LPASS)
	@echo "export SECRET_KEY_BASE=$$($(LPASS) show --notes 7272253808960291967)" && \
	echo "export SIGNING_SALT=$$($(LPASS) show --notes 8954230056631744101)"
.PHONY: slack
slack: $(LPASS)
	@echo "export SLACK_INVITE_API_TOKEN=$$($(LPASS) show --notes 3107315517561229870)" && \
	echo "export SLACK_APP_API_TOKEN=$$($(LPASS) show --notes 1152178239154303913)"
.PHONY: rollbar
rollbar: $(LPASS)
	@echo "export ROLLBAR_ACCESS_TOKEN=$$($(LPASS) show --notes 5433360937426957091)"
.PHONY: buffer
buffer: $(LPASS)
	@echo "export BUFFER_TOKEN=$$($(LPASS) show --notes 4791620911166920938)"
.PHONY: coveralls
coveralls: $(LPASS)
	@echo "export COVERALLS_REPO_TOKEN=$$($(LPASS) show --notes 8654919576068551356)"
.PHONY: algolia
algolia: $(LPASS)
	@echo "export ALGOLIA_APPLICATION_ID=$$($(LPASS) show --notes 5418916921816895235)" && \
	echo "export ALGOLIA_API_KEY=$$($(LPASS) show --notes 1668162557359149736)"
