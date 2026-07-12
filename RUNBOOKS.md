# BloomingEdge Run Books

## Distributed Poller Group Assignment

Purpose: prevent device status flapping between Triad and edge pollers.

### Group Policy

Use non-zero groups for edge sites.

* `0` = Triad/core only
* `1` = LOM edge site
* `2` = LOU edge site
* `3` = next edge site (choose and document site code)

Do not leave edge-only devices in group `0`.

### Configure Groups In Triad Console

Use the AWS Triad LibreNMS GUI to enforce single ownership per site/subnet.

1. Create site poller groups in the console:
	1) `1 = LOM`
	2) `2 = LOU`
	3) `3 = next site`
2. Keep `0` for Triad/core devices only.
3. For each edge device, open device edit settings and set `Poller Group` to the site's non-zero group.
4. Ensure the edge poller container at that site is deployed with the same group value (`SIDECAR_GROUP`).
5. Re-check that no edge subnet devices remain in group `0`.

Result: Triad and edge do not both ping/poll the same edge devices, which prevents status bouncing.

### Deploy Poller With Group

Menu wizard:

1. Run `bash scripts/edge-node-ops.sh`
2. Open `5) LibreNMS Poller Agent`
3. Select `2) Deploy/Re-Deploy Poller Agent`
4. Set `Poller group` to the site value (for example `1` for LOM)

Direct CLI:

```bash
bash scripts/edge-node-ops.sh poller-deploy --poller-group 1
```

Short form:

```bash
bash scripts/edge-node-ops.sh poller-deploy -g 2
```

### Verify Poller Group In Container

```bash
docker exec -it librenms-dispatcher-agent env | grep -E '^SIDECAR_GROUP='
```

Expected output example:

```text
SIDECAR_GROUP=1
```

### Validate Device Assignment On Triad DB

Run on Triad host:

```bash
docker exec -it triad-mariadb sh -lc 'ROOTPW="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}"; mariadb -uroot -p"$ROOTPW" librenms -e "SELECT device_id,hostname,poller_group,status,last_polled,last_ping FROM devices WHERE hostname=0x31302E302E31302E3331;"'
```

Replace the hostname hex value for other devices as needed.

### Troubleshooting: Up/Down Flapping

Symptom:

* Device status alternates Up/Down with different poller names in eventlog.

Cause:

* Device is in group `0` or overlapping group scope, and Triad plus edge pollers both write status.

Fix:

1. Move device to correct non-zero edge group.
2. Redeploy edge poller with matching `--poller-group` value.
3. Ensure Triad poller scope excludes that edge group.
4. Confirm eventlog shows checks from the site poller only (no alternating Triad poller name).
