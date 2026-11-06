# Runs the tests and the example CLI build on Linux.
#   docker build -f tool/docker/Dockerfile -t webrtc_ffi-test .
#   docker run --rm webrtc_ffi-test
FROM dart:3.13.7
RUN apt-get update && apt-get install -y --no-install-recommends cmake build-essential \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY pubspec.yaml analysis_options.yaml ./
RUN dart pub get
COPY . .
RUN dart pub get --offline
CMD ["sh", "-c", "dart analyze && dart test"]
