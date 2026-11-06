#!/usr/bin/env python3
"""Dynamic iSCSI PVs from an ASUSTOR NAS, attached by democratic-csi node-manual.

Every volume gets its own target holding a single LUN. ADM derives LUN numbers
from position when it rebuilds SCST at boot, so a shared target could renumber
its LUNs and attach a PV to the wrong disk. A lone LUN is always 0.

Reconciles by polling and derives all names from the PVC UID, so a crash at any
point is repaired by the next pass.
"""
import hashlib
import http.client
import json
import logging
import math
import os
import ssl
import time
import urllib.parse

PROVISIONER = "iscsi.asustor.homelab"
ANNOTATION = "pv.kubernetes.io/provisioned-by"
DRIVER = "org.democratic-csi.node-manual"
SINGLE_NODE_MODES = {"ReadWriteOnce", "ReadWriteOncePod"}
MASK_READWRITE, MASK_DENY = "0", "2"
UNITS = {
    "": 1, "k": 10**3, "M": 10**6, "G": 10**9, "T": 10**12,
    "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40,
}

log = logging.getLogger("asustor-provisioner")


def to_gib(quantity):
    """Round a Kubernetes quantity up to whole GiB, the unit LUNs are sized in."""
    number = quantity.rstrip("kKMGTi")
    return max(1, math.ceil(float(number) * UNITS[quantity[len(number):]] / 2**30))


def volume_name(uid):
    """ADM limits target names to 31 characters, too short for a whole UID."""
    return "pvc-" + uid.replace("-", "")[:24]


