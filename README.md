# Demo Stop The Crazy Train - Lego Train Camel post processing app

![lego](https://www.lego.com/cdn/cs/set/assets/blt95604d8cc65e26c4/CITYtrain_Hero-XL-Desktop.png?fit=crop&format=webply&quality=80&width=1600&height=1000&dpr=1)

# Train-CEQ-App

Train-CEQ-App is the hub of the demo. It takes the raw predictions produced by
Intelligent-Train, turns them into a command for the train, and forwards an annotated
copy of the frame on for monitoring.

It is the **only component that bridges MQTT and Kafka**, and the only one with
branching logic — everything else in the pipeline is a straight transform.

## How it works

Predictions arrive from Intelligent-Train over MQTT. For each message the application
does two things:

1. Reduces the detections to a single command and publishes it over MQTT, where
   Train-Controller picks it up and drives the LEGO hub.
2. Draws the detection boxes onto the frame, wraps it in a CloudEvent envelope, and
   produces it to Kafka for Train-Monitoring-App.

A second, independent route lets the monitoring app's buttons reach the capture app:
it consumes capture commands from Kafka and turns them into HTTP calls.

## Routes

Both routes are declared in XML, **not** in Java — see
[`src/main/resources/camel/PostProcessingRoute.xml`](src/main/resources/camel/PostProcessingRoute.xml).
Searching the Java sources for `RouteBuilder` finds nothing.

### `postproscesing-route`

```
MQTT train-model-result
  -> stash the raw body in an `origin` header
  -> unmarshal to Result
  -> CommandProcessor  (detections -> class id)
  -> MQTT train-command
  -> restore the raw body from the header
  -> CloudEventProcessor  (draw boxes, wrap in a CloudEvent envelope)
  -> Kafka train-monitoring
```

The header stash is load-bearing: unmarshalling and reducing destroys the body, so the
original JSON has to be parked somewhere in order to rebuild the Kafka message from it.

### `command-capture-image`

```
Kafka train-command-capture  ->  POST ${TRAIN_HTTP_URL}/${command}
```

`$.command` is pulled from the message and appended to the URL, so `{"command":"start"}`
becomes `POST http://<capture-app>/capture/start`.

## Message contracts

**Consumes** `train-model-result` (MQTT), published by Intelligent-Train:

```json
{ "id": 1728234567890, "image": "<base64 WebP>",
  "detections": [ { "class_id": 0, "class_name": "SpeedLimit",
                    "confidence": "0.94", "box": ["12.00","34.00","56.00","78.00"] } ],
  "pre-process": "0.00s", "inference": "0.04s", "post-process": "0.01s",
  "total": "0.05s", "scale": 1.09375 }
```

Note `confidence` and the `box` elements arrive as **strings**. `Detection` declares them
as `double` and `ArrayList<Double>` and relies on Jackson coercing them.

**Produces** `train-command` (MQTT) — not JSON, just the class id as a bare string:
`"0"` (SpeedLimit), `"1"` (DangerAhead), or `"-1"` when there were no detections.
`CommandProcessor` uses the **first** detection in the array and ignores the rest.

**Produces** `train-monitoring` (Kafka) — a CloudEvent envelope built by hand, not a
Kafka-native CloudEvent. The consumer reads the fields out of the JSON body with
`cloud-events=false`. `data` is the message above with `image` replaced by the annotated
frame as `data:image/webp;base64,...`.

**Consumes** `train-command-capture` (Kafka) — `{"command": "start"}` or
`{"command": "stop"}`.

## Prerequisites

- **MQTT broker** — reachable at `BROKER_MQTT_URL` (default `tcp://localhost:1883`).
- **Kafka** — reachable at `BROKER_KAFKA_URL` / `KAFKA_BOOTSTRAP_SERVERS`
  (default `localhost:9092`).

Both are required; the application will not start a useful route without them.

## Configuration

Set through environment variables, resolved in `src/main/resources/application.properties`.

| Variable | Default | Purpose |
|---|---|---|
| `BROKER_MQTT_URL` | `tcp://localhost:1883` | MQTT broker for both the source and command topics |
| `BROKER_KAFKA_URL` | `tcp://localhost:9092` | Kafka brokers for the Camel endpoints |
| `KAFKA_BOOTSTRAP_SERVERS` | `localhost:9092` | Kafka bootstrap for the Quarkus client |
| `MQTT_SRC_TOPIC_NAME` | `train-model-result` | Detections consumed from Intelligent-Train |
| `MQTT_DEST_TOPIC_NAME` | `train-command` | Commands published to Train-Controller |
| `KAFKA_TOPIC_NAME` | `train-monitoring` | Annotated frames produced for the monitoring app |
| `KAFKA_TOPIC_CAPTURE_NAME` | `train-command-capture` | Capture start/stop commands consumed |
| `TRAIN_HTTP_URL` | `http://localhost:8082/capture` | Capture app base URL for the second route |
| `LOGGER_LEVEL` | `DEBUG` | Root log level. Note the default is DEBUG, which is noisy |
| `LOGGER_LEVEL_CATEGORY_CAMEL` | `INFO` | Log level for `org.apache.camel` |
| `CAMEL_COMPONENT_KAFKA_SECURITY_PROTOCOL` | *(unset)* | e.g. `PLAINTEXT` or `SASL_PLAINTEXT` |
| `CAMEL_COMPONENT_KAFKA_SASL_MECHANISM` | *(unset)* | e.g. `SCRAM-SHA-512` |
| `CAMEL_COMPONENT_KAFKA_SASL_JAAS_CONFIG` | *(unset)* | JAAS config when using SASL |

HTTP port is `8083`; the dev-mode debug port is `5006`.

> **Watch the spelling of `MQTT_DEST_TOPIC_NAME`.** The compose files in the `gitops`
> repository set `MQTT_DEST_TOPIC_NAM`, missing the final `E`. The variable is silently
> ignored and the default applies. The values happen to match today, so nothing breaks —
> but changing the topic there will have no effect.

## Dependencies

- **Quarkus** — Kubernetes-native Java stack.
- **Apache Camel (Camel Quarkus)** — routing, with the XML IO DSL for the route file.
- **Eclipse Paho MQTT client** — via `camel-quarkus-paho`.
- **Apache Kafka client** — via `camel-quarkus-kafka`.
- **CloudEvents SDK**, **OpenCV** (`quarkus-opencv`) for drawing the detection boxes.

## How to run

1. Clone the repository: `git clone https://github.com/redhatnsp/train-ceq-app.git`
2. Navigate to the project directory: `cd train-ceq-app`
3. Start an MQTT broker and Kafka, and set the variables above if they are not on
   `localhost`.
4. Run the application: `./mvnw compile quarkus:dev`

Dev mode needs **JDK 17 on the host**. Maven itself is optional — `./mvnw` bootstraps it.
Packaging and building the container image need neither; see
[Building from source](#building-from-source) and [Building the image](#building-the-image).

Every component of this demo talks to the same broker, so the mosquitto setup is
documented once, in
[train-controller](https://github.com/redhatnsp/train-controller#local-installation).
Follow its *Local installation* section, which has separate Linux and macOS variants —
the macOS one matters, because podman there only shares `/Users`, `/private` and
`/var/folders` with its VM, so a config mounted from `/tmp` fails.

(`podman-compose/broker/mosquitto/config/mosquitto.conf` in this repository is the copy
used by `docker-compose.yml`. It is byte-identical to the copies in the capture,
monitoring and sensor repositories, and differs from the train-controller instructions
only in setting `user mosquitto` and logging to a file rather than stdout.)

> **`docker-compose.yml` in this repository is stale and untested.** It uses a
> ZooKeeper-era Kafka, its `bridge` service mounts a `log4j.properties` that is not in
> the repository, and it publishes port 8082, which collides with the capture app. The
> maintained local stack lives in the
> [gitops](https://github.com/redhatnsp/gitops) repository under `podman-compose-shadow/`.

## Building from source

`./mvnw` works from a clean clone — the wrapper files under `.mvn/wrapper/` are committed.
With a JDK 17 on the host:

```sh
./mvnw -B clean package
```

To keep the toolchain off the host entirely, run the same command in a JDK container with
the repository bind-mounted:

```sh
podman run --rm -v "$PWD":/project:z -v "$HOME/.m2":/root/.m2:z -w /project \
  docker.io/library/eclipse-temurin:17-jdk ./mvnw -B clean package
```

The `~/.m2` mount is a **cache, not a requirement** — it holds the dependency tree and the
Maven distribution the wrapper downloads. Drop it and the build still succeeds, it just
re-fetches everything on every run. No `settings.xml` is needed either: the pom declares no
`<repositories>`, and the platform is `io.quarkus.platform` (Maven Central) rather than the
Red Hat productised `com.redhat.quarkus.platform`. Verified against a cold cache on
2026-10-07.

Output lands in `target/`:

```
target/
├── train-ceq-app-1.0.0-SNAPSHOT.jar    ~13 KB   thin jar — this project's classes only
└── quarkus-app/                        ~154 MB  the deployable (Quarkus fast-jar layout)
    ├── quarkus-run.jar                          run this
    ├── app/                                     application classes
    ├── lib/                                     dependencies
    └── quarkus/                                 generated bootstrap
```

The thin jar at the top is **not** runnable on its own. `quarkus-run.jar` is a manifest
pointing at its sibling directories, so the whole `target/quarkus-app/` tree has to travel
together:

```sh
java -jar target/quarkus-app/quarkus-run.jar
```

## Building the image

```sh
./build-image.sh           # build and tag locally
PUSH=1 ./build-image.sh    # build, tag, and push
```

**No JDK or Maven is needed on the host.** The script runs Maven inside a container
(`maven:3.9-eclipse-temurin-17` by default) to produce `target/quarkus-app/`, then builds
the runtime image from it.

Note `src/main/docker/Dockerfile.jvm` does *not* compile anything — it starts from
`ubi8/openjdk-17` and copies `target/quarkus-app/` in, so the packaging step must happen
first. That is what the Maven container is for.

Overridable: `IMAGE`, `TAG`, `PLATFORM`, `MAVEN_IMAGE`, `M2_DIR` (defaults to `~/.m2`,
mounted so dependencies are cached between runs). Pushing is opt-in so that running the
script cannot publish by accident.

## Related Modules

- **Capture-App** — captures frames and sends them to Intelligent-Train.
- **Intelligent-Train** — runs the model and produces the raw predictions this app consumes.
- **Train-Monitoring-App** — receives the CloudEvent from this app via Kafka, for
  monitoring and visualisation.
- **Train-Controller** — receives commands from this app over MQTT and drives the train
  over Bluetooth.

## Known issues

- **Only the first detection is used.** `CommandProcessor` takes `detections.get(0)` with
  no ranking, so when a SpeedLimit and a DangerAhead sign are both in frame, which one
  steers the train is effectively arbitrary.
- **A malformed message produces a confusing NullPointerException.**
  `CloudEventProcessor` logs the real exception in its catch block but then dereferences
  a null, so the NPE is what propagates.
- The CloudEvent `source` is hardcoded to `http://example.com`.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file
for details.
