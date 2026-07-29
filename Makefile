.PHONY: keys prepare start stop test clean logs

keys:
	./scripts/generate-tsig-key.sh

prepare:
	./scripts/prepare.sh

start: prepare
	./scripts/start.sh

stop:
	./scripts/stop.sh

test:
	./mgmt-scripts/test.sh

clean:
	./mgmt-scripts/cleanup.sh -y

logs:
	podman logs -f $${CONTAINER_NAME:-dnsmasq-lab}
