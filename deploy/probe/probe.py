#!/usr/bin/env python3
"""Активный детект координатора: семейство + версия прошивки.

Запускается одноразовым контейнером (make detect-firmware), устройство прокинуто
как /dev/zigbee. Печатает в stdout ровно один JSON:
    {"family": "zstack|ember|unknown", "firmware": "...", "model": "...",
     "confidence": "probe|none", "error": "..."}

Порядок: подсказка семейства (аргумент 2, из VID:PID-эвристики) определяет, какой
probe пробовать первым; при неудаче пробуем второй. deconz/zigate активно не
детектируются (family приходит эвристикой, firmware — вручную).
"""
import asyncio
import json
import re
import subprocess
import sys

DEVICE = sys.argv[1] if len(sys.argv) > 1 else "/dev/zigbee"
HINT = sys.argv[2] if len(sys.argv) > 2 else ""


def out(family, firmware="", model="", confidence="probe", error=""):
    print(json.dumps({
        "family": family,
        "firmware": firmware,
        "model": model,
        "confidence": confidence,
        "error": error,
    }))
    sys.exit(0)


async def probe_znp():
    """Z-Stack: SYS.Version → CodeRevision (build-дата вида 20240710)."""
    from zigpy_znp.api import ZNP
    from zigpy_znp.config import CONFIG_SCHEMA
    import zigpy_znp.commands as c

    znp = ZNP(CONFIG_SCHEMA({"device": {"path": DEVICE}}))
    try:
        await asyncio.wait_for(znp.connect(), timeout=15)
        rsp = await asyncio.wait_for(znp.request(c.SYS.Version.Req()), timeout=10)
        model = {0: "CC2531", 1: "CC2652/CC1352", 2: "CC2652/CC1352"}.get(
            getattr(rsp, "ProductId", None), ""
        )
        return str(rsp.CodeRevision), model
    finally:
        znp.close()


def probe_silabs():
    """EFR32: universal-silabs-flasher probe → версия EZSP из вывода."""
    proc = subprocess.run(
        ["universal-silabs-flasher", "--device", DEVICE, "probe"],
        capture_output=True, text=True, timeout=90,
    )
    text = proc.stdout + proc.stderr
    m = re.search(r"(?:EZSP|EmberZNet).*?(\d+\.\d+\.\d+(?:\.\d+)?)", text)
    if not m:
        raise RuntimeError(f"версия не распознана (rc={proc.returncode})")
    return m.group(1), ""


def try_znp():
    try:
        fw, model = asyncio.get_event_loop().run_until_complete(probe_znp())
        out("zstack", fw, model)
    except Exception as e:  # noqa: BLE001 — любой сбой = «не zstack», пробуем дальше
        return str(e)


def try_silabs():
    try:
        fw, model = probe_silabs()
        out("ember", fw, model)
    except Exception as e:  # noqa: BLE001
        return str(e)


order = [try_silabs, try_znp] if HINT == "ember" else [try_znp, try_silabs]
errors = [f() for f in order]
out("unknown", confidence="none",
    error="; ".join(e for e in errors if e) or "probe не дал результата")
