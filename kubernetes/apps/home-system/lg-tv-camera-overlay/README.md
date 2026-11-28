# lg-tv-camera-overlay (home-ops)

Runs the camera overlay watcher in the cluster. The TV app itself is a devmode
webOS package installed on the TV; see the source repo
`~/repos/homelab/lg-tv-camera-overlay`.

## What runs

- One Deployment in `home-system` running `scripts/watch.py`.
- It subscribes to `binary_sensor.camera_pippi_baby_crying` on Home Assistant.
- On a crying event: starts the internal frame proxy (port 9000), launches
  `org.local.camoverlay` on the TV with `http://192.168.0.61/frame.jpg`.
- After the event: keeps the overlay 60 s, then closes it and stops the proxy.
- The Service (LoadBalancer, `192.168.0.61`) exposes the frame proxy to the
  TV/LAN. Do not reuse `.59` — it is another device on the LAN.

## Secret (manual bootstrap)

The deployment expects `lg-tv-camera-overlay-secret` in `home-system`:

| Key | Content |
|---|---|
| `HA_TOKEN` | Home Assistant long-lived token (`lg-tv-camera-overlay`) |
| `tv-key` | SSH private key for `root@192.168.0.214` |

Bootstrap (never commit values):

```sh
kubectl -n home-system create secret generic lg-tv-camera-overlay-secret \
  --from-file=HA_TOKEN=/path/to/token.txt \
  --from-file=tv-key="$HOME/.ssh/lg-c2-tv"
```

Follow-up: move this to 1Password + an ExternalSecret (`onepassword-connect`),
like `home-system/frigate`, once `op` is available.

## Image

```sh
cd ~/repos/homelab/lg-tv-camera-overlay
docker buildx build --platform linux/amd64 \
  -t harbor.rbl.lol/library/lg-tv-camera-overlay:0.1.1 --push .
```

Update `tag` in `values.yaml` after each push.

## Notes

- The pod needs LAN access to the TV (SSH 22) and to Home Assistant
  (`home-assistant.home-system.svc.cluster.local:8123`).
- The watcher is always running (listening); the proxy/overlay only run during
  an event.
- The watcher also launches the interactive control app (`org.local.tvcontrol`)
  when `select.soggiorno_192_168_0_111_activity` is `Camera Pippi`. That activity
  exists on the hub (LG-only members, TV key bindings cloned from "Casa Apple
  TV"); starting it powers the TV on and opens the app, switching to another
  shared-LG activity keeps the TV on. See the app README for details.
- Logging: `LOG_LEVEL=INFO|DEBUG`; watcher and proxy log to the pod log
  (`kubectl -n home-system logs deploy/lg-tv-camera-overlay`).
- `luna` calls go through `ssh` (`TV_SSH_KEY`, `TV_SSH_PORT`).
