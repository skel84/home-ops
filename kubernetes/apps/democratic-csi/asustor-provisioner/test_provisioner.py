#!/usr/bin/env python3
"""Run with: python3 test_provisioner.py"""
import provisioner as p

CFG = {
    "nas_host": "nas", "iqn_prefix": "iqn.test", "cap_gib": 10,
    "chap_secret": "chap", "chap_secret_namespace": "csi",
}


class FakeNas:
    def __init__(self, busy=()):
        self.created, self.deleted, self.busy = [], [], busy

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def create(self, name, gib):
        self.created.append((name, gib))

    def delete(self, name):
        if name in self.busy:
            return False
        self.deleted.append(name)
        return True


class FakeKube:
    def __init__(self, pvcs=(), pvs=()):
        self.pvcs, self.pvs, self.calls = list(pvcs), list(pvs), []

    def items(self, path):
        if "storageclasses" in path:
            return [
                {"metadata": {"name": "nas"}, "provisioner": p.PROVISIONER, "reclaimPolicy": "Delete"},
                {"metadata": {"name": "other"}, "provisioner": "someone.else"},
            ]
        return self.pvs if "persistentvolumes" in path else self.pvcs

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        return {}

    def made(self, method, fragment):
        return [c for c in self.calls if c[0] == method and fragment in c[1]]


def pvc(uid, size="1Gi", sc="nas", modes=("ReadWriteOnce",), phase="Pending", **spec):
    return {
        "metadata": {"name": f"claim-{uid}", "namespace": "ns", "uid": uid},
        "spec": {"storageClassName": sc, "accessModes": list(modes),
                 "resources": {"requests": {"storage": size}}, **spec},
        "status": {"phase": phase},
    }


def pv(uid, size="1Gi", phase="Bound", policy="Delete", ours=True):
    return {
        "metadata": {"name": f"pvc-{uid}",
                     "annotations": {p.ANNOTATION: p.PROVISIONER if ours else "other"}},
        "spec": {"capacity": {"storage": size}, "persistentVolumeReclaimPolicy": policy,
                 "csi": {"volumeHandle": p.volume_name(uid)}},
        "status": {"phase": phase},
    }


def run(kube, nas):
    p.reconcile(kube, nas, CFG, set())
    return kube, nas


def test_quantities():
    assert p.to_gib("1Gi") == 1
    assert p.to_gib("1500Mi") == 2
    assert p.to_gib("1G") == 1
    assert p.to_gib("1Ti") == 1024
    assert p.to_gib("1") == 1


def test_name_fits_adm_limit():
    name = p.volume_name("6f1c2a3e-1111-2222-3333-444455556666")
    assert len(name) <= 31 and name.startswith("pvc-") and "-" not in name[4:]


def test_provisions_pending_claim_as_lun_zero():
    kube, nas = run(FakeKube([pvc("a", "2Gi")]), FakeNas())
    assert nas.created == [(p.volume_name("a"), 2)]
    made = kube.made("POST", "persistentvolumes")[0][2]
    attributes = made["spec"]["csi"]["volumeAttributes"]
    assert attributes["lun"] == "0"
    assert attributes["iqn"] == f"iqn.test.{p.volume_name('a')}"
    assert made["spec"]["claimRef"]["uid"] == "a"
    assert made["spec"]["persistentVolumeReclaimPolicy"] == "Delete"


def test_ignores_claims_it_does_not_own():
    _, nas = run(FakeKube([pvc("a", sc="other"), pvc("b", phase="Bound"),
                           pvc("c", volumeName="static")]), FakeNas())
    assert nas.created == []


def test_second_pass_does_not_recreate():
    _, nas = run(FakeKube([pvc("a")], [pv("a")]), FakeNas())
    assert nas.created == []


def test_cap_counts_existing_and_this_pass():
    kube, nas = run(FakeKube([pvc("a", "4Gi"), pvc("b", "4Gi")], [pv("x", "4Gi")]), FakeNas())
    assert [n for n, _ in nas.created] == [p.volume_name("a")]
    assert "exceed" in kube.made("POST", "events")[0][2]["message"]


def test_refuses_shared_access():
    kube, nas = run(FakeKube([pvc("a", modes=("ReadWriteMany",))]), FakeNas())
    assert nas.created == [] and kube.made("POST", "events")


def test_deletes_released_and_frees_cap():
    kube, nas = run(FakeKube([pvc("b", "10Gi")], [pv("a", "10Gi", phase="Released")]), FakeNas())
    assert nas.deleted == [p.volume_name("a")]
    assert kube.made("DELETE", "pvc-a")
    assert [n for n, _ in nas.created] == [p.volume_name("b")]


def test_never_deletes_retained_bound_or_foreign():
    kube, nas = run(FakeKube([], [
        pv("a", phase="Released", policy="Retain"),
        pv("b", phase="Bound"),
        pv("c", phase="Released", ours=False),
    ]), FakeNas())
    assert nas.deleted == [] and kube.calls == []


def test_keeps_pv_while_host_connected():
    kube, _ = run(FakeKube([], [pv("a", phase="Released")]), FakeNas(busy=[p.volume_name("a")]))
    assert not kube.made("DELETE", "pvc-a")


class StubNas(p.Nas):
    """Real create/delete logic against a scripted iscsi.cgi."""

    def __init__(self, target, masks=None, hosts=()):
        super().__init__({"iqn_prefix": "iqn.test", "chap_user": "u", "chap_password": "s",
                          "nas_volume": "volume1", "initiators": ["i1", "i2"]})
        self.target, self.masks, self.hosts, self.acts = target, masks, list(hosts), []

    def _iscsi(self, act, tab, query=None, **form):
        self.acts.append((act, tab))
        if (act, tab) == ("list", "target"):
            return {"targets": [self.target] if self.target else []}
        if (act, tab) == ("get", "mask"):
            return {"masks": self.masks}
        if (act, tab) == ("get", "target"):
            return {"hosts": self.hosts}
        return {}


GOOD_MASKS = [{"name": "default", "mask": "2"}, {"name": "i1", "mask": "0"}, {"name": "i2", "mask": "0"}]


def raises(fn):
    try:
        fn()
    except RuntimeError:
        return True
    return False


def test_create_accepts_verified_mask():
    nas = StubNas({"target": "v", "lun": 1}, GOOD_MASKS)
    nas.create("v", 1)
    assert ("set", "mask") in nas.acts


def test_create_never_masks_a_target_without_lun():
    nas = StubNas({"target": "v", "lun": 0}, GOOD_MASKS)
    assert raises(lambda: nas.create("v", 1))
    assert ("set", "mask") not in nas.acts


def test_create_rejects_mask_left_open():
    open_masks = [{"name": "default", "mask": "0"}] + GOOD_MASKS[1:]
    assert raises(lambda: StubNas({"target": "v", "lun": 1}, open_masks).create("v", 1))


def test_delete_refuses_connected_target():
    nas = StubNas({"target": "v", "lun": 1}, hosts=[{"host": "1.2.3.4"}])
    assert nas.delete("v") is False
    assert ("delete", "target_lun") not in nas.acts


def test_delete_of_missing_target_succeeds():
    assert StubNas(None).delete("v") is True


if __name__ == "__main__":
    tests = [(k, v) for k, v in globals().items() if k.startswith("test_")]
    for name, test in tests:
        test()
        print("ok", name)
    print(f"{len(tests)} passed")