class Nas:
    """ADM's iscsi.cgi: the only route that keeps iscsi.conf, the UI and SCST in step."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.sid = None

    def _post(self, path, query, form):
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE  # self-signed: pinned below instead
        conn = http.client.HTTPSConnection(self.cfg["nas_host"], 8001, context=context, timeout=90)
        try:
            conn.connect()
            seen = hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest()
            if seen != self.cfg["nas_fingerprint"]:
                raise RuntimeError(f"NAS certificate fingerprint mismatch: {seen}")
            conn.request(
                "POST",
                f"/portal/apis/{path}?{urllib.parse.urlencode(query)}",
                urllib.parse.urlencode(form),
                {"Content-Type": "application/x-www-form-urlencoded"},
            )
            body = json.loads(conn.getresponse().read())
        finally:
            conn.close()
        if not body.get("success"):
            raise RuntimeError(f"ADM {query.get('act')} {query.get('tab', '')} failed: "
                               f"{ {k: v for k, v in body.items() if k != 'sid'} }")
        return body

    def __enter__(self):
        self.sid = self._post("login.cgi", {"act": "login"}, {
            "account": self.cfg["nas_user"],
            "password": self.cfg["nas_password"],
            "two-step-auth": "true",
        })["sid"]
        return self

    def __exit__(self, *_):
        try:
            self._post("login.cgi", {"act": "logout", "sid": self.sid}, {})
        except Exception as err:  # the session just expires on its own
            log.warning("logout failed: %s", err)

    def _iscsi(self, act, tab, query=None, **form):
        params = {"sid": self.sid, "act": act, "tab": tab, **(query or {})}
        return self._post("storageManager/iscsi.cgi", params, form)

    def iqn(self, name):
        return f"{self.cfg['iqn_prefix']}.{name}"

    def _target(self, name):
        targets = self._iscsi("list", "target").get("targets", [])
        return next((t for t in targets if t["target"] == name), None)

    def create(self, name, gib):
        if self._target(name) is None:
            self._iscsi(
                "add", "target_lun",
                target=name, iqn=self.iqn(name), header=0, data=0,
                chaptype=1, chapname=self.cfg["chap_user"], chappass=self.cfg["chap_password"],
                mname="", mpass="",
                luntype=0, lun=name, volume=self.cfg["nas_volume"],
                provisioning=1, indexed=0, size=gib * 1024,
            )
        # Masking a target with no LUN is ignored yet reports success, and writes
        # garbage sections into iscsi.conf. Never attempt it.
        target = self._target(name)
        if target is None or int(target["lun"]) != 1:
            raise RuntimeError(f"target {name} has no single LUN, needs manual cleanup: {target}")
        self._iscsi(
            "set", "mask", {"target": self.iqn(name)},
            readwrite=",".join(self.cfg["initiators"]), readonly="", deny="default", nomask="",
        )
        # success above proves nothing, so read back what was really applied
        masks = {m["name"]: m["mask"] for m in self._iscsi("get", "mask", {"target": self.iqn(name)})["masks"]}
        expected = {"default": MASK_DENY, **{i: MASK_READWRITE for i in self.cfg["initiators"]}}
        if masks != expected:
            raise RuntimeError(f"target {name} mask not applied: {masks}")

    def delete(self, name):
        if self._target(name) is None:
            return True
        if self._iscsi("get", "target", {"target": self.iqn(name)}).get("hosts"):
            return False
        self._iscsi("delete", "target_lun", {"target": self.iqn(name), "lun": name})
        return True


class Kube:
    def __init__(self):
        sa = "/var/run/secrets/kubernetes.io/serviceaccount"
        self.token_path = f"{sa}/token"
        self.context = ssl.create_default_context(cafile=f"{sa}/ca.crt")
        self.host = os.environ["KUBERNETES_SERVICE_HOST"]
        self.port = int(os.environ["KUBERNETES_SERVICE_PORT"])

    def request(self, method, path, body=None):
        with open(self.token_path) as f:  # rotated by the kubelet
            token = f.read()
        conn = http.client.HTTPSConnection(self.host, self.port, context=self.context, timeout=30)
        try:
            conn.request(method, path, json.dumps(body) if body else None, {
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            })
            response = conn.getresponse()
            data = response.read()
        finally:
            conn.close()
        if response.status == 404 and method == "DELETE":
            return {}
        if response.status >= 400:
            raise RuntimeError(f"{method} {path}: {response.status} {data[:300]!r}")
        return json.loads(data)

    def items(self, path):
        return self.request("GET", path)["items"]


def build_pv(cfg, pvc, storage_class, name, gib):
    return {
        "apiVersion": "v1",
        "kind": "PersistentVolume",
        "metadata": {"name": f"pvc-{pvc['metadata']['uid']}", "annotations": {ANNOTATION: PROVISIONER}},
        "spec": {
            "capacity": {"storage": f"{gib}Gi"},
            "accessModes": pvc["spec"]["accessModes"],
            "persistentVolumeReclaimPolicy": storage_class.get("reclaimPolicy", "Delete"),
            "storageClassName": storage_class["metadata"]["name"],
            "volumeMode": pvc["spec"].get("volumeMode", "Filesystem"),
            "claimRef": {
                "apiVersion": "v1",
                "kind": "PersistentVolumeClaim",
                "namespace": pvc["metadata"]["namespace"],
                "name": pvc["metadata"]["name"],
                "uid": pvc["metadata"]["uid"],
            },
            "csi": {
                "driver": DRIVER,
                "fsType": storage_class.get("parameters", {}).get("fsType", "ext4"),
                "volumeHandle": name,
                "nodeStageSecretRef": {"name": cfg["chap_secret"], "namespace": cfg["chap_secret_namespace"]},
                "volumeAttributes": {
                    "portal": f"{cfg['nas_host']}:3260",
                    "iqn": f"{cfg['iqn_prefix']}.{name}",
                    "lun": "0",
                    "node_attach_driver": "iscsi",
                    "provisioner_driver": "node-manual",
                },
            },
        },
    }


def warn(kube, pvc, message, warned):
    """Surface a refusal in `kubectl describe pvc`, once per PVC and message."""
    key = (pvc["metadata"]["uid"], message)
    log.warning("%s/%s: %s", pvc["metadata"]["namespace"], pvc["metadata"]["name"], message)
    if key in warned:
        return
    warned.add(key)
    namespace = pvc["metadata"]["namespace"]
    kube.request("POST", f"/api/v1/namespaces/{namespace}/events", {
        "metadata": {"generateName": "asustor-provisioner-", "namespace": namespace},
        "involvedObject": {
            "kind": "PersistentVolumeClaim",
            "namespace": namespace,
            "name": pvc["metadata"]["name"],
            "uid": pvc["metadata"]["uid"],
        },
        "reason": "ProvisioningRefused",
        "message": message,
        "type": "Warning",
        "source": {"component": PROVISIONER},
    })


def reconcile(kube, nas, cfg, warned):
    classes = {
        sc["metadata"]["name"]: sc
        for sc in kube.items("/apis/storage.k8s.io/v1/storageclasses")
        if sc.get("provisioner") == PROVISIONER
    }
    ours = [
        pv for pv in kube.items("/api/v1/persistentvolumes")
        if pv["metadata"].get("annotations", {}).get(ANNOTATION) == PROVISIONER
    ]
    names = {pv["metadata"]["name"] for pv in ours}
    pending = [
        pvc for pvc in kube.items("/api/v1/persistentvolumeclaims")
        if pvc["spec"].get("storageClassName") in classes
        and pvc.get("status", {}).get("phase") == "Pending"
        and not pvc["spec"].get("volumeName")
        and "deletionTimestamp" not in pvc["metadata"]
        and f"pvc-{pvc['metadata']['uid']}" not in names
    ]
    released = [
        pv for pv in ours
        if pv.get("status", {}).get("phase") == "Released"
        and pv["spec"]["persistentVolumeReclaimPolicy"] == "Delete"
    ]
    if not pending and not released:
        return

    with nas as session:
        for pv in released:
            name = pv["spec"]["csi"]["volumeHandle"]
            if session.delete(name):
                kube.request("DELETE", f"/api/v1/persistentvolumes/{pv['metadata']['name']}")
                ours.remove(pv)
                log.info("deleted %s", name)
            else:
                log.info("%s still has a connected host, retrying", name)

        used = sum(to_gib(pv["spec"]["capacity"]["storage"]) for pv in ours)
        for pvc in pending:
            gib = to_gib(pvc["spec"]["resources"]["requests"]["storage"])
            if not set(pvc["spec"]["accessModes"]) <= SINGLE_NODE_MODES:
                warn(kube, pvc, "only ReadWriteOnce and ReadWriteOncePod are supported", warned)
            elif used + gib > cfg["cap_gib"]:
                warn(kube, pvc, f"{gib}Gi would exceed the {cfg['cap_gib']}Gi cap ({used}Gi in use)", warned)
            else:
                name = volume_name(pvc["metadata"]["uid"])
                session.create(name, gib)
                kube.request("POST", "/api/v1/persistentvolumes",
                             build_pv(cfg, pvc, classes[pvc["spec"]["storageClassName"]], name, gib))
                used += gib
                log.info("provisioned %s for %s/%s (%sGi)", name,
                         pvc["metadata"]["namespace"], pvc["metadata"]["name"], gib)


def load_config():
    env = os.environ
    return {
        "nas_host": env["NAS_HOST"],
        "nas_fingerprint": env["NAS_FINGERPRINT"].replace(":", "").lower(),
        "nas_user": env["NAS_USER"],
        "nas_password": env["NAS_PASSWORD"],
        "nas_volume": env.get("NAS_VOLUME", "volume1"),
        "iqn_prefix": env["IQN_PREFIX"],
        "initiators": env["INITIATORS"].split(","),
        "chap_user": env["CHAP_USER"],
        "chap_password": env["CHAP_PASSWORD"],
        "chap_secret": env["CHAP_SECRET"],
        "chap_secret_namespace": env["CHAP_SECRET_NAMESPACE"],
        "cap_gib": int(env["CAP_GIB"]),
    }


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    cfg, kube, warned = load_config(), Kube(), set()
    nas = Nas(cfg)
    log.info("started, cap %sGi", cfg["cap_gib"])
    while True:
        try:
            reconcile(kube, nas, cfg, warned)
        except Exception as err:
            log.error("reconcile failed: %s", err)
        time.sleep(int(os.environ.get("INTERVAL_SECONDS", "15")))


if __name__ == "__main__":
    main()
