FROM python:3.12-slim

# zigpy-znp — версия Z-Stack по serial (SYS.Version);
# universal-silabs-flasher — probe EZSP/ember-прошивок EFR32.
RUN pip install --no-cache-dir zigpy-znp==0.13.1 universal-silabs-flasher==0.0.30

COPY probe.py /probe.py
ENTRYPOINT ["python", "/probe.py"]
