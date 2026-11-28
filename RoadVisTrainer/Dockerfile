# RoadVis Trainer — CPU-only image (API and worker share it; see docker-compose.yml).
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    YOLO_AUTOINSTALL=false \
    YOLO_CONFIG_DIR=/data/.ultralytics \
    MPLCONFIGDIR=/data/.matplotlib \
    ROADVIS_DATA_DIR=/data

RUN apt-get update \
    && apt-get install -y --no-install-recommends libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# CPU-only PyTorch from the PyTorch CPU index (no CUDA libraries). coremltools 9 is tested with torch <= 2.7.
RUN pip install torch==2.7.1 torchvision==0.22.1 --index-url https://download.pytorch.org/whl/cpu

WORKDIR /app
COPY pyproject.toml README.md ./
COPY roadvis_trainer ./roadvis_trainer
# Ultralytics pulls opencv-python (needs X11/GL libraries); the headless build of the same version is enough here.
RUN pip install . \
    && v="$(python -c 'import importlib.metadata as m; print(m.version("opencv-python"))')" \
    && pip uninstall -y opencv-python \
    && pip install "opencv-python-headless==${v}" \
    && python -c "import cv2, fastapi, ultralytics, coremltools, onnx; print('ok', cv2.__version__)"

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin roadvis \
    && mkdir -p /data && chown roadvis:roadvis /data
USER roadvis
# Teacher/baseline weights (yolo11x.pt, yolo11s.pt) are downloaded into the working directory on first use and
# therefore persist in the data volume.
WORKDIR /data
VOLUME ["/data"]
EXPOSE 8601

HEALTHCHECK --interval=60s --timeout=5s --start-period=20s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8601/healthz', timeout=4)" || exit 1

CMD ["roadvis-trainer", "serve", "--host", "0.0.0.0", "--port", "8601", "--forwarded-allow-ips", "*"]
