MT_REF  ?= $(shell grep -vE '^[[:space:]]*(#|$$)' MT_COMMIT | head -n1 | tr -d '[:space:]')
IMAGE   ?= mt-repro
LOCAL   ?= ../mt

.PHONY: verify smoke shell dev build-% clean

build-%:
	docker build --target $* --build-arg MT_REF=$(MT_REF) -t $(IMAGE):$* .

verify: build-verify
	docker run --rm $(IMAGE):verify

smoke: build-smoke
	mkdir -p model_cache out
	docker run --rm \
	  -v "$(CURDIR)/model_cache:/app/prog/model_cache" \
	  -v "$(CURDIR)/out:/app/prog/results/smoke" \
	  $(IMAGE):smoke python scripts/smoke_plan.py --sentences 5

shell: build-full
	docker run --rm -it \
	  -v "$(CURDIR)/model_cache:/app/prog/model_cache" \
	  $(IMAGE):full bash

dev: build-verify
	docker run --rm -v "$(abspath $(LOCAL)):/app" $(IMAGE):verify

clean:
	-docker rmi $(IMAGE):verify $(IMAGE):smoke $(IMAGE):full 2>/dev/null
	rm -rf out
